"""Structured logging and run-metadata collection for the dlt pipeline runner.

WHY THIS EXISTS
    A pipeline that only writes data tells you nothing about itself. This module adds
    the two things you need to operate one: log lines that carry the pipeline name, and
    a durable row per run in Snowflake saying what happened.

    The run record is deliberately *best effort*. Telemetry that can break a data load
    is worse than no telemetry, so every failure here is caught and downgraded to a
    warning.

CONTENTS
    1. Structured logging ...... _PipelineDefaultFilter, configure_logging
    2. Run metadata ............ _RUN_COLUMNS, record_run

PUBLIC ENTRY POINTS
    configure_logging(pipeline_name) -> logging.LoggerAdapter
        Attaches a structured formatter to the "dlt_pipeline" logger (once) and returns
        an adapter that injects {"pipeline": pipeline_name} into every log record.

    record_run(spec, *, status, load_id, row_counts, error) -> None
        Writes one row to <destination database>.OPS._DLT_RUNS via a transient dlt
        pipeline.

WHERE THE RUN RECORD LANDS
    The OPS schema is per environment, not central: the dataset is always "OPS" but the
    database is whichever one the destination is pointed at. So dev runs land in
    DLT_DEV_DB.OPS._DLT_RUNS and scheduled prod runs in DLT_PROD_DB.OPS._DLT_RUNS.

    Do not confuse this with DLT_DB, the control plane. DLT_DB.OPS holds
    PIPELINE_REGISTRY, which is configuration created by sql/base/03_registry.sql. Run
    history is not configuration and is deliberately kept beside the data it describes.

    Neither the schema nor the table is created here. sql/dev/01_dev_db.sql and
    sql/prod/01_prod_db.sql create the OPS schema and grant CREATE TABLE; dlt creates
    _DLT_RUNS and alters it as the column hints below change.
"""

from __future__ import annotations

import logging
import os
from datetime import datetime, timezone
from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:
    from pipelines.batch.models import PipelineSpec

_LOG_CONFIGURED: bool = False


# ---------------------------------------------------------------------------
# 1. Structured logging
#
# One handler on the "dlt_pipeline" logger, attached once per process. Callers get a
# LoggerAdapter rather than the logger itself, which is how the pipeline name reaches
# every record without each call site passing it.
# ---------------------------------------------------------------------------


class _PipelineDefaultFilter(logging.Filter):
    """Ensure every record has a `pipeline` attribute.

    The handler's formatter references %(pipeline)s, but records emitted without a
    LoggerAdapter (module-level `log`, and record_run's warnings) do not set it.
    Without this, formatting raises KeyError('pipeline') and floods stderr. A logging
    filter is the right hook because it runs on every record regardless of origin.
    """

    def filter(self, record: logging.LogRecord) -> bool:
        if not hasattr(record, "pipeline"):
            record.pipeline = "-"
        return True


def configure_logging(pipeline_name: str) -> logging.LoggerAdapter:
    """Attach a structured handler to the 'dlt_pipeline' logger (idempotent).

    Uses SnowflakeLogFormatter when the snowflake.telemetry package is available
    (in-Snowflake / SPCS), so logs land in the account's event table already parsed.
    Falls back to a plain Formatter so the runner works in local dev without the
    package installed. That fallback is why the import is inside a try, not at module
    top: local development must not require a Snowflake-only dependency.

    Level is read from the LOG_LEVEL env var (default: INFO).
    """
    global _LOG_CONFIGURED

    base = logging.getLogger("dlt_pipeline")

    # Guarded so repeated calls (one per pipeline in a group run) do not stack
    # duplicate handlers and print every line N times.
    if not _LOG_CONFIGURED:
        _LOG_CONFIGURED = True

        level_name: str = os.environ.get("LOG_LEVEL", "INFO").upper()
        level: int = getattr(logging, level_name, logging.INFO)
        base.setLevel(level)

        handler = logging.StreamHandler()
        handler.setLevel(level)
        handler.addFilter(_PipelineDefaultFilter())

        try:
            from snowflake.telemetry.logs import SnowflakeLogFormatter  # type: ignore[import]

            formatter: logging.Formatter = SnowflakeLogFormatter()
        except Exception:  # noqa: BLE001, package absent in local dev
            formatter = logging.Formatter(
                "%(asctime)s %(levelname)s %(name)s [pipeline=%(pipeline)s] %(message)s"
            )

        handler.setFormatter(formatter)
        base.addHandler(handler)

    return logging.LoggerAdapter(base, {"pipeline": pipeline_name})


# ---------------------------------------------------------------------------
# 2. Run metadata
#
# Explicit column hints for _DLT_RUNS. Without them dlt infers the schema from
# whatever a given run happened to produce, which breaks this table in two ways.
#
#   row_counts is a dict keyed by TABLE NAME. Left to inference, dlt normalizes it
#   into a child table with one column per table name it has ever seen, so the schema
#   grows without bound as pipelines and resources are added. Typing it as `json`
#   keeps it in one column (VARIANT on Snowflake), still queryable there.
#
#   error, load_id, resources and params are null on most runs. A column that receives
#   no data during a load cannot have its type inferred, so dlt does not create it at
#   all. The result is backwards: `error`, the column you query to find failures, is
#   missing until the first failure creates it, and every dashboard selecting it breaks
#   on a healthy account.
#
# Both are silent. Neither shows up as a failed load.
# ---------------------------------------------------------------------------

_RUN_COLUMNS: dict[str, Any] = {
    "row_counts": {"data_type": "json"},
    "error": {"data_type": "text"},
    "load_id": {"data_type": "text"},
    "resources": {"data_type": "text"},
    "params": {"data_type": "json"},
}


def record_run(
    spec: PipelineSpec,
    *,
    status: str,
    load_id: str | None,
    row_counts: dict[str, Any] | None,
    error: str | None = None,
    resources: list[str] | None = None,
    params: dict[str, Any] | None = None,
) -> None:
    """Append one run-metadata row to <destination database>.OPS._DLT_RUNS.

    The database follows the destination, so this is DLT_DEV_DB.OPS in dev and
    DLT_PROD_DB.OPS in prod. It is not DLT_DB, which is the control plane.

    *resources* is the run's resource filter, stored as a comma-separated list and
    NULL when the whole pipeline ran. Without it a partial run is indistinguishable
    from a full one, and its `row_counts` looks like the pipeline's complete output
    when it covers only part of it. `WHERE resources IS NOT NULL` finds them.

    *params* is the run's query-parameter override, for the same reason: two backfills
    of the same resource for different seasons are otherwise identical rows. It is
    typed `json` rather than text because the values are already a mapping and one key
    may hold several values.

    This function is *best effort*: any exception is caught and logged as a warning so
    a telemetry failure never blocks the actual data load. That is a deliberate
    trade. If this table goes stale you lose visibility, but you do not lose data.

    Note this opens a second dlt pipeline and its own Snowflake connections, so it
    costs real wall time (roughly a third of total on a small load). Worth knowing
    before it runs per-pipeline on a schedule.
    """
    _log = logging.getLogger("dlt_pipeline")

    try:
        import dlt  # noqa: PLC0415, deferred to avoid hard dep at module load

        # Follow the caller's destination override so the run record lands beside the
        # data it describes, rather than wherever the spec's default points.
        destination: str = os.environ.get("DLT_DESTINATION") or spec.destination

        ops_pipeline = dlt.pipeline(
            pipeline_name="ops_meta",
            destination=destination,
            dataset_name="OPS",
        )

        record: dict[str, Any] = {
            "pipeline": spec.name,
            "load_id": load_id,
            "status": status,
            "row_counts": row_counts,
            "error": error,
            "resources": ",".join(resources) if resources else None,
            "params": params,
            "finished_at": datetime.now(timezone.utc).isoformat(),
        }

        ops_pipeline.run(
            [record],
            table_name="_dlt_runs",
            write_disposition="append",
            columns=_RUN_COLUMNS,
        )

    except Exception as exc:  # noqa: BLE001
        _log.warning(
            "record_run failed for pipeline '%s' (status=%s): %s",
            spec.name,
            status,
            exc,
        )
