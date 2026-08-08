"""Fixture-mode smoke over every Phase 2 endpoint. No network."""

import pytest
from fastapi.testclient import TestClient

from app.main import create_app

QID = "01c6418f-0107-5e62-000f-cf02000b054e"


@pytest.fixture()
def client(monkeypatch: pytest.MonkeyPatch) -> TestClient:
    monkeypatch.setenv("OPS_DASHBOARD_DATA", "fixtures")
    return TestClient(create_app())


def test_sports(client: TestClient) -> None:
    body = client.get("/api/sports").json()
    assert [s["sport"] for s in body["sports"]] == ["NFL", "WNBA"]
    assert all(s["pipelines"] > 0 for s in body["sports"])


def test_overview_shape(client: TestClient) -> None:
    body = client.get("/api/overview?date=2026-08-08").json()
    assert body["summary"]["pipelines"] == 17
    assert body["summary"]["sports"] == 2
    assert {s["sport"] for s in body["sports"]} == {"NFL", "WNBA"}
    board = body["board"]
    assert board["window"]["start"] < board["window"]["end"]
    for sport in body["sports"]:
        assert sport["anomaly_count"] + sport["healthy_count"] == sport["pipelines"]


def test_overview_sport_filter(client: TestClient) -> None:
    body = client.get("/api/overview?sport=WNBA&date=2026-08-08").json()
    assert [s["sport"] for s in body["sports"]] == ["WNBA"]


def test_incidents_counts_match_entries(client: TestClient) -> None:
    body = client.get("/api/incidents?days=7").json()
    assert sum(body["counts"].values()) == len(body["incidents"])
    kinds = {e["kind"] for e in body["incidents"]}
    assert kinds <= {"failure", "missing", "disagree", "missed"}


def test_incidents_kind_filter(client: TestClient) -> None:
    body = client.get("/api/incidents?days=7&kind=missing").json()
    assert body["incidents"]
    assert all(e["kind"] == "missing" for e in body["incidents"])


def test_pipeline_detail(client: TestClient) -> None:
    body = client.get("/api/pipelines/NFL/nfl_stats").json()
    assert body["schedule"] == "daily 10:00 UTC"
    assert len(body["heatmap"]) == 14
    assert body["runs"]
    assert client.get("/api/pipelines/NFL/nope").status_code == 404


def test_run_detail_and_subresources(client: TestClient) -> None:
    run = client.get(f"/api/runs/{QID}").json()
    assert run["pipeline"] == "nfl_reference"
    assert run["state"] == "succeeded"
    assert run["prior_runs"]

    logs = client.get(f"/api/runs/{QID}/logs?limit=10").json()
    assert logs["total_log_lines"] == 416
    assert len(logs["lines"]) == 10

    metrics = client.get(f"/api/runs/{QID}/metrics").json()
    assert metrics["metric_samples"] == 179
    assert len(metrics["strips"]["cpu"]["points"]) == metrics["cpu_samples"] == 1
    assert len(metrics["strips"]["memory"]["points"]) == metrics["mem_samples"] == 2
    assert metrics["node_instance_family"] == "CPU_X64_S"

    counts = client.get(f"/api/runs/{QID}/rowcounts").json()
    assert counts["row_counts"] == {"players": 13521, "teams": 32}

    assert client.get("/api/runs/not-a-qid").status_code == 404
