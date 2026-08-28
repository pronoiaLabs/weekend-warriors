"""The AI wire endpoint: exact-day hit, fallback, empty, and bad input.

The fallback is the behavior worth pinning: the upstream proc is best-effort
and some days legitimately have no rows, so the endpoint serves the newest
day at or before the request and says which day it served. An empty wire is
HTTP 200 with an empty list, never a 404.
"""

from fastapi.testclient import TestClient

SEVERITIES = {"fail", "warn", "ok", "info"}


def test_default_date_serves_todays_wire(client: TestClient) -> None:
    # Pinned now is 2026-08-09; the fixture has a full wire for that day.
    body = client.get("/api/headlines").json()
    assert body["requested_date"] == "2026-08-09"
    assert body["served_date"] == "2026-08-09"
    assert body["stale"] is False
    assert body["model"] == "claude-haiku-4-5"
    assert len(body["headlines"]) == 4
    assert [h["seq"] for h in body["headlines"]] == [0, 1, 2, 3]
    assert body["headlines"][0]["severity"] == "fail"  # worst first, seq 0 = lead


def test_missing_day_falls_back_to_newest_before_it(client: TestClient) -> None:
    # No 08-08 rows in the fixture; the wire from 08-07 serves, marked stale.
    body = client.get("/api/headlines?date=2026-08-08").json()
    assert body["served_date"] == "2026-08-07"
    assert body["stale"] is True
    assert len(body["headlines"]) == 1


def test_no_wire_at_or_before_date_is_empty_not_404(client: TestClient) -> None:
    resp = client.get("/api/headlines?date=2026-08-01")
    assert resp.status_code == 200
    body = resp.json()
    assert body["served_date"] is None
    assert body["stale"] is True
    assert body["generated_at"] is None
    assert body["headlines"] == []


def test_invalid_date_is_422(client: TestClient) -> None:
    assert client.get("/api/headlines?date=garbage").status_code == 422


def test_severity_vocabulary_is_closed(client: TestClient) -> None:
    body = client.get("/api/headlines").json()
    assert {h["severity"] for h in body["headlines"]} <= SEVERITIES
