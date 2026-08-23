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
    2. The source .............. snowflake_app
"""

from __future__ import annotations

import logging
import re
from collections.abc import Callable, Iterator
from typing import Any

import dlt

log = logging.getLogger("dlt_pipeline.snowflake_app")

# Unquoted Snowflake identifiers. The registry list is the allowlist; this
# stops a typo becoming a second statement.
IDENT_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


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

    def _rows(fqn: str) -> Iterator[dict[str, Any]]:
        from snowflake.connector import DictCursor  # noqa: PLC0415

        conn = connect()
        try:
            cur = conn.cursor(DictCursor)
            cur.execute(f"SELECT * FROM {fqn}")
            for row in cur:
                yield {str(k).lower(): v for k, v in row.items()}
        finally:
            conn.close()

    @dlt.source(name=name, max_table_nesting=0)
    def _source() -> Any:
        for table in tables:
            fqn = qualify(database, schema, table)
            log.info("resource %s reads %s", table, fqn)
            yield dlt.resource(
                _rows(fqn),
                name=table,
                write_disposition="replace",
            )

    return _source()
