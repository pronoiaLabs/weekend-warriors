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


def test_healthy_pipeline_renders_no_card() -> None:
    runs = [
        _run("nfl_a", "2026-08-08T10:00:30.000Z"),
        _run("nfl_b", "2026-08-08T12:00:30.000Z"),
    ]
    out = assemble.overview(PIPES, runs, NOW, DAY)
    panel = out["sports"][0]
    assert panel["anomaly_count"] == 0
    assert panel["healthy_count"] == 2
    assert panel["worst"] == "ok"


def test_failed_latest_run_renders_card_and_worst() -> None:
    runs = [
        _run("nfl_a", "2026-08-08T10:00:30.000Z", task_state="FAILED", dlt_status="failed"),
        _run("nfl_b", "2026-08-08T12:00:30.000Z"),
    ]
    panel = assemble.overview(PIPES, runs, NOW, DAY)["sports"][0]
    assert panel["anomaly_count"] == 1
    assert panel["cards"][0]["pipeline"] == "nfl_a"
    assert panel["worst"] == "failure"


def test_missed_slot_counts_and_files_incident() -> None:
    # nfl_b never ran; its 12:00 slot passed the grace period hours ago.
    runs = [_run("nfl_a", "2026-08-08T10:00:30.000Z")]
    out = assemble.overview(PIPES, runs, NOW, DAY)
    assert out["summary"]["missed_today"] == 1
    inc = assemble.incidents(PIPES, runs, NOW, days=1)
    missed = [e for e in inc["incidents"] if e["kind"] == "missed"]
    assert len(missed) == 1
    assert missed[0]["pipeline"] == "nfl_b"
    assert missed[0]["query_id"] is None


def test_disagreement_is_a_card_even_when_task_succeeded() -> None:
    runs = [
        _run("nfl_a", "2026-08-08T10:00:30.000Z", outcome_disagrees=True, dlt_status="failed"),
        _run("nfl_b", "2026-08-08T12:00:30.000Z"),
    ]
    panel = assemble.overview(PIPES, runs, NOW, DAY)["sports"][0]
    assert panel["cards"][0]["pipeline"] == "nfl_a"
    assert panel["cards"][0]["task_state"] == "SUCCEEDED"
    assert panel["cards"][0]["dlt_status"] == "failed"


def test_record_missing_outranks_failure() -> None:
    assert derive.worst(["failure", "missing"]) == "missing"
    assert derive.worst(["disagree", "failure"]) == "failure"
    assert derive.worst([]) == "ok"


def test_record_missing_run_files_missing_incident_not_failure() -> None:
    runs = [
        _run(
            "nfl_a",
            "2026-08-08T10:00:30.000Z",
            task_state="FAILED",
            dlt_status=None,
            dlt_record_missing=True,
            rows_loaded=None,
            row_counts=None,
            error_text="Job JOB_X failed to complete. Exited with status: FAILED.",
        )
    ]
    inc = assemble.incidents([PIPES[0]], runs, NOW, days=1)
    kinds = [e["kind"] for e in inc["incidents"] if e["query_id"]]
    assert kinds == ["missing"]
    entry = inc["incidents"][0]
    assert entry["error_provenance"] == "TASK_HISTORY.ERROR_MESSAGE"


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
