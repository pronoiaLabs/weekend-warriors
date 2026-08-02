"""Snowflake connection and SPCS detection for the control plane.

WHY THIS EXISTS
    The control plane (registry_store reads, registry_sync writes) has to reach
    Snowflake from two very different places, and the right way to authenticate is
    not the same in both. Centralising it here means neither caller has to know which
    environment it is in.

    Note this is only for the CONTROL PLANE. The data path authenticates separately:
    dlt reads DESTINATION__SNOWFLAKE__CREDENTIALS__* env vars for the destination, and
    deploy/snow_env.py sets both families from one `snow` CLI connection.

CONTENTS
    1. Environment detection ... _SPCS_TOKEN_PATH, in_spcs
    2. Connecting ............... SnowflakeSessionError, connect

THE TWO ENVIRONMENTS
    In SPCS  -> Snowflake mounts an OAuth session token at /snowflake/session/token.
                Connect with authenticator="oauth" plus that token, using the
                SNOWFLAKE_HOST / SNOWFLAKE_ACCOUNT the runtime injects. Nothing is
                baked into the image.

    External -> SNOWFLAKE_* env vars from a laptop or CI. Whichever ONE of password,
                PAT, or key-pair is present is used, together with the authenticator
                that names it.

The connector is imported lazily so importing this module never hard-requires
snowflake-connector-python. The YAML and local DuckDB paths must work without it.
"""

from __future__ import annotations

import os
from pathlib import Path
from typing import Any

# ---------------------------------------------------------------------------
# 1. Environment detection
#
# The presence of the token file is the signal, not an env var, because it is
# something only Snowflake can produce. Nothing on a laptop can fake being in SPCS
# by exporting a variable.
# ---------------------------------------------------------------------------

# Snowflake mounts the OAuth session token here for any container running in SPCS.
_SPCS_TOKEN_PATH = "/snowflake/session/token"


def in_spcs() -> bool:
    """True when running inside an SPCS container (OAuth token file present)."""
    return Path(_SPCS_TOKEN_PATH).exists()


# ---------------------------------------------------------------------------
# 2. Connecting
#
# Every credential is optional and each maps to a specific connector parameter.
# Getting that mapping wrong fails in a way that blames the credential rather than
# the code, so the pairings are spelled out at each branch:
#
#   password    -> password=       authenticator absent or SNOWFLAKE
#   PAT         -> token=          authenticator PROGRAMMATIC_ACCESS_TOKEN
#   key-pair    -> private_key_file=
#   SSO         -> no secret       authenticator externalbrowser
#
# The PAT pairing is the non-obvious one. A PAT is not a password: the connector
# builds AuthByPAT(self._token) (see connector connection.py, the
# PROGRAMMATIC_ACCESS_TOKEN branch), so it reads `token` and nothing else. Setting
# the authenticator without the token yields "Programmatic access token is invalid",
# which points at the credential when the real problem is that none was sent.
# ---------------------------------------------------------------------------


class SnowflakeSessionError(RuntimeError):
    """Raised when a Snowflake connection cannot be established from the environment."""


def connect():  # noqa: ANN201, returns a snowflake.connector connection
    """Open a snowflake-connector-python connection for the current environment."""
    import snowflake.connector  # noqa: PLC0415

    database = os.environ.get("SNOWFLAKE_DATABASE", "DLT_DB")
    warehouse = os.environ.get("SNOWFLAKE_WAREHOUSE", "DLT_WH")

    if in_spcs():
        token = Path(_SPCS_TOKEN_PATH).read_text()
        return snowflake.connector.connect(
            host=os.environ["SNOWFLAKE_HOST"],
            account=os.environ["SNOWFLAKE_ACCOUNT"],
            token=token,
            authenticator="oauth",
            database=database,
            warehouse=warehouse,
        )

    # External (local / CI). Account and user are always required; the secret varies.
    account = os.environ.get("SNOWFLAKE_ACCOUNT")
    user = os.environ.get("SNOWFLAKE_USER")
    if not account or not user:
        raise SnowflakeSessionError(
            "cannot connect to Snowflake: set SNOWFLAKE_ACCOUNT and SNOWFLAKE_USER "
            "(plus SNOWFLAKE_PASSWORD, SNOWFLAKE_TOKEN, or a key-pair) for external "
            "access, or run where /snowflake/session/token is mounted. From a laptop "
            'the usual source is: eval "$(uv run python -m deploy.snow_env)".'
        )

    kwargs: dict[str, Any] = {
        "account": account,
        "user": user,
        "database": database,
        "warehouse": warehouse,
    }
    if os.environ.get("SNOWFLAKE_PASSWORD"):
        kwargs["password"] = os.environ["SNOWFLAKE_PASSWORD"]
    if os.environ.get("SNOWFLAKE_TOKEN"):
        # PAT / OAuth. Must be `token`, never `password`.
        kwargs["token"] = os.environ["SNOWFLAKE_TOKEN"]
    if os.environ.get("SNOWFLAKE_AUTHENTICATOR"):
        kwargs["authenticator"] = os.environ["SNOWFLAKE_AUTHENTICATOR"]
    if os.environ.get("SNOWFLAKE_ROLE"):
        kwargs["role"] = os.environ["SNOWFLAKE_ROLE"]
    if os.environ.get("SNOWFLAKE_PRIVATE_KEY_PATH"):
        kwargs["private_key_file"] = os.environ["SNOWFLAKE_PRIVATE_KEY_PATH"]

    return snowflake.connector.connect(**kwargs)
