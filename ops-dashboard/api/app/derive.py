"""Anomaly classification and severity ranking.

Severity is a class, not a score, but the sport-panel "worst" badge still needs
an ordering. The ranking encodes the design's argument: RECORD MISSING outranks
FAILURE because it destroys its own evidence; MISSED SLOT sits beside it because
it removes even the failure; DISAGREEMENT is a finding, kept out of the red
ladder entirely on the page, but it still beats "ok" for worst-of purposes.

TASK_STATE and DLT_STATUS are never merged here or anywhere downstream.
"""

from typing import Any

# Worst first. "missing" = DLT_RECORD_MISSING, "missed" = an expanded cron slot
# with no run row at all.
SEVERITY_ORDER = ["missing", "missed", "failure", "disagree", "ok"]

_RANK = {kind: i for i, kind in enumerate(SEVERITY_ORDER)}


def run_anomalies(run: dict[str, Any]) -> list[str]:
    """Anomaly kinds carried by one V_PIPELINE_RUNS row (may be several)."""
    kinds: list[str] = []
    if run.get("dlt_record_missing"):
        kinds.append("missing")
    if run.get("task_state") == "FAILED" and not run.get("dlt_record_missing"):
        kinds.append("failure")
    if run.get("outcome_disagrees"):
        kinds.append("disagree")
    return kinds


def worst(kinds: list[str]) -> str:
    return min(kinds, default="ok", key=lambda k: _RANK.get(k, len(_RANK)))


def error_provenance(run: dict[str, Any]) -> str | None:
    """Which source ERROR_TEXT resolved from, computed per run.

    The view is COALESCE(dlt.ERROR, TASK_ERROR_MESSAGE). A run that never made
    it into _DLT_RUNS can only have the Task message; a run dlt recorded as
    failed carries dlt's exception, which the COALESCE prefers.
    """
    if run.get("error_text") is None:
        return None
    if run.get("dlt_record_missing") or run.get("dlt_status") is None:
        return "TASK_HISTORY.ERROR_MESSAGE"
    if run.get("dlt_status") == "failed":
        return "_DLT_RUNS.ERROR (dlt exception)"
    return "TASK_HISTORY.ERROR_MESSAGE"
