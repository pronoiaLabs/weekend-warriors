"""Fixture-mode smoke over every Phase 2 endpoint. No network.

The shared `client` fixture (data + clock pins) lives in conftest.py.
"""

from fastapi.testclient import TestClient

QID = "01c6418f-0107-5e62-000f-cf02000b054e"


def test_sports(client: TestClient) -> None:
    body = client.get("/api/sports").json()
    assert [s["sport"] for s in body["sports"]] == ["NFL"]
    assert all(s["pipelines"] > 0 for s in body["sports"])


def test_pipelines_index(client: TestClient) -> None:
    body = client.get("/api/pipelines").json()
    assert len(body["pipelines"]) == 7
    by_name = {p["pipeline"]: p for p in body["pipelines"]}
    ref = by_name["nfl_reference"]
    assert ref["schedule"] == "0 8 * * *"
    assert ref["latest"]["state"] == "succeeded"
    assert ref["succeeded"] > 0
    # The 14-day strip rides on every index row, same day states as the detail
    # heatmap (shared _day_states), so the two can never disagree.
    assert len(ref["days"]) == 14
    assert all(c["state"] for c in ref["days"])
    # A pipeline that never ran still gets a row, with latest None.
    never_ran = [p for p in body["pipelines"] if p["latest"] is None]
    assert all(p["runs_in_window"] == 0 for p in never_ran)
    nfl = client.get("/api/pipelines?sport=NFL").json()["pipelines"]
    assert len(nfl) == 7 and all(p["sport"] == "NFL" for p in nfl)


def test_pipeline_detail(client: TestClient) -> None:
    body = client.get("/api/pipelines/NFL/nfl_stats").json()
    assert body["schedule"] == "0 10 * * *"
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
