"""Record which dbt build an APP → Postgres copy came from.

Before nfl_app_to_postgres loads, compare Snowflake HASH_AGG values with the
last successful values in app_copy.app_copy_watermark so unchanged resources
can be skipped. After the load, UPSERT copied tables with the latest build id,
row count and hash. A failed watermark write fails the job: a copy with no
lineage is worse than no copy.
"""

from __future__ import annotations

import logging
import os
import re
from collections.abc import Callable, Mapping
from typing import Any

from pipelines.batch.models import PipelineSpec, resolve_database

log = logging.getLogger("dlt_pipeline.app_copy_watermark")

_IDENT_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")

# Sport is the registry database stem (already validated as an identifier).
_LATEST_BUILD_SQL = """
SELECT BUILD_ID
FROM DLT_DB.OPS.DBT_BUILDS
WHERE LOWER(SPORT) = '{sport}'
ORDER BY FINISHED_AT DESC
LIMIT 1
"""

_UPSERT_SQL = """
INSERT INTO app_copy.app_copy_watermark
    (sport, table_name, source_build_id, copied_at, row_count, content_hash)
VALUES (%s, %s, %s, NOW(), %s, %s)
ON CONFLICT (sport, table_name) DO UPDATE SET
  source_build_id = EXCLUDED.source_build_id,
  copied_at = EXCLUDED.copied_at,
  row_count = EXCLUDED.row_count,
  content_hash = COALESCE(EXCLUDED.content_hash, app_copy_watermark.content_hash)
"""

_READ_HASHES_SQL = """
SELECT table_name, content_hash
FROM app_copy.app_copy_watermark
WHERE sport = %s
"""


def listed_table_names(spec: PipelineSpec) -> list[str]:
    """Return configured table names from bare or per-table mapping entries."""
    names: list[str] = []
    for entry in spec.config.get("tables") or []:
        name = entry if isinstance(entry, str) else entry.get("name")
        if not isinstance(name, str) or not _IDENT_RE.match(name):
            raise RuntimeError(f"{spec.name}: invalid APP table entry {entry!r}")
        names.append(name)
    if not names:
        raise RuntimeError(f"{spec.name}: config.tables is empty; nothing to copy")
    return names


def current_table_signatures(
    spec: PipelineSpec,
    *,
    tables: list[str] | None = None,
    fetch_signature: Callable[[str], Any] | None = None,
) -> dict[str, tuple[str, int]]:
    """Return Snowflake content hashes and row counts for selected APP tables."""
    database = str(spec.config.get("database") or resolve_database(spec, "PROD"))
    schema = str(spec.config.get("schema") or "APP")
    for ident, label in ((database, "database"), (schema, "schema")):
        if not _IDENT_RE.match(ident):
            raise RuntimeError(f"{spec.name}: invalid APP {label} {ident!r}")

    listed = listed_table_names(spec)
    selected = tables or listed
    unknown = set(selected) - set(listed)
    if unknown:
        raise RuntimeError(
            f"{spec.name}: cannot fingerprint unlisted table(s): {', '.join(sorted(unknown))}"
        )
    queries = {
        table: f"SELECT HASH_AGG(*), COUNT(*) FROM {database}.{schema}.{table}"
        for table in selected
    }
    if fetch_signature is None:
        rows = _snowflake_hashes(queries)
    else:
        rows = {table: fetch_signature(sql) for table, sql in queries.items()}

    signatures: dict[str, tuple[str, int]] = {}
    for table, row in rows.items():
        if not isinstance(row, (tuple, list)) or len(row) < 2 or row[0] is None:
            raise RuntimeError(f"{spec.name}: invalid HASH_AGG/COUNT result for {table}: {row!r}")
        signatures[table.lower()] = (str(row[0]), int(row[1]))
    return signatures


def stored_content_hashes(
    spec: PipelineSpec,
    *,
    fetch: Callable[[str, tuple[Any, ...]], Any] | None = None,
) -> dict[str, str]:
    """Read the last successfully copied content hashes from Postgres."""
    rows = (fetch or _postgres_fetchall)(_READ_HASHES_SQL, (spec.database.lower(),))
    return {
        str(table).lower(): str(content_hash)
        for table, content_hash in rows
        if content_hash is not None
    }


def changed_tables(
    spec: PipelineSpec,
    current_hashes: Mapping[str, str],
    stored_hashes: Mapping[str, str],
) -> list[str]:
    """Return configured tables whose current content is not already in Postgres."""
    return [
        table
        for table in listed_table_names(spec)
        if stored_hashes.get(table.lower()) != current_hashes.get(table.lower())
    ]


def latest_build_id(sport: str, execute: Callable[[str], Any] | None = None) -> str:
    """Return BUILD_ID of the newest successful build for *sport*."""
    stem = sport.lower()
    if not stem.replace("_", "").isalnum() or stem[0].isdigit():
        raise RuntimeError(f"watermark sport is not an identifier: {sport!r}")
    if execute is None:
        execute = _snowflake_fetchone
    row = execute(_LATEST_BUILD_SQL.format(sport=stem))
    if not row or not row[0]:
        raise RuntimeError(
            f"no DLT_DB.OPS.DBT_BUILDS row for sport {sport!r}; "
            "refusing to watermark a copy with no source build"
        )
    return str(row[0])


def write_app_copy_watermark(
    spec: PipelineSpec,
    row_counts: Mapping[str, Any],
    *,
    fetch_build_id: Callable[[str], str] | None = None,
    upsert: Callable[[str, tuple[Any, ...]], Any] | None = None,
    content_hashes: Mapping[str, str] | None = None,
    source_row_counts: Mapping[str, int] | None = None,
) -> None:
    """UPSERT one watermark row per APP table that this run actually loaded.

    A RESOURCE= subset must not stamp row_count=0 on tables that were not copied.
    Raises on any failure.
    """
    sport = spec.database.lower()
    listed = listed_table_names(spec)

    authoritative_counts = source_row_counts if source_row_counts is not None else row_counts
    present = {
        str(k).lower()
        for k in authoritative_counts
        if not str(k).startswith("_dlt")
    }
    tables = [t for t in listed if t.lower() in present]
    if not tables:
        raise RuntimeError(
            f"{spec.name}: row_counts had no listed APP tables; refusing to watermark"
        )

    build_id = (fetch_build_id or latest_build_id)(sport)
    writer = upsert or _postgres_execute
    for table in tables:
        count = _row_count_for(authoritative_counts, table)
        content_hash = (content_hashes or {}).get(table.lower())
        writer(_UPSERT_SQL, (sport, table, build_id, count, content_hash))
        log.info(
            "watermark %s.%s build_id=%s row_count=%s content_hash=%s",
            sport,
            table,
            build_id,
            count,
            content_hash,
        )


def _row_count_for(row_counts: Mapping[str, Any], table: str) -> int:
    for key in (table, table.lower(), table.upper()):
        if key in row_counts:
            return int(row_counts[key] or 0)
    return 0


def _snowflake_fetchone(sql: str) -> Any:
    from pipelines.common.snowflake_session import connect  # noqa: PLC0415

    conn = connect()
    try:
        cur = conn.cursor()
        cur.execute(sql)
        return cur.fetchone()
    finally:
        conn.close()


def _snowflake_hashes(queries: Mapping[str, str]) -> dict[str, Any]:
    from pipelines.common.snowflake_session import connect  # noqa: PLC0415

    conn = connect()
    try:
        cur = conn.cursor()
        try:
            rows: dict[str, Any] = {}
            for table, sql in queries.items():
                cur.execute(sql)
                rows[table] = cur.fetchone()
            return rows
        finally:
            cur.close()
    finally:
        conn.close()


def _postgres_connect() -> Any:
    import psycopg2  # noqa: PLC0415

    return psycopg2.connect(
        host=os.environ["DESTINATION__POSTGRES__CREDENTIALS__HOST"],
        port=os.environ.get("DESTINATION__POSTGRES__CREDENTIALS__PORT", "5432"),
        dbname=os.environ.get("DESTINATION__POSTGRES__CREDENTIALS__DATABASE", "app"),
        user=os.environ["DESTINATION__POSTGRES__CREDENTIALS__USERNAME"],
        password=os.environ["DESTINATION__POSTGRES__CREDENTIALS__PASSWORD"],
        sslmode=os.environ.get("PGSSLMODE", "require"),
    )


def _postgres_fetchall(sql: str, params: tuple[Any, ...]) -> Any:
    conn = _postgres_connect()
    try:
        with conn.cursor() as cur:
            cur.execute(sql, params)
            return cur.fetchall()
    finally:
        conn.close()


def _postgres_execute(sql: str, params: tuple[Any, ...]) -> None:
    conn = _postgres_connect()
    try:
        with conn:
            with conn.cursor() as cur:
                cur.execute(sql, params)
    finally:
        conn.close()
