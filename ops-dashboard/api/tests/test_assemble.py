"""Assembly rules against hand-built runs plus the recorded fixtures.

These encode the wireframe's design rules so a regression is a test failure,
not a silent dashboard lie.
"""

from datetime import UTC, date, datetime

from app import assemble, derive

NOW = datetime(2026, 8, 8, 19, 0, tzinfo=UTC)
DAY = date(2026, 8, 8)


def _run(pipeline: str, at: str, **overrides: object) -> dict[str, object]:
    base: dict[str, object] = {
        "sport": "NFL",
        "pipeline": pipeline,
        "query_id": f"qid-{pipeline}-{at}",
        "run_started_at": at,
        "run_ended_at": at,
        "duration_s": 90,
        "task_state": "SUCCEEDED",
        "dlt_status": "ok",
        "outcome_disagrees": False,
        "dlt_record_missing": False,
        "rows_loaded": 100,
        "row_counts": {"t": 100},
        "error_text": None,
    }
    base.update(overrides)
    return base


PIPES = [
    {"name": "nfl_a", "sport": "NFL", "schedule": "0 10 * * *", "enabled": True},
    {"name": "nfl_b", "sport": "NFL", "schedule": "0 12 * * *", "enabled": True},
]


def test_missed_slot_counts_and_renders_a_missed_card() -> None:
    # nfl_b never ran; its 12:00 slot passed the grace period hours ago. The
    # slate is the surviving reader of _match_slots, so the slot rule is
    # asserted through it rather than through the retired incident feed.
    runs = [_run("nfl_a", "2026-08-08T10:00:30.000Z")]
    out = assemble.slate(PIPES, runs, [], NOW, DAY, radius=0)

    today = out["days"][0]
    assert today["date"] == DAY.isoformat()
    assert today["ran"] == 1
    assert today["missed"] == 1

    cards = out["leagues"][0]["cards"]
    missed = [c for c in cards if c["kind"] == "missed"]
    assert len(missed) == 1
    assert missed[0]["pipeline"] == "nfl_b"
    assert missed[0]["query_id"] is None


def test_record_missing_outranks_failure() -> None:
    assert derive.worst(["failure", "missing"]) == "missing"
    assert derive.worst(["disagree", "failure"]) == "failure"
    assert derive.worst([]) == "ok"


def test_record_missing_run_reads_missing_not_failure() -> None:
    # A FAILED task whose dlt row never landed is classified "missing", not
    # "failure", and its ERROR_TEXT can only have come from TASK_HISTORY. The
    # incident feed used to be where this was read; run_detail carries the same
    # two derived fields, so the rule is asserted there now.
    run = _run(
        "nfl_a",
        "2026-08-08T10:00:30.000Z",
        task_state="FAILED",
        dlt_status=None,
        dlt_record_missing=True,
        rows_loaded=None,
        row_counts=None,
        error_text="Job JOB_X failed to complete. Exited with status: FAILED.",
    )
    detail = assemble.run_detail(run, [run])
    assert detail["anomalies"] == ["missing"]
    assert detail["state"] == "missing"
    assert detail["error_provenance"] == "TASK_HISTORY.ERROR_MESSAGE"


def test_run_detail_prev_row_counts_skips_null_runs() -> None:
    current = _run("nfl_a", "2026-08-08T10:00:30.000Z")
    failed = _run(
        "nfl_a", "2026-08-07T10:00:30.000Z", task_state="FAILED", row_counts=None, rows_loaded=None
    )
    older = _run("nfl_a", "2026-08-06T10:00:30.000Z", row_counts={"t": 90})
    detail = assemble.run_detail(current, [current, failed, older])
    assert detail["prev_row_counts"] == {"t": 90}
    assert [p["state"] for p in detail["prior_runs"]] == ["failure", "succeeded"]


def test_heatmap_covers_window_and_marks_future_none() -> None:
    pipe = {"name": "nfl_a", "sport": "NFL", "schedule": "0 10 * * *", "enabled": True}
    runs = [_run("nfl_a", "2026-08-08T10:00:30.000Z")]
    detail = assemble.pipeline_detail(pipe, runs, NOW, limit=8)
    assert len(detail["heatmap"]) == assemble.WINDOW_DAYS
    assert detail["heatmap"][-1]["date"] == "2026-08-08"
    assert detail["heatmap"][-1]["state"] == "succeeded"
    # Days with a slot but no run (pipeline history predates the fleet) read missed.
    assert detail["heatmap"][0]["state"] == "missed"
