"""Record that an OPS → Postgres observability copy finished.

After obs_to_postgres loads, UPSERT observability.observability_watermark.
Do not look up DLT_DB.OPS.DBT_BUILDS: an obs run is not an NFL dbt build.
source_ref is a copy-job stamp (UTC ISO timestamp), not a BUILD_ID. A
failed watermark write fails the job.
"""

from __future__ import annotations

import logging
import os
from collections.abc import Callable, Mapping
from datetime import datetime, timezone
from typing import Any

from pipelines.batch.models import PipelineSpec

log = logging.getLogger("dlt_pipeline.obs_copy_watermark")

_UPSERT_SQL = """
INSERT INTO observability.observability_watermark (table_name, copied_at, row_count, source_ref)
VALUES (%s, NOW(), %s, %s)
ON CONFLICT (table_name) DO UPDATE SET
  copied_at = EXCLUDED.copied_at,
  row_count = EXCLUDED.row_count,
  source_ref = EXCLUDED.source_ref
"""


def is_obs_copy(spec: PipelineSpec) -> bool:
    """True when this snowflake_app run writes app.observability, not APP marts."""
    if spec.dataset_name == "observability":
        return True
    return str(spec.config.get("schema") or "").upper() == "OPS"


def write_obs_copy_watermark(
    spec: PipelineSpec,
    row_counts: Mapping[str, Any],
    *,
    source_ref: str | None = None,
    upsert: Callable[[str, tuple[Any, ...]], Any] | None = None,
) -> None:
    """UPSERT one watermark row per OPS table that this run actually loaded.

    A RESOURCE= subset must not stamp row_count=0 on tables that were not copied.
    Raises on any failure.
    """
    # A table entry is a bare name or, since the incremental copy (2026-08),
    # a mapping with a `name` key (see snowflake_app_source.normalize_table).
    # Only the name matters here.
    listed: list[str] = [
        t if isinstance(t, str) else t["name"] for t in (spec.config.get("tables") or [])
    ]
    if not listed:
        raise RuntimeError(f"{spec.name}: config.tables is empty; nothing to watermark")

    present = {str(k).lower() for k in row_counts if not str(k).startswith("_dlt")}
    tables = [t for t in listed if t.lower() in present]
    if not tables:
        if not present:
            # Incremental copies load nothing on a quiet hour; that is a
            # clean no-op, not a failure. The watermark keeps its previous
            # stamps. (Before incremental, replace loaded every table every
            # run, so an empty row_counts could only mean breakage.)
            log.info("%s: no rows loaded this run; watermark untouched", spec.name)
            return
        raise RuntimeError(
            f"{spec.name}: row_counts had no listed OPS tables; refusing to watermark"
        )

    ref = source_ref or datetime.now(timezone.utc).isoformat()
    writer = upsert or _postgres_execute
    for table in tables:
        count = _row_count_for(row_counts, table)
        writer(_UPSERT_SQL, (table, count, ref))
        log.info(
            "obs watermark %s source_ref=%s row_count=%s",
            table,
            ref,
            count,
        )


def _row_count_for(row_counts: Mapping[str, Any], table: str) -> int:
    for key in (table, table.lower(), table.upper()):
        if key in row_counts:
            return int(row_counts[key] or 0)
    return 0


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
