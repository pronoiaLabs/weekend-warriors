"""Every pipeline row and every slot or run card names its source, the
registry's SOURCE column (rest_api for BallDontLie, nflverse, sleeper,
firecrawl, openmeteo ...), so the web can slice the board by vendor without a
second request. dbt build cards carry none: a build fires because data landed,
from whichever sources landed it."""

from __future__ import annotations

from datetime import UTC, datetime

from fastapi.testclient import TestClient

from app import assemble

NOW = datetime(2026, 8, 23, 18, 0, tzinfo=UTC)


def test_registry_rows_carry_source(client: TestClient) -> None:
    rows = client.get("/api/pipelines").json()["pipelines"]
    assert rows
    assert all("source" in r for r in rows)
    assert {r["source"] for r in rows} == {"rest_api"}  # the recorded fixture era


def test_slate_cards_carry_source(client: TestClient) -> None:
    body = client.get("/api/slate?date=2026-08-08").json()
    cards = [c for lg in body["leagues"] for c in lg["cards"]]
    ingestion = [c for c in cards if c["kind"] != "build"]
    builds = [c for c in cards if c["kind"] == "build"]
    assert ingestion and all(c["source"] == "rest_api" for c in ingestion)
    assert all("source" not in c for c in builds)


def test_slot_and_run_cards_take_the_pipeline_source() -> None:
    pipes = [
        {
            "name": "nfl_games",
            "sport": "NFL",
            "schedule": "5 9 * * *",
            "enabled": True,
            "source": "rest_api",
        },
        {
            "name": "nfl_sleeper_market",
            "sport": "NFL",
            "schedule": "20 */6 * * *",
            "enabled": True,
            "source": "sleeper",
        },
    ]
    runs = [
        {
            "pipeline": "nfl_games",
            "sport": "NFL",
            "run_started_at": "2026-08-23T09:05:30.000Z",
            "run_ended_at": "2026-08-23T09:06:30.000Z",
            "task_state": "SUCCEEDED",
            "dlt_status": "success",
            "query_id": "q",
            "rows_loaded": 1,
            "duration_s": 60.0,
            "error_text": None,
        }
    ]
    payload = assemble.slate(pipes, runs, [], NOW, NOW.date(), 0, UTC)
    by_pipe = {}
    for lg in payload["leagues"]:
        for c in lg["cards"]:
            by_pipe.setdefault(c["pipeline"], set()).add(c["source"])
    assert by_pipe == {"nfl_games": {"rest_api"}, "nfl_sleeper_market": {"sleeper"}}

    index = assemble.pipelines_index(pipes, runs, NOW)
    assert {r["pipeline"]: r["source"] for r in index["pipelines"]} == {
        "nfl_games": "rest_api",
        "nfl_sleeper_market": "sleeper",
    }
    detail = assemble.pipeline_detail(pipes[1], [], NOW, 10)
    assert detail["source"] == "sleeper"
