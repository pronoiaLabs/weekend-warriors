"""Fixture-mode tests for /api/runs. No network, no connector import."""

from fastapi.testclient import TestClient


def test_runs_shape(client: TestClient) -> None:
    body = client.get("/api/runs?limit=10").json()
    assert body["sports"] == ["NFL"]
    assert len(body["runs"]) == 10
    first = body["runs"][0]
    for key in ("sport", "pipeline", "query_id", "task_state", "run_started_at"):
        assert key in first


def test_runs_newest_first_utc(client: TestClient) -> None:
    runs = client.get("/api/runs?limit=50").json()["runs"]
    stamps = [r["run_started_at"] for r in runs]
    assert stamps == sorted(stamps, reverse=True)
    assert all(s.endswith("Z") for s in stamps)


def test_runs_have_the_expected_sport(client: TestClient) -> None:
    runs = client.get("/api/runs?limit=100").json()["runs"]
    assert {r["sport"] for r in runs} == {"NFL"}


def test_row_counts_parsed(client: TestClient) -> None:
    runs = client.get("/api/runs?limit=100").json()["runs"]
    counted = [r for r in runs if r["row_counts"] is not None]
    assert counted, "fixture should contain at least one run with row counts"
    assert all(isinstance(r["row_counts"], dict) for r in counted)


def test_sport_filter_and_unknown_sport(client: TestClient) -> None:
    nfl = client.get("/api/runs?sport=NFL").json()["runs"]
    assert nfl and all(r["sport"] == "NFL" for r in nfl)
    assert client.get("/api/runs?sport=NHL").status_code == 404
