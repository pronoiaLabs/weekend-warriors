"""The slate's day is a calendar day of the viewer's zone. With no zone the day
is UTC (every other slate test); with tz=America/New_York the same date spans
04:00Z to 04:00Z the next day in August, so a slot at 00:00Z belongs to the
previous local day."""

from fastapi.testclient import TestClient


def _cards(client: TestClient, **params: str) -> list[dict]:
    body = client.get("/api/slate", params={"sport": "all", **params}).json()
    return [
        c for league in body["leagues"] if league["kind"] == "ingestion" for c in league["cards"]
    ]


def test_eastern_day_cuts_at_local_midnight(client: TestClient) -> None:
    cards = _cards(client, date="2026-08-08", tz="America/New_York")
    assert cards, "the fixture has slots on that day"
    assert all("2026-08-08T04:00:00.000Z" <= c["at"] < "2026-08-09T04:00:00.000Z" for c in cards)
    utc_cards = _cards(client, date="2026-08-08")
    assert all(
        "2026-08-08T00:00:00.000Z" <= c["at"] < "2026-08-09T00:00:00.000Z" for c in utc_cards
    )
    # the fixture's crons all fire after 04:00Z, so Eastern and UTC agree on this
    # date; Tokyo's edge (15:00Z) moves the evening slots to the next local day
    tokyo = _cards(client, date="2026-08-08", tz="Asia/Tokyo")
    assert all("2026-08-07T15:00:00.000Z" <= c["at"] < "2026-08-08T15:00:00.000Z" for c in tokyo)
    assert {c["at"] for c in tokyo} != {c["at"] for c in utc_cards}


def test_today_and_the_strip_follow_the_zone(client: TestClient) -> None:
    # the clock is pinned to 2026-08-09T18:00Z: still Sunday in New York, already
    # Monday in Tokyo
    ny = client.get("/api/slate", params={"tz": "America/New_York"}).json()
    tokyo = client.get("/api/slate", params={"tz": "Asia/Tokyo"}).json()
    assert (
        ny["date"] == "2026-08-09"
        and next(d for d in ny["days"] if d["is_today"])["date"] == "2026-08-09"
    )
    assert (
        tokyo["date"] == "2026-08-10"
        and next(d for d in tokyo["days"] if d["is_today"])["date"] == "2026-08-10"
    )


def test_unknown_zone_is_422(client: TestClient) -> None:
    res = client.get("/api/slate", params={"tz": "Mars/Olympus"})
    assert res.status_code == 422
    assert "unknown timezone" in res.json()["detail"]
