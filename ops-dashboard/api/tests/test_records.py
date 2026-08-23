"""W-L records and form strips on the pipelines index (additive fields).

The record counts decisive outcomes only (SUCCEEDED / FAILED /
FAILED_AND_AUTO_SUSPENDED, matching the form_guide_14d SQL); missed slots
render as M cells in the form but never touch the record or the streak.
"""

from datetime import UTC, datetime

from fastapi.testclient import TestClient

from app import assemble

NOW = datetime(2026, 8, 9, 18, 0, tzinfo=UTC)


def test_index_rows_carry_records(client: TestClient) -> None:
    body = client.get("/api/pipelines").json()
    for row in body["pipelines"]:
        rec = row["record"]
        assert set(rec) == {"wins", "losses", "pct", "streak"}
        wl_cells = [c for c in row["form"] if c["result"] in ("W", "L")]
        assert rec["wins"] + rec["losses"] == len(wl_cells) or len(row["form"]) == 14
        assert len(row["form"]) <= 14
        ats = [c["at"] for c in row["form"]]
        assert ats == sorted(ats)


def test_all_green_pipeline_has_perfect_record(client: TestClient) -> None:
    body = client.get("/api/pipelines").json()
    perfect = [
        r for r in body["pipelines"] if r["record"]["losses"] == 0 and r["record"]["wins"] > 0
    ]
    assert perfect, "fixture fleet should include at least one clean pipeline"
    for row in perfect:
        assert row["record"]["pct"] == 1.0
        assert row["record"]["streak"] == f"W{row['record']['wins']}"


def test_latest_failure_shows_l_streak(client: TestClient) -> None:
    body = client.get("/api/pipelines").json()
    for row in body["pipelines"]:
        latest = row["latest"]
        if latest and latest["state"] in ("failure", "missing") and row["record"]["streak"]:
            assert row["record"]["streak"].startswith("L")


def _run(at: str, state: str) -> dict:
    return {"run_started_at": at, "task_state": state, "query_id": "q-" + at}


def test_streak_edges_pure() -> None:
    cron = "0 8 * * *"
    # all wins
    hist = [_run(f"2026-08-0{d}T08:00:30.000Z", "SUCCEEDED") for d in range(1, 9)]
    hist.reverse()
    _form, rec = assemble.form_and_record(cron, hist, NOW)
    assert rec["streak"] == "W8" and rec["pct"] == 1.0

    # latest differs from the run before it
    hist2 = [
        _run("2026-08-08T08:00:30.000Z", "FAILED"),
        _run("2026-08-07T08:00:30.000Z", "SUCCEEDED"),
        _run("2026-08-06T08:00:30.000Z", "SUCCEEDED"),
    ]
    _form, rec2 = assemble.form_and_record(cron, hist2, NOW)
    assert rec2["streak"] == "L1"
    assert rec2["wins"] == 2 and rec2["losses"] == 1

    # auto-suspend counts as a loss
    hist3 = [_run("2026-08-08T08:00:30.000Z", "FAILED_AND_AUTO_SUSPENDED")]
    _form, rec3 = assemble.form_and_record(cron, hist3, NOW)
    assert rec3["losses"] == 1 and rec3["streak"] == "L1"

    # never ran: null record, form holds only M cells
    form4, rec4 = assemble.form_and_record(cron, [], NOW)
    assert rec4 == {"wins": 0, "losses": 0, "pct": None, "streak": None}
    assert form4 and all(c["result"] == "M" for c in form4)
