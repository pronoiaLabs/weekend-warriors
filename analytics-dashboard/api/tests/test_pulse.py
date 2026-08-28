"""The Pulse composite in fixture mode, clock pinned to 2026-08-28T17:00Z."""

from fastapi.testclient import TestClient


def test_pulse_composes_the_five_sections(client: TestClient) -> None:
    body = client.get("/api/nfl/pulse").json()
    for section in ("slate", "news", "status", "trending"):
        assert isinstance(body[section], list), section
    assert set(body["movers"]) == {"games", "props"}
    assert body["days"] == 2
    assert body["vendor"] == "draftkings"
    # one composite fetch shows every select it ran
    for table in (
        "app_game_slate",
        "app_news_mentions",
        "app_status_board",
        "app_trending_players",
        "app_market_movers",
    ):
        assert f"app_copy.{table}" in body["query"], table


def test_week_default_matches_the_slate(client: TestClient) -> None:
    pulse = client.get("/api/nfl/pulse").json()
    slate = client.get("/api/nfl/slate").json()
    assert pulse["season"] == slate["season"]
    assert pulse["season_type_name"] == slate["season_type_name"]
    assert pulse["week"] == slate["week"]
    assert [r["game_key"] for r in pulse["slate"]] == [r["game_key"] for r in slate["rows"]]


def test_news_window_narrows_by_days(client: TestClient) -> None:
    wide = client.get("/api/nfl/pulse", params={"days": 7}).json()
    narrow = client.get("/api/nfl/pulse", params={"days": 1}).json()
    assert len(narrow["news"]) <= len(wide["news"])
    assert all(r["published_date"] >= "2026-08-27" for r in narrow["news"])


def test_status_rows_order_hard_designations_first(client: TestClient) -> None:
    rows = client.get("/api/nfl/pulse").json()["status"]
    orders = [r["designation_order"] for r in rows]
    assert orders == sorted(orders)
    assert all(r["player_name"] for r in rows)


def test_trending_adds_before_drops_in_board_order(client: TestClient) -> None:
    rows = client.get("/api/nfl/pulse").json()["trending"]
    directions = [r["direction"] for r in rows]
    assert directions == sorted(directions)  # 'add' < 'drop'
    for direction in ("add", "drop"):
        ranks = [r["board_rank"] for r in rows if r["direction"] == direction]
        assert ranks == sorted(ranks)


def test_movers_split_by_kind_with_caps_and_vendor_bind(client: TestClient) -> None:
    body = client.get("/api/nfl/pulse").json()
    movers = body["movers"]
    assert len(movers["games"]) <= 6 and len(movers["props"]) <= 8
    assert all(r["kind"] == "game" for r in movers["games"])
    assert all(r["kind"] == "prop" for r in movers["props"])
    assert all(r["vendor"] == "draftkings" for r in movers["games"] + movers["props"])
    assert all(r["delta"] != 0 for r in movers["games"] + movers["props"])
    assert "and vendor = 'draftkings'" in body["query"]


def test_days_bounds_are_enforced(client: TestClient) -> None:
    assert client.get("/api/nfl/pulse", params={"days": 0}).status_code == 422
    assert client.get("/api/nfl/pulse", params={"days": 91}).status_code == 422


def test_sport_without_the_marts_is_404(client: TestClient) -> None:
    res = client.get("/api/ncaaf/pulse")
    assert res.status_code == 404
    assert "has no" in res.json()["detail"]
