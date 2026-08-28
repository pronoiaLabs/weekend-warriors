"""The news feed in fixture mode: every mention from the feeds' first days
(2026-08-20 to 08-28) against a clock pinned to 2026-08-28T17:00Z."""

from fastapi.testclient import TestClient


def test_default_window_is_seven_days_newest_first(client: TestClient) -> None:
    body = client.get("/api/nfl/news").json()
    assert body["days"] == 7
    assert body["since"] == "2026-08-21"
    assert body["team"] is None
    rows = body["rows"]
    assert len(rows) == 1005
    assert rows == sorted(rows, key=lambda r: r["published_at"], reverse=True)
    assert len(body["teams"]) == 32 and "pft" in body["feeds"]
    assert body["query"].count("from app_copy.app_news_mentions") == 1


def test_window_narrows_by_published_date(client: TestClient) -> None:
    body = client.get("/api/nfl/news", params={"days": 1}).json()
    assert body["since"] == "2026-08-27"
    assert len(body["rows"]) == 238
    assert all(r["published_date"] >= "2026-08-27" for r in body["rows"])


def test_team_param_binds_in_sql(client: TestClient) -> None:
    body = client.get("/api/nfl/news", params={"team": "kc"}).json()
    assert body["team"] == "KC"
    assert len(body["rows"]) == 7 and all(r["team_label"] == "KC" for r in body["rows"])
    assert "and team_label = 'KC'" in body["query"]


def test_rows_carry_resolution_and_the_next_game(client: TestClient) -> None:
    rows = client.get("/api/nfl/news").json()["rows"]
    unresolved = [r for r in rows if not r["is_player_resolved"]]
    assert len(unresolved) == 91
    assert all(r["player_key"] is None and r["player_name"] for r in unresolved), "the article's name survives"
    with_game = [r for r in rows if r["next_game_key"]]
    assert len(with_game) == 971
    assert all(r["next_opponent_label"] and r["days_to_next_game"] is not None for r in with_game)


def test_window_bounds_are_enforced(client: TestClient) -> None:
    assert client.get("/api/nfl/news", params={"days": 0}).status_code == 422
    assert client.get("/api/nfl/news", params={"days": 91}).status_code == 422


def test_sport_without_news_is_404(client: TestClient) -> None:
    res = client.get("/api/ncaaf/news")
    assert res.status_code == 404
    assert res.json()["detail"] == "NCAAF has no news data"
