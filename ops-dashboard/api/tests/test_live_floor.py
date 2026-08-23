"""A pipeline's slots begin when the pipeline did.

A cron expanded over a day produces slots for hours the Task may not have
existed: the morning of the deploy that created it reads as a row of
no-shows. datasource.live_from picks the floor (the earlier of the registry
row's last sync and the first run ever) and assemble drops slots before it
from the slate, the form strip and the heatmap alike.
"""

from __future__ import annotations

from datetime import UTC, datetime

from app import assemble, datasource

NOW = datetime(2026, 8, 23, 18, 0, tzinfo=UTC)  # 14:00 ET, a Sunday


def _run(pipeline: str, at: str, state: str = "SUCCEEDED") -> dict:
    return {
        "pipeline": pipeline,
        "sport": "NFL",
        "run_started_at": at,
        "run_ended_at": at,
        "task_state": state,
        "dlt_status": "success",
        "query_id": "q",
        "rows_loaded": 1,
        "duration_s": 10.0,
        "error_text": None,
    }


# ---------------------------------------------------------------------------
# the floor itself
# ---------------------------------------------------------------------------


def test_live_from_is_the_earlier_witness() -> None:
    assert datasource.live_from("2026-08-23T17:30:00Z", None) == "2026-08-23T17:30:00Z"
    assert datasource.live_from(None, "2026-08-01T09:00:00Z") == "2026-08-01T09:00:00Z"
    # an old pipeline: last sync is recent, first run long ago -> first run wins
    assert (
        datasource.live_from("2026-08-23T17:30:00Z", "2026-08-01T09:00:00Z")
        == "2026-08-01T09:00:00Z"
    )
    assert datasource.live_from(None, None) is None


# ---------------------------------------------------------------------------
# the slate
# ---------------------------------------------------------------------------


def _slate_for(pipes: list[dict], runs: list[dict]) -> dict:
    return assemble.slate(pipes, runs, [], NOW, NOW.date(), 0, UTC)


def test_new_pipeline_slots_start_at_its_deploy() -> None:
    # every 6h at :20; deployed 17:30 UTC -> 00:20, 06:20, 12:20 never existed,
    # 18:20 is still ahead
    pipe = {
        "name": "nfl_sleeper_market",
        "sport": "NFL",
        "schedule": "20 */6 * * *",
        "enabled": True,
        "live_from": "2026-08-23T17:30:00Z",
    }
    payload = _slate_for([pipe], [])
    today = next(d for d in payload["days"] if d["is_today"])
    assert (today["slots"], today["missed"], today["upcoming"]) == (1, 0, 1)
    cards = [c for lg in payload["leagues"] for c in lg["cards"]]
    assert [c["at"][11:16] for c in cards] == ["18:20"]


def test_first_fire_that_never_came_is_still_a_no_show() -> None:
    # deployed 11:00 UTC, slot at 12:10 UTC passed without a run -> no show
    pipe = {
        "name": "nfl_sleeper_players",
        "sport": "NFL",
        "schedule": "10 12 * * *",
        "enabled": True,
        "live_from": "2026-08-23T11:00:00Z",
    }
    today = next(d for d in _slate_for([pipe], [])["days"] if d["is_today"])
    assert (today["slots"], today["missed"]) == (1, 1)


def test_old_pipeline_is_unaffected() -> None:
    pipe = {
        "name": "nfl_games",
        "sport": "NFL",
        "schedule": "5 9 * * *",
        "enabled": True,
        "live_from": "2026-07-01T00:00:00Z",
    }
    runs = [_run("nfl_games", "2026-08-23T09:05:30.000Z")]
    today = next(d for d in _slate_for([pipe], runs)["days"] if d["is_today"])
    assert (today["slots"], today["ran"], today["missed"]) == (1, 1, 0)


def test_no_floor_means_every_slot_counts() -> None:
    pipe = {"name": "x", "sport": "NFL", "schedule": "20 */6 * * *", "enabled": True}
    today = next(d for d in _slate_for([pipe], [])["days"] if d["is_today"])
    assert today["slots"] == 4 and today["missed"] == 3 and today["upcoming"] == 1


# ---------------------------------------------------------------------------
# the records path
# ---------------------------------------------------------------------------


def test_form_strip_and_heatmap_start_at_the_floor() -> None:
    cron = "20 */6 * * *"
    live = "2026-08-23T17:30:00Z"
    form, record = assemble.form_and_record(cron, [], NOW, live)
    assert form == [] and record["wins"] == 0 and record["losses"] == 0
    form_all, _ = assemble.form_and_record(cron, [], NOW)
    assert len(form_all) > 0 and all(c["result"] == "M" for c in form_all)

    cells = assemble._day_states(cron, [], NOW, live)
    by_date = {c["date"]: c["state"] for c in cells}
    assert by_date["2026-08-22"] == "none"  # before the floor: no slots at all
    assert by_date["2026-08-23"] == "scheduled"  # the 18:20 slot is still ahead
