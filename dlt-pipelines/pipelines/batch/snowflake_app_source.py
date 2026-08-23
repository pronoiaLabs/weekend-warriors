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
    4. The source .............. snowflake_app
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
            raise ValueError(
                f"snowflake_app {label} is not a Snowflake identifier: {part!r}"
            )
    return f"{database}.{schema}.{table}"


def snowflake_app(
    name: str,
    tables: list[str],
    database: str,
    schema: str = "APP",
    connect: Callable[[], Any] | None = None,
):
    """One resource per table. Each yields dict rows with lowercase keys.

    `name` becomes the dlt schema name; pass the pipeline name so two APP copies
    cannot share one stored schema. `connect` is injected by tests.
    """
    if not tables:
        raise ValueError("snowflake_app requires config.tables")

    if connect is None:

        def connect() -> Any:
            from pipelines.common.snowflake_session import connect as _connect  # noqa: PLC0415

            return _connect()

    def _rows(fqn: str, columns: dict[str, dict[str, Any]]) -> Iterator[dict[str, Any]]:
        from snowflake.connector import DictCursor  # noqa: PLC0415

        types = {name: spec["data_type"] for name, spec in columns.items()}
        conn = connect()
        try:
            cur = conn.cursor(DictCursor)
            cur.execute(f"SELECT * FROM {fqn}")
            for row in cur:
                out = {str(k).lower(): v for k, v in row.items()}
                yield {k: adapt_copied_value(v, types.get(k, "text")) for k, v in out.items()}
        finally:
            conn.close()

    @dlt.source(name=name, max_table_nesting=0)
    def _source() -> Any:
        for table in tables:
            fqn = qualify(database, schema, table)
            conn = connect()
            try:
                from snowflake.connector import DictCursor  # noqa: PLC0415

                columns = _column_hints(conn.cursor(DictCursor), fqn)
            finally:
                conn.close()
            log.info("resource %s reads %s (%s columns)", table, fqn, len(columns))
            yield dlt.resource(
                _rows(fqn, columns),
                name=table,
                write_disposition="replace",
                columns=columns,
            )

    return _source()
