"""Read listed tables from a Snowflake APP schema through snowflake_session.

WHY THIS EXISTS
    nfl_app_to_postgres copies dbt APP marts into Snowflake Postgres. The
    container already has a Snowflake session (OAuth in SPCS, SNOWFLAKE_* on
    a laptop). sql_database + snowflake-sqlalchemy would be a second auth
    stack for the same warehouse. This source is SELECT * per listed table
    through pipelines.common.snowflake_session.connect().

    Tables come from the registry config, not from INFORMATION_SCHEMA. A new
    mart is an edit to app-copy-registry.yml.

CONTENTS
    1. Identifiers ............. IDENT_RE, qualify
    2. Types ................... dlt_data_type (DESCRIBE TABLE -> dlt hint)
    3. Variants ................ adapt_copied_value (VARIANT is text, not jsonb)
    4. Table entries ........... normalize_table (per-table copy mode)
    5. The source .............. snowflake_app

INCREMENTAL COPIES
    A full replace of every table each run is what OOMed the shared Postgres
    instance (2026-08-24): LOG_LINES and METRIC_SAMPLES carry 90 days of
    history and were re-INSERTed wholesale every fire. A registry table entry
    can therefore be a mapping instead of a bare name:

        - name: log_lines
          mode: append          # or merge (needs primary_key), or replace
          cursor: event_ts
          primary_key: query_id # merge only

    append/merge read `WHERE <cursor> >= <last seen value>` (the boundary is
    inclusive; dlt's incremental dedupes rows equal to it), pushed into the
    Snowflake SELECT so the warehouse stops scanning history too. A bare
    string stays exactly what it always was: full replace. Incremental never
    deletes, so Postgres keeps rows Snowflake retention purges; the weekly
    obs_to_postgres_resync entry (spec-level write_disposition: replace, the
    blunt override) is what re-bounds it.

    CAVEAT, accepted: for the two event tables the cursor is the
    container-side EVENT_TS, and two containers flushing out of order can
    land a row below the copied maximum, which the hourly copy then never
    picks up. The weekly resync heals exactly that.
"""

from __future__ import annotations

import json
import logging
import re
from collections.abc import Callable, Iterator
from typing import Any

import dlt

log = logging.getLogger("dlt_pipeline.snowflake_app")

# Unquoted Snowflake identifiers. The registry list is the allowlist; this
# stops a typo becoming a second statement.
IDENT_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


def dlt_data_type(sf_type: str) -> str:
    """Map a Snowflake DESCRIBE TABLE type to a dlt column hint.

    Inference from row values drops all-null columns and skips empty tables.
    The dashboard SELECTs named columns, so the copy must keep the mart's
    full DESCRIBE even when every value is NULL.
    """
    t = sf_type.upper()
    if t.startswith("NUMBER"):
        m = re.match(r"NUMBER\((\d+),(\d+)\)", t)
        if m and m.group(2) == "0":
            return "bigint"
        return "double"
    if t.startswith(("FLOAT", "DOUBLE", "REAL")):
        return "double"
    if t.startswith("BOOLEAN"):
        return "bool"
    if t == "DATE":
        return "date"
    if t.startswith("TIMESTAMP"):
        return "timestamp"
    # ARRAY / OBJECT are structured. VARIANT is not: PIPELINE_REGISTRY.write_disposition
    # is a VARIANT whose value is the string replace (PARSE_JSON of json.dumps("replace")).
    # The connector hands that over as a bare Python str, and Postgres jsonb rejects it.
    if t.startswith("VARIANT"):
        return "text"
    if t.startswith(("ARRAY", "OBJECT")):
        return "json"
    return "text"


def adapt_copied_value(value: Any, data_type: str) -> Any:
    """Coerce a Snowflake cell so the Postgres hint can store it.

    VARIANT is copied as text. The connector may still return a dict or list for
    an object-valued VARIANT (row_counts, operator_statistics); dump those so
    the dashboard's parse_variant can json.loads them. jsonb columns keep
    dict/list, and wrap a non-JSON string so a stray VARIANT-as-json cannot
    fail the load the way write_disposition did.
    """
    if value is None:
        return None
    if data_type == "text" and isinstance(value, (dict, list)):
        return json.dumps(value)
    if data_type == "json" and isinstance(value, str):
        try:
            json.loads(value)
        except ValueError:
            return json.dumps(value)
    return value


def _column_hints(cur: Any, fqn: str) -> dict[str, dict[str, Any]]:
    cur.execute(f"DESCRIBE TABLE {fqn}")
    hints: dict[str, dict[str, Any]] = {}
    for row in cur.fetchall():
        name = str(row["name"]).lower()
        hints[name] = {
            "data_type": dlt_data_type(str(row["type"])),
            "nullable": str(row.get("null?") or "Y").upper() == "Y",
        }
    if not hints:
        raise RuntimeError(f"DESCRIBE TABLE {fqn} returned no columns")
    return hints


def qualify(database: str, schema: str, table: str) -> str:
    """Return database.schema.table after rejecting anything that is not an ident."""
    for part, label in ((database, "database"), (schema, "schema"), (table, "table")):
        if not isinstance(part, str) or not IDENT_RE.match(part):
            raise ValueError(f"snowflake_app {label} is not a Snowflake identifier: {part!r}")
    return f"{database}.{schema}.{table}"


_TABLE_KEYS = frozenset({"name", "mode", "cursor", "primary_key"})
_MODES = ("replace", "append", "merge")


def normalize_table(entry: str | dict[str, Any]) -> dict[str, Any]:
    """A registry table entry -> {name, mode, cursor, primary_key}, validated.

    Fail-fast on shape errors: a typo here would otherwise become a silent
    full replace (mode misspelled) or a silent append that duplicates rows
    (merge without a key -- run.py also guards that, but the message here
    names the table).
    """
    if isinstance(entry, str):
        return {"name": entry, "mode": "replace", "cursor": None, "primary_key": ()}
    if not isinstance(entry, dict):
        raise ValueError(f"snowflake_app table entry must be a table name or a mapping: {entry!r}")
    unknown = set(entry) - _TABLE_KEYS
    if unknown:
        raise ValueError(
            f"snowflake_app table entry {entry.get('name')!r} has unknown "
            f"key(s): {', '.join(sorted(unknown))}"
        )
    name = entry.get("name")
    if not name:
        raise ValueError(f"snowflake_app table entry needs a name: {entry!r}")
    mode = entry.get("mode", "replace")
    if mode not in _MODES:
        raise ValueError(
            f"snowflake_app table {name!r}: mode must be one of {_MODES}, got {mode!r}"
        )
    cursor = entry.get("cursor")
    primary_key = entry.get("primary_key") or ()
    if isinstance(primary_key, str):
        primary_key = (primary_key,)
    primary_key = tuple(primary_key)
    if mode == "replace" and (cursor or primary_key):
        raise ValueError(
            f"snowflake_app table {name!r}: cursor/primary_key only make sense "
            "with mode append or merge (a bare name already means replace)"
        )
    if mode in ("append", "merge") and not cursor:
        raise ValueError(f"snowflake_app table {name!r}: mode {mode!r} needs a cursor")
    if mode == "merge" and not primary_key:
        raise ValueError(f"snowflake_app table {name!r}: mode merge needs a primary_key")
    for ident in (name, cursor, *primary_key):
        if ident is not None and not IDENT_RE.match(ident):
            raise ValueError(f"snowflake_app table {name!r}: not a Snowflake identifier: {ident!r}")
    return {"name": name, "mode": mode, "cursor": cursor, "primary_key": primary_key}


def select_sql(fqn: str, cursor: str | None = None, since: Any = None) -> str:
    """The read statement: full scan, or bounded at the incremental cursor.

    Inclusive boundary on purpose: dlt's incremental dedupes rows equal to
    the previous last_value, and `>` would drop rows that share the boundary
    timestamp but landed after the previous read.
    """
    if cursor is None or since is None:
        return f"SELECT * FROM {fqn}"
    return f"SELECT * FROM {fqn} WHERE {cursor.upper()} >= %s"


def snowflake_app(
    name: str,
    tables: list[str | dict[str, Any]],
    database: str,
    schema: str = "APP",
    connect: Callable[[], Any] | None = None,
):
    """One resource per table. Each yields dict rows with lowercase keys.

    `name` becomes the dlt schema name; pass the pipeline name so two APP copies
    cannot share one stored schema. `connect` is injected by tests. Table
    entries are bare names (replace) or mappings (append/merge on a cursor);
    see normalize_table and the module docstring.
    """
    if not tables:
        raise ValueError("snowflake_app requires config.tables")
    specs = [normalize_table(entry) for entry in tables]

    if connect is None:

        def connect() -> Any:
            from pipelines.common.snowflake_session import connect as _connect  # noqa: PLC0415

            return _connect()

    def _rows(
        fqn: str,
        columns: dict[str, dict[str, Any]],
        cursor_col: str | None = None,
        since: Any = None,
    ) -> Iterator[dict[str, Any]]:
        from snowflake.connector import DictCursor  # noqa: PLC0415

        types = {name: spec["data_type"] for name, spec in columns.items()}
        conn = connect()
        try:
            cur = conn.cursor(DictCursor)
            sql = select_sql(fqn, cursor_col, since)
            if since is not None and cursor_col is not None:
                cur.execute(sql, (since,))
            else:
                cur.execute(sql)
            for row in cur:
                out = {str(k).lower(): v for k, v in row.items()}
                yield {k: adapt_copied_value(v, types.get(k, "text")) for k, v in out.items()}
        finally:
            conn.close()

    @dlt.source(name=name, max_table_nesting=0)
    def _source() -> Any:
        # One connection for every DESCRIBE; each resource still opens its own
        # at extraction time, because extraction happens after this returns.
        conn = connect()
        try:
            from snowflake.connector import DictCursor  # noqa: PLC0415

            hints = {
                spec["name"]: _column_hints(
                    conn.cursor(DictCursor), qualify(database, schema, spec["name"])
                )
                for spec in specs
            }
        finally:
            conn.close()

        for spec in specs:
            table = spec["name"]
            fqn = qualify(database, schema, table)
            columns = hints[table]
            for ident in filter(None, (spec["cursor"], *spec["primary_key"])):
                if ident.lower() not in columns:
                    raise ValueError(
                        f"snowflake_app table {table!r}: column {ident!r} is not in "
                        f"DESCRIBE TABLE {fqn}"
                    )
            log.info(
                "resource %s reads %s (%s columns, mode %s)",
                table,
                fqn,
                len(columns),
                spec["mode"],
            )
            if spec["mode"] == "replace":
                yield dlt.resource(
                    _rows(fqn, columns),
                    name=table,
                    write_disposition="replace",
                    columns=columns,
                )
                continue

            def _incremental_rows(
                # include, not raise: a stray NULL cursor value must not kill
                # the whole copy. NULL rows ride along (the SQL boundary
                # excludes them after the first run) and never advance state.
                incremental=dlt.sources.incremental(
                    spec["cursor"].lower(), on_cursor_value_missing="include"
                ),
                _fqn: str = fqn,
                _columns: dict[str, dict[str, Any]] = columns,
                _cursor: str = spec["cursor"],
            ) -> Iterator[dict[str, Any]]:
                yield from _rows(_fqn, _columns, _cursor, incremental.last_value)

            kwargs: dict[str, Any] = {}
            if spec["primary_key"]:
                kwargs["primary_key"] = list(spec["primary_key"])
            yield dlt.resource(
                _incremental_rows,
                name=table,
                write_disposition=spec["mode"],
                columns=columns,
                **kwargs,
            )

    return _source()
