"""Manual observability refresh: the dashboard's freshness valve.

The scheduled path is hourly (OBS_REFRESH and DBT_RUNS_REFRESH run at a 3600s
trigger interval, and the Postgres copy is latched to about one run an hour).
This endpoint is the in-between for "I need it now": it CALLs the guarded ops
procs directly over a short-lived Snowflake connection, whatever backend the
pages read from.

  - SP_OBS_SWEEP / SP_DBT_RUNS_SWEEP are the in-flight-guarded wrappers
    around the refresh procs. EXECUTE TASK is deliberately not used: it
    would silently no-op whenever the streams happen to be empty.
  - SP_OBS_COPY_FIRE(TRUE) forces past the hourly latch but keeps both
    in-flight guards: a manual refresh may jump the queue, never stack a
    second copy onto the shared Postgres instance (the 2026-08-24 OOM).

The copy container takes minutes; the response reports each proc's
fired/skipped message and the pages' refreshed_at fields show when data
lands. All three procs need real privileges on the connection's role
(EXECUTE TASK, TASK_HISTORY): a shortfall surfaces here as an error message,
not a silent no-op.
"""

from fastapi import APIRouter, HTTPException

from app import db

router = APIRouter(tags=["refresh"])

_CALLS = (
    ("obs_refresh", "CALL DLT_DB.OPS.SP_OBS_SWEEP()"),
    ("dbt_runs_refresh", "CALL DLT_DB.OPS.SP_DBT_RUNS_SWEEP()"),
    ("obs_copy", "CALL DLT_DB.OPS.SP_OBS_COPY_FIRE(TRUE)"),
)


@router.post("/api/refresh")
def refresh() -> dict[str, str]:
    try:
        conn = db.snowflake_connection()
    except Exception as exc:
        raise HTTPException(status_code=502, detail=f"snowflake connection failed: {exc}") from exc

    results: dict[str, str] = {}
    try:
        cur = conn.cursor()
        try:
            # Each call stands alone: a failed sweep must not stop the copy
            # fire, and the caller sees exactly which step said what.
            for key, statement in _CALLS:
                try:
                    cur.execute(statement)
                    row = cur.fetchone()
                    results[key] = str(row[0]) if row else "ok"
                except Exception as exc:  # noqa: BLE001
                    results[key] = f"error: {exc}"
        finally:
            cur.close()
    finally:
        conn.close()
    return results
