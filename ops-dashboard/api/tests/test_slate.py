"""The day slate: card lanes, day-strip tallies, and their agreement.

The strip and the lanes are computed by one function over one filtered
pipeline set, so a tab's "1 failed" and its slate's upset cards can never
disagree; these tests pin that accounting plus the window boundaries.
"""

from fastapi.testclient import TestClient


def _get(client: TestClient, **params: str) -> dict:
    q = "&".join(f"{k}={v}" for k, v in params.items())
    return client.get(f"/api/slate?{q}").json()


def test_strip_shape_and_accounting(client: TestClient) -> None:
    body = _get(client, date="2026-08-08")
    assert body["date"] == "2026-08-08"
    assert len(body["days"]) == 7
    assert body["days"][3]["date"] == "2026-08-08"  # requested day centered
    for d in body["days"]:
        assert d["ran"] + d["failed"] + d["missed"] + d["upcoming"] == d["slots"]


def test_future_day_is_pure_schedule(client: TestClient) -> None:
    # Pinned now is Aug 9; Aug 11 is entirely in the future.
    body = _get(client, date="2026-08-11")
    today_cell = next(d for d in body["days"] if d["date"] == "2026-08-11")
    assert today_cell["ran"] == 0 and today_cell["failed"] == 0
    assert today_cell["upcoming"] == today_cell["slots"] > 0
    # Every ingestion card that day is an upcoming card.
    for league in body["leagues"]:
        if league["kind"] == "ingestion":
            assert all(c["kind"] == "upcoming" for c in league["cards"])


def test_cards_ordered_and_typed(client: TestClient) -> None:
    body = _get(client, date="2026-08-08")
    kinds = {"run", "missed", "upcoming", "build"}
    for league in body["leagues"]:
        ats = [c["at"] for c in league["cards"]]
        assert ats == sorted(ats)
        assert {c["kind"] for c in league["cards"]} <= kinds


def test_failure_card_carries_evidence_and_prev(client: TestClient) -> None:
    # The fixture era contains failed runs; find any failure card in the window.
    found = None
    for date in ("2026-08-05", "2026-08-06", "2026-08-07", "2026-08-08"):
        body = _get(client, date=date)
        for league in body["leagues"]:
            for c in league["cards"]:
                if c["kind"] == "run" and c["state"] in ("failure", "missing"):
                    found = c
        if found:
            break
    assert found is not None, "fixture window should contain at least one bad run"
    assert found["query_id"]
    # prev context exists whenever an earlier run of the pipeline is in window
    assert "prev" in found


def test_sport_filter_drops_other_leagues(client: TestClient) -> None:
    body = _get(client, date="2026-08-08", sport="NFL")
    ingestion = [x for x in body["leagues"] if x["kind"] == "ingestion"]
    assert {x["sport"] for x in ingestion} <= {"NFL"}
    # dbt league, when present under a sport filter, only carries that sport.
    for league in body["leagues"]:
        if league["kind"] == "dbt":
            assert {c["sport"] for c in league["cards"]} <= {"nfl"}


def test_window_boundary_excludes_prior_day(client: TestClient) -> None:
    # runs_between contract: start <= at < end. A day at the far edge of the
    # strip must not pull cards from beyond its own slots.
    body = _get(client, date="2026-08-01")
    for league in body["leagues"]:
        if league["kind"] != "ingestion":
            continue
        for c in league["cards"]:
            assert c["at"].startswith("2026-08-01")
