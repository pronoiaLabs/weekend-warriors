"""Slack failure/recovery pings, sent through Snowflake from inside the run.

WHY THIS EXISTS
    The Aug 2026 dbt outage ran two days silent: failures landed in TASK_HISTORY,
    the task auto-suspended, and nothing read any of it. The fix chosen is
    IN-PROCESS alerting -- the run that fails is the thing that pings -- rather
    than a sweep reading telemetry on a schedule. The auto-suspend cascade is
    preceded by ~10 individual failures, so a ping per transition surfaces the
    problem at failure #1. The accepted blind spots, knowingly: a container that
    never starts, and a schedule that is dead without failing. No code runs in
    either, so no in-process design can see them.

    Delivery rides SYSTEM$SEND_SNOWFLAKE_NOTIFICATION over the same Snowflake
    session family the control plane already uses (snowflake_session.connect),
    so the container needs no Slack egress and carries no webhook secret. The
    integration and the ALERT_STATE latch live in sql/ops/09_alerting.sql; the
    SQL twin of this logic is SP_DBT_BUILD's handler in
    sql/sources/<sport>/05_dbt_trigger.sql.

NOISE POLICY: TRANSITIONS ONLY
    DLT_DB.OPS.ALERT_STATE holds the last known status per scope. A failure
    pings only when the scope was not already failing; a success pings only
    when it was (recovery). Everything else updates the latch silently, so a
    pipeline failing for a week costs one ping, not seven.

BEST EFFORT, LIKE record_run
    Every exit from report() is caught and logged as a warning. An alerting
    failure must never fail the run it is reporting on, and must never mask
    the exception the caller is about to re-raise. The send happens BEFORE the
    latch write: if the write then fails, the worst case is a duplicate ping
    next run, which beats a latch that says "alerted" about a ping that never
    left.

GATING
    No-op unless DLT_ALERTS == "1", which only the prod job template
    (deploy/spcs/dlt_job.tmpl.yaml) sets. Laptop runs, dev containers and CI
    stay silent without any of them knowing this module exists.
"""

from __future__ import annotations

import logging
import os
import re

log = logging.getLogger("dlt_pipeline.alerts")

# Account objects from sql/ops/09_alerting.sql. The integration name is inlined
# into the SQL text (integration references cannot be bound); the message is
# always a bind, and SANITIZE_WEBHOOK_CONTENT strips placeholder tokens
# server-side so error text cannot smuggle SNOWFLAKE_WEBHOOK_SECRET out.
_INTEGRATION = "SLACK_ALERTS_INT"
_STATE_TABLE = "DLT_DB.OPS.ALERT_STATE"

# Slack renders the whole message inline; TASK_HISTORY holds the full text.
_ERROR_LIMIT = 400
_CAUSE_LIMIT = 300

# dlt load-failure fields, as they appear in str(PipelineStepFailed) e.g.:
#   Pipeline execution failed at `step=load` when processing package with
#   `load_id=1787548486.42` ... Job with `job_id=app_player_weeks.994a.insert_values.gz`
#   had 5 retries which is a multiple of `max_retry_count=5`. ...
#   Last failure message was: Traceback (most recent call last): ...
_STEP_RE = re.compile(r"step=`?([a-z_]+)`?")
_LOAD_ID_RE = re.compile(r"load_id=`?(\d+\.\d+|\d+)`?")
_JOB_ID_RE = re.compile(r"job_id=`?([A-Za-z0-9_][A-Za-z0-9_.\-]*)`?")
_RETRIES_RE = re.compile(r"had (\d+) retries.*?max_retry_count=`?(\d+)`?", re.S)

_SEND_SQL = (
    "CALL SYSTEM$SEND_SNOWFLAKE_NOTIFICATION("
    "SNOWFLAKE.NOTIFICATION.TEXT_PLAIN("
    "SNOWFLAKE.NOTIFICATION.SANITIZE_WEBHOOK_CONTENT(%s)),"
    f"SNOWFLAKE.NOTIFICATION.INTEGRATION('{_INTEGRATION}'))"
)

_MERGE_SQL = (
    f"MERGE INTO {_STATE_TABLE} t USING (SELECT %s AS SCOPE) s ON t.SCOPE = s.SCOPE "
    "WHEN MATCHED THEN UPDATE SET STATUS = %s, UPDATED_AT = CURRENT_TIMESTAMP(), "
    "LAST_ALERTED_AT = IFF(%s, CURRENT_TIMESTAMP(), t.LAST_ALERTED_AT), LAST_ERROR = %s "
    "WHEN NOT MATCHED THEN INSERT (SCOPE, STATUS, UPDATED_AT, LAST_ALERTED_AT, LAST_ERROR) "
    "VALUES (s.SCOPE, %s, CURRENT_TIMESTAMP(), "
    "IFF(%s, CURRENT_TIMESTAMP(), NULL), %s)"
)


def enabled() -> bool:
    """True when this environment is allowed to ping (prod containers only)."""
    return os.environ.get("DLT_ALERTS") == "1"


def decide(prev_status: str | None, ok: bool) -> str | None:
    """The transition rule: 'fail', 'recover', or None (stay silent).

    Pure so the whole ping/no-ping matrix is unit-testable without a
    connection. `prev_status` is the ALERT_STATE row ('ok' | 'failing') or
    None when the scope has never been seen -- and an unseen scope that fails
    DOES ping, because "first failure ever" is exactly a healthy->failing
    transition.
    """
    if not ok:
        return None if prev_status == "failing" else "fail"
    return "recover" if prev_status == "failing" else None


def _root_cause(error: str) -> str | None:
    """The actual error line out of a traceback, or None when there is none.

    Python prints chained tracebacks oldest-first, so the FIRST non-indented
    exception line after the first ``Traceback`` marker is the root cause
    (psycopg2.errors.OutOfMemory), not the dlt wrapper that re-raised it.
    """
    lines = error.splitlines()
    it = iter(lines)
    for line in it:
        # dlt embeds the first marker mid-line ("Last failure message was:
        # Traceback (most recent call last):"), so substring, not startswith.
        if "Traceback (most recent call last)" in line:
            break
    else:
        return None
    for line in it:
        if not line.strip():
            continue
        if line.startswith((" ", "\t")):
            continue
        if line.startswith(("Traceback", "During handling", "The above exception")):
            continue
        return line.strip()[:_CAUSE_LIMIT]
    return None


def format_message(scope: str, ok: bool, error: str | None = None) -> str:
    """Slack mrkdwn, worst news first, root cause on line two.

    A dlt load failure buries the one line that matters (the traceback tail)
    behind retry boilerplate, and Slack truncation was cutting exactly that
    off (the OOM night, 2026-08-24). So when the dlt fields are present the
    message is restructured: bold scope, then the cause inside backticks
    where no truncation can reach it, then the parsed job fields. Anything
    unparseable keeps the old flattened one-liner. mrkdwn, not Markdown:
    bold is a single ``*``.
    """
    if ok:
        return f"*RECOVERED {scope}*"

    error = error or "unknown error"
    cause = _root_cause(error)
    step = _STEP_RE.search(error)
    load_id = _LOAD_ID_RE.search(error)
    job_id = _JOB_ID_RE.search(error)
    retries = _RETRIES_RE.search(error)

    if cause is None and job_id is None and step is None:
        snippet = " ".join(error.split())[:_ERROR_LIMIT]
        return f"*FAILED {scope}*: {snippet}"

    if cause is None:
        # dlt fields without a traceback: the first line is the best cause.
        cause = " ".join(error.split())[:_CAUSE_LIMIT]

    # One metric per line: scannable on a phone notification, and a missing
    # field simply drops its line rather than leaving a gap mid-row.
    parts = [f"*FAILED {scope}*", f"cause: `{cause}`"]
    if job_id:
        parts.append(f"table: `{job_id.group(1).split('.')[0]}`")
    if step:
        parts.append(f"step: {step.group(1)}")
    if retries:
        parts.append(f"retries: {retries.group(1)}/{retries.group(2)}")
    if load_id:
        parts.append(f"load_id: {load_id.group(1)}")
    return "\n".join(parts)


def report(scope: str, ok: bool, error: str | None = None) -> None:
    """Record the outcome for *scope*, pinging Slack when the status flips.

    Called by run.py on every pipeline outcome (scope = pipeline name) and on
    registry-resolution death (scope = 'runner'). Opens one short-lived
    control-plane connection per call; against a run that already spends a
    third of its wall time on record_run's second dlt pipeline, this is noise.
    """
    if not enabled():
        return

    try:
        # Deferred like snowflake_session's own connector import: the DuckDB
        # and YAML paths must work on a machine without the connector installed.
        from pipelines.common.snowflake_session import connect  # noqa: PLC0415

        conn = connect()
        try:
            cur = conn.cursor()
            cur.execute(f"SELECT STATUS FROM {_STATE_TABLE} WHERE SCOPE = %s", (scope,))
            row = cur.fetchone()
            prev = row[0] if row else None

            action = decide(prev, ok)
            if action is None and ok:
                # Healthy stayed healthy: no ping, and no row churn either --
                # the latch only needs writing when there is something to latch.
                return

            if action is not None:
                # Raw newlines break the webhook: Snowflake substitutes the
                # message into the integration's JSON body WITHOUT escaping,
                # and the parse fails server-side ("Unexpected JSON error
                # while parsing Webhook Body", measured 2026-08-24). The
                # two-character \n sequence IS the JSON-escaped newline;
                # Slack renders it as a line break after parsing.
                message = format_message(scope, ok, error).replace("\n", "\\n")
                cur.execute(_SEND_SQL, (message,))
                log.info("alert sent (%s) for scope '%s'", action, scope)

            status = "ok" if ok else "failing"
            snippet = " ".join(error.split())[:_ERROR_LIMIT] if error and not ok else None
            sent = action is not None
            cur.execute(
                _MERGE_SQL,
                (scope, status, sent, snippet, status, sent, snippet),
            )
            conn.commit()
        finally:
            conn.close()

    except Exception as exc:  # noqa: BLE001, alerting must never fail the run
        log.warning("alert report failed for scope '%s': %s", scope, exc)
