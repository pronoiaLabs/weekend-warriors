"""Fixture-mode cover over the dbt build endpoints. No network."""

import pytest
from fastapi.testclient import TestClient

from app.main import create_app

# A wnba build with a drained load, per-node queries and one profiled query.
BUILD = "ec4edb49-8ac2-4de1-8c8d-eec69407e91e"
NFL_BUILD = "368a08ac-6de0-4922-b2d2-4359fc123f1a"
PROFILED_QID = "01c64669-0107-5e2f-000f-cf02000f2d46"


@pytest.fixture()
def client(monkeypatch: pytest.MonkeyPatch) -> TestClient:
    monkeypatch.setenv("OPS_DASHBOARD_DATA", "fixtures")
    return TestClient(create_app())


def test_builds_ordered_and_filtered(client: TestClient) -> None:
    builds = client.get("/api/dbt/builds").json()["builds"]
    assert len(builds) == 9
    starts = [b["started_at"] for b in builds]
    assert starts == sorted(starts, reverse=True)
    assert all(s.endswith("Z") for s in starts)
    # Runs that died before the proc recorded a build_id still get a row.
    assert any(b["build_id"] is None for b in builds)
    assert {b["state"] for b in builds} == {"SUCCEEDED", "FAILED"}

    nfl = client.get("/api/dbt/builds?sport=nfl").json()["builds"]
    assert nfl and all(b["sport"] == "nfl" for b in nfl)
    assert len(client.get("/api/dbt/builds?limit=2").json()["builds"]) == 2


def test_builds_unknown_sport_is_404(client: TestClient) -> None:
    assert client.get("/api/dbt/builds?sport=mlb").status_code == 404


def test_build_detail_with_loads(client: TestClient) -> None:
    body = client.get(f"/api/dbt/builds/{BUILD}").json()
    build = body["build"]
    assert build["sport"] == "wnba"
    assert build["environment"] == "wnba_prod"
    assert build["n_queries"] == 1263
    # One load drained inside the build's window; the sport's other loads sit
    # outside it and must not appear.
    assert [load["pipeline"] for load in body["loads"]] == ["wnba_games"]
    assert body["loads"][0]["drained_at"] > build["started_at"]


def test_build_detail_loads_scoped_to_sport(client: TestClient) -> None:
    body = client.get(f"/api/dbt/builds/{NFL_BUILD}").json()
    assert body["build"]["sport"] == "nfl"
    assert [load["pipeline"] for load in body["loads"]] == ["nfl_reference"]


def test_build_detail_unknown_is_404(client: TestClient) -> None:
    assert client.get("/api/dbt/builds/nope").status_code == 404
    assert client.get("/api/dbt/builds/nope/queries").status_code == 404


def test_build_queries_slowest_first(client: TestClient) -> None:
    queries = client.get(f"/api/dbt/builds/{BUILD}/queries").json()["queries"]
    elapsed = [q["total_elapsed_time"] for q in queries]
    assert elapsed == sorted(elapsed, reverse=True)
    assert all(q["node"].startswith("model.cortex_agent_lifecycle.") for q in queries)
    assert all(q["execution_status"] == "SUCCESS" for q in queries)
    assert len(client.get(f"/api/dbt/builds/{BUILD}/queries?limit=3").json()["queries"]) == 3


def test_query_operators_are_parsed_json(client: TestClient) -> None:
    body = client.get(f"/api/dbt/queries/{PROFILED_QID}/operators").json()
    assert body["query_id"] == PROFILED_QID
    ops = body["operators"]
    assert [(o["step_id"], o["operator_id"]) for o in ops] == sorted(
        (o["step_id"], o["operator_id"]) for o in ops
    )
    root = ops[0]
    assert root["parent_operators"] is None
    assert isinstance(root["operator_statistics"], dict)
    assert isinstance(ops[1]["parent_operators"], list)
    assert isinstance(ops[1]["execution_time_breakdown"], dict)


def test_query_operators_unknown_is_404(client: TestClient) -> None:
    assert client.get("/api/dbt/queries/not-a-qid/operators").status_code == 404
