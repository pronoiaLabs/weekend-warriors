"""Bridge a Snowflake CLI named connection into dlt / connector env vars.

WHY THIS EXISTS
    dlt authenticates its Snowflake destination from environment variables. The `snow`
    CLI keeps credentials in its own TOML files. Without a bridge you would have to copy
    the credential into `.dlt/secrets.toml`, leaving a second copy on disk inside the
    project directory, protected only by .gitignore.

    This script reads the CLI's files and prints shell `export` lines instead. The
    Makefile evals them, so the credential exists only in the environment of a single
    run and `connections.toml` stays the one place it is stored.

CONTENTS
    1. Config file discovery ..... _snowflake_home, _connections_path, _config_path,
                                   _load_toml
    2. Precedence resolution ..... resolve_config
    3. Shell-safe emission ....... _shell_quote, _emit
    4. Connection mapping ........ build_exports
    5. Entry point ............... main

USAGE (see the Makefile `snow-env` / `run-snowflake` targets)

    eval "$(uv run python -m deploy.snow_env weekend-warriors)"
    DLT_DESTINATION=snowflake python -m pipelines.batch.run nfl_reference

    With no argument it resolves the default connection. See `resolve_config`.

EMITS, for whatever keys the connection defines
    * dlt destination : DESTINATION__SNOWFLAKE__CREDENTIALS__{HOST,USERNAME,ROLE,
                        WAREHOUSE,PASSWORD,TOKEN,AUTHENTICATOR,PRIVATE_KEY_PATH,
                        PRIVATE_KEY_PASSPHRASE}
    * connector       : SNOWFLAKE_{ACCOUNT,USER,ROLE,WAREHOUSE,PASSWORD,TOKEN,
                        AUTHENTICATOR,PRIVATE_KEY_PATH}  (used by registry_store)
    * dev sandbox     : DLT_DEV_DATASET, derived from the Snowflake user

OUTPUT DISCIPLINE
    Secrets go to stdout, and stdout is meant only to be eval'd. Every diagnostic,
    warning, and error goes to stderr prefixed with `#`, so that a caller which
    captures stdout never accidentally captures a message, and a caller which shows
    stderr never accidentally shows a credential.
"""

from __future__ import annotations

import argparse
import os
import re
import sys
import tomllib
from pathlib import Path

# ---------------------------------------------------------------------------
# 1. Config file discovery
#
# The CLI splits its state across two files in the same directory, and the split is
# not intuitive:
#
#   connections.toml   the connection definitions themselves
#   config.toml        CLI settings, including which connection is the default,
#                      and (only when connections.toml is absent) a [connections]
#                      section of its own
#
# Both are relocated together by $SNOWFLAKE_HOME, so the base directory is resolved
# once and the two filenames hang off it.
# ---------------------------------------------------------------------------


def _snowflake_home() -> Path:
    """Directory holding the CLI's TOML files. $SNOWFLAKE_HOME wins if set."""
    home = os.environ.get("SNOWFLAKE_HOME")
    return Path(home) if home else Path.home() / ".snowflake"


def _connections_path() -> Path:
    return _snowflake_home() / "connections.toml"


def _config_path() -> Path:
    return _snowflake_home() / "config.toml"


def _load_toml(path: Path) -> dict:
    """Parse a TOML file, or return {} if it does not exist.

    A missing file is normal, not an error: a machine can legitimately have only one
    of the two. Returning {} lets the caller decide whether the combination is fatal.
    """
    if not path.exists():
        return {}
    return tomllib.loads(path.read_text())


# ---------------------------------------------------------------------------
# 2. Precedence resolution
#
# Two separate questions with two different answers, which is what makes this easy to
# get wrong: where the connection *definitions* come from, and where the *name* of the
# default connection comes from. They live in different files.
#
# Kept as a pure function taking already-parsed dicts so the rules can be read and
# tested without touching the filesystem.
# ---------------------------------------------------------------------------


def resolve_config(
    connections_data: dict, config_data: dict
) -> tuple[dict, str | None, str]:
    """Resolve (connections, default_connection_name, source_label) the way the CLI does.

    Verified by reading snowflake-cli 3.23.0 rather than inferred:

      * Connections. If connections.toml exists it *replaces* config.toml's
        [connections] section outright; the two are never merged. See the comment in
        snowflake/cli/api/config.py `_dump_config`: "config manager doesn't have
        connections from config.toml if connections.toml exists".

        Practical consequence worth knowing: once connections.toml exists, any
        connection still defined in config.toml is dead. Editing it changes nothing
        and the CLI will not list it.

      * default_connection_name. Lives in config.toml, not connections.toml
        (config.py `get_default_connection_name` reads it from the connector's config
        manager, whose file is config.toml). The connector derives the env var name
        automatically as SNOWFLAKE_DEFAULT_CONNECTION_NAME, and env wins over file
        (config_manager.py `_get_env`). Its built-in fallback is the literal "default".

    We also accept default_connection_name in connections.toml as a courtesy, after
    config.toml, since that is where people reasonably expect to set it.

    Returns the source label too, so an error message can say which file it searched
    instead of leaving the caller to guess.
    """
    # Presence of connections.toml is the switch, not a merge of the two.
    if connections_data:
        conns = connections_data
        source = "connections.toml"
    else:
        raw = config_data.get("connections")
        conns = raw if isinstance(raw, dict) else {}
        source = "config.toml [connections]"

    # connections.toml is flat: every table is a connection, but scalars such as a
    # stray default_connection_name can sit alongside them. Keep only the tables.
    conns = {k: v for k, v in conns.items() if isinstance(v, dict)}

    # Env first, matching the CLI: an explicit environment override has to beat a
    # value sitting in a file, never the other way round.
    default_name = (
        os.environ.get("SNOWFLAKE_DEFAULT_CONNECTION_NAME")
        or config_data.get("default_connection_name")
        or connections_data.get("default_connection_name")
    )
    return conns, default_name, source


# ---------------------------------------------------------------------------
# 3. Shell-safe emission
#
# Output is consumed by `eval`, so a value containing a quote, a space, or a `$`
# would otherwise be re-interpreted by the shell. Single quotes disable all shell
# expansion, which is what we want for credentials.
# ---------------------------------------------------------------------------


def _shell_quote(value: str) -> str:
    """Single-quote a value for safe shell `eval`.

    The replace handles the one character single quotes cannot escape themselves:
    close the quote, emit an escaped quote, reopen. `it's` becomes `'it'\\''s'`.
    """
    return "'" + str(value).replace("'", "'\\''") + "'"


def _emit(pairs: list[tuple[str, str]]) -> str:
    return "\n".join(f"export {k}={_shell_quote(v)}" for k, v in pairs)


# ---------------------------------------------------------------------------
# 4. Connection mapping
#
# One connection dict fans out into two naming schemes, because two different
# libraries read this environment:
#
#   DESTINATION__SNOWFLAKE__CREDENTIALS__*   dlt's destination config
#   SNOWFLAKE_*                              snowflake-connector-python, used by
#                                            registry_store to read the control plane
#
# Every field is optional. Emit whatever the connection happens to define and let
# the consumer complain about what it actually needs.
# ---------------------------------------------------------------------------


def build_exports(conn: dict[str, object]) -> tuple[list[tuple[str, str]], list[str]]:
    """Map a connection dict to (export pairs, warnings)."""
    pairs: list[tuple[str, str]] = []
    warnings: list[str] = []

    def put(dlt_key: str | None, sf_key: str | None, value: object) -> None:
        """Append a value under either naming scheme, or both. Skips None."""
        if value is None:
            return
        v = str(value)
        if dlt_key:
            pairs.append((f"DESTINATION__SNOWFLAKE__CREDENTIALS__{dlt_key}", v))
        if sf_key:
            pairs.append((sf_key, v))

    # Non-secret fields, always safe to emit.
    # dlt's snowflake "host" is the account identifier (see .dlt/secrets.toml.example).
    put("HOST", "SNOWFLAKE_ACCOUNT", conn.get("account"))
    put("USERNAME", "SNOWFLAKE_USER", conn.get("user"))
    put("ROLE", "SNOWFLAKE_ROLE", conn.get("role"))
    put("WAREHOUSE", "SNOWFLAKE_WAREHOUSE", conn.get("warehouse"))

    # The authenticator (if any) is the mode, not a secret. Always pass it through:
    # it tells the client *how* to use whichever credential follows.
    authenticator = conn.get("authenticator")
    if authenticator is not None:
        put("AUTHENTICATOR", "SNOWFLAKE_AUTHENTICATOR", authenticator)

    # Exactly one secret is emitted, in this order of preference. A connection can
    # legitimately define more than one; picking the first avoids sending a client
    # two credentials and letting it choose.
    password = conn.get("password")
    token = conn.get("token")
    key_path = conn.get("private_key_file") or conn.get("private_key_path")

    if password is not None:
        put("PASSWORD", "SNOWFLAKE_PASSWORD", password)
    elif token is not None:
        # PAT / OAuth token (authenticator is typically programmatic_access_token or oauth).
        put("TOKEN", "SNOWFLAKE_TOKEN", token)
    elif key_path is not None:
        # Only the path travels; the key file itself is never read here.
        put("PRIVATE_KEY_PATH", "SNOWFLAKE_PRIVATE_KEY_PATH", key_path)
        passphrase = conn.get("private_key_file_pwd") or conn.get("private_key_passphrase")
        put("PRIVATE_KEY_PASSPHRASE", None, passphrase)
    elif authenticator is None:
        # No secret and no mode. Usually means `snow` stored the secret in the OS
        # keyring, which this script deliberately does not touch. Warn rather than
        # fail: the caller may not need the destination at all.
        warnings.append(
            "connection has no password / token / private_key / authenticator. "
            "The secret is likely in your OS keyring. Add `authenticator = "
            "\"externalbrowser\"` to the connection, or a private_key_file, so the "
            "destination can authenticate."
        )

    return pairs, warnings


# ---------------------------------------------------------------------------
# 5. Entry point
#
# Exit codes matter here: the Makefile checks them to decide whether to run the
# pipeline at all.
#
#   0  exports on stdout, ready to eval
#   1  no config files found
#   2  a name was resolved but no such connection exists
# ---------------------------------------------------------------------------


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="deploy.snow_env",
        description="Emit shell export lines for a snow CLI connection (eval them).",
    )
    parser.add_argument(
        "connection",
        nargs="?",
        help=(
            "connection name; defaults to $SNOWFLAKE_DEFAULT_CONNECTION_NAME, then "
            "default_connection_name in config.toml, then 'default'"
        ),
    )
    args = parser.parse_args(sys.argv[1:] if argv is None else argv)

    # Read both, decide after. Either file alone is a workable configuration.
    connections_data = _load_toml(_connections_path())
    config_data = _load_toml(_config_path())
    if not connections_data and not config_data:
        print(
            f"# snow_env: neither {_connections_path()} nor {_config_path()} exists",
            file=sys.stderr,
        )
        return 1

    conns, default_name, source = resolve_config(connections_data, config_data)

    # "default" is the CLI's own built-in fallback when nothing is configured.
    name = args.connection or default_name or "default"

    conn = conns.get(name)
    if not conn:
        # Name the file that was searched and list what is in it. A bare "not found"
        # leaves the caller unable to tell a typo from a file-precedence surprise.
        available = ", ".join(sorted(conns)) or "(none)"
        print(
            f"# snow_env: connection '{name}' not found in {source}. Available: {available}",
            file=sys.stderr,
        )
        if not args.connection and not default_name:
            # Distinguish "you asked for something that isn't there" from "you asked
            # for nothing and nothing is configured", since 'default' above makes the
            # second case masquerade as the first.
            print(
                "# snow_env: no connection was given and no default is set. Either pass one "
                "(CONN=<name>), run `snow connection set-default <name>`, or export "
                "SNOWFLAKE_DEFAULT_CONNECTION_NAME.",
                file=sys.stderr,
            )
        return 2

    pairs, warnings = build_exports(conn)
    for w in warnings:
        print(f"# snow_env warning: {w}", file=sys.stderr)

    # Emit a per-developer dev schema derived from the Snowflake user, e.g.
    # user "JSMITH" -> DLT_DEV_DATASET=DEV_JSMITH. run-snowflake / run-spcs use
    # this when DATASET is not set explicitly, so the sandbox is tied to the
    # developer's Snowflake identity rather than their OS login.
    user = conn.get("user")
    if user:
        # Schema identifiers cannot hold arbitrary characters; an email-style login
        # such as "a.b@c.com" would otherwise produce invalid DDL.
        safe = re.sub(r"[^A-Z0-9_]", "_", str(user).upper())
        pairs.append(("DLT_DEV_DATASET", f"DEV_{safe}"))

    print(_emit(pairs))
    print(f"# snow_env: sourced connection '{name}'", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
