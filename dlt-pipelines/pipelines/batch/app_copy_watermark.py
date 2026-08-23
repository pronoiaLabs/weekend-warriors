"""Record which dbt build an APP → Postgres copy came from.

After nfl_app_to_postgres loads, UPSERT app_copy.app_copy_watermark from the
latest DLT_DB.OPS.DBT_BUILDS row for that sport. A failed watermark write
fails the job: a copy with no build id is worse than no copy.
"""

from __future__ import annotations

import logging
import os
from collections.abc import Callable, Mapping
from typing import Any

from pipelines.batch.models import PipelineSpec

log = logging.getLogger("dlt_pipeline.app_copy_watermark")

# Sport is the registry database stem (already validated as an identifier).
_LATEST_BUILD_SQL = """
SELECT BUILD_ID
FROM DLT_DB.OPS.DBT_BUILDS
WHERE LOWER(SPORT) = '{sport}'
ORDER BY FINISHED_AT DESC
LIMIT 1
"""

_UPSERT_SQL = """
INSERT INTO app_copy.app_copy_watermark (sport, table_name, source_build_id, copied_at, row_count)
VALUES (%s, %s, %s, NOW(), %s)
ON CONFLICT (sport, table_name) DO UPDATE SET
  source_build_id = EXCLUDED.source_build_id,
  copied_at = EXCLUDED.copied_at,
  row_count = EXCLUDED.row_count
"""


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
) -> None:
    """UPSERT one watermark row per APP table that this run actually loaded.

    A RESOURCE= subset must not stamp row_count=0 on tables that were not copied.
    Raises on any failure.
    """
    sport = spec.database.lower()
    listed: list[str] = list(spec.config.get("tables") or [])
    if not listed:
        raise RuntimeError(f"{spec.name}: config.tables is empty; nothing to watermark")

    present = {str(k).lower() for k in row_counts if not str(k).startswith("_dlt")}
    tables = [t for t in listed if t.lower() in present]
    if not tables:
        raise RuntimeError(
            f"{spec.name}: row_counts had no listed APP tables; refusing to watermark"
        )

    build_id = (fetch_build_id or latest_build_id)(sport)
    writer = upsert or _postgres_execute
    for table in tables:
        count = _row_count_for(row_counts, table)
        writer(_UPSERT_SQL, (sport, table, build_id, count))
        log.info(
            "watermark %s.%s build_id=%s row_count=%s",
            sport,
            table,
            build_id,
            count,
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


def _postgres_execute(sql: str, params: tuple[Any, ...]) -> None:
    import psycopg2  # noqa: PLC0415

    conn = psycopg2.connect(
        host=os.environ["DESTINATION__POSTGRES__CREDENTIALS__HOST"],
        port=os.environ.get("DESTINATION__POSTGRES__CREDENTIALS__PORT", "5432"),
        dbname=os.environ.get("DESTINATION__POSTGRES__CREDENTIALS__DATABASE", "app"),
        user=os.environ["DESTINATION__POSTGRES__CREDENTIALS__USERNAME"],
        password=os.environ["DESTINATION__POSTGRES__CREDENTIALS__PASSWORD"],
        sslmode=os.environ.get("PGSSLMODE", "require"),
    )
    try:
        with conn:
            with conn.cursor() as cur:
                cur.execute(sql, params)
    finally:
        conn.close()
