"""The game's situations sub-route in fixture mode: both teams x both units,
season-level splits from app_team_situation (2025 + 2026 Regular Season in the
fixture slice; 2026 is empty until its play-by-play lands)."""

from fastapi.testclient import TestClient


def _completed_game(client: TestClient) -> str:
    body = client.get(
        "/api/nfl/slate", params={"season": 2025, "season_type": "Regular Season", "week": 18}
    ).json()
    return body["rows"][0]["game_key"]


def test_situations_split_four_ways(client: TestClient) -> None:
    key = _completed_game(client)
    body = client.get(f"/api/nfl/games/{key}/situations").json()
    assert body["game_key"] == key
    assert body["situation_season_type_name"] == "Regular Season"
    for section in ("home_offense", "home_defense", "away_offense", "away_defense"):
        rows = body[section]
        assert rows, f"{section} has season splits for a completed 2025 game"
        team = body["home_team_key"] if section.startswith("home") else body["away_team_key"]
        side = "offense" if section.endswith("offense") else "defense"
        assert all(r["team_key"] == team and r["side"] == side for r in rows)
        # ordered by situation_order, anchored by the overall row
        orders = [r["situation_order"] for r in rows]
        assert orders == sorted(orders)
        assert rows[0]["situation_key"] == "all"


def test_situations_rows_carry_league_context(client: TestClient) -> None:
    key = _completed_game(client)
    body = client.get(f"/api/nfl/games/{key}/situations").json()
    row = body["home_offense"][0]
    assert row["plays"] > 0
    assert row["teams_ranked"] == 32
    assert 1 <= row["situation_rank"] <= 32
    assert row["epa_vs_league"] is not None


def test_situations_unknown_game_404(client: TestClient) -> None:
    res = client.get("/api/nfl/games/nope/situations")
    assert res.status_code == 404


def test_situations_gated_by_capability(client: TestClient) -> None:
    # require() names the first missing capability; for NCAAF that is schedule
    res = client.get("/api/ncaaf/games/anything/situations")
    assert res.status_code == 404
    assert "has no" in res.json()["detail"]
