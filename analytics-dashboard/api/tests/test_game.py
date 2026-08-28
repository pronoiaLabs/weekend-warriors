"""The game page in fixture mode: a slate row with the chosen book's line plus the
prop board split by side. Four 2026 week 1 games carry props from two books."""

import pytest
from fastapi.testclient import TestClient


@pytest.fixture()
def game_with_props(client: TestClient) -> str:
    body = client.get("/api/nfl/slate", params={"season_type": "Regular Season", "week": 1}).json()
    keys = [r["game_key"] for r in body["rows"] if r["props_open_all_books"] > 0]
    assert keys, "week 1 has games with props"
    return keys[0]


def test_game_splits_the_board_by_side(client: TestClient, game_with_props: str) -> None:
    body = client.get(f"/api/nfl/games/{game_with_props}").json()
    game = body["game"]
    assert game["game_key"] == game_with_props
    assert game["vendor"] == "draftkings"
    assert body["away"] and body["home"]
    assert all(not p["is_home"] for p in body["away"])
    assert all(p["is_home"] for p in body["home"])
    # team_as_of prefers the roster feed before the season's first box score, so an
    # offseason mover sits with the team that priced him, not his last box score's.
    # The reverse case also exists: a book keeps pricing a cut player's props while
    # the roster feed has already moved him (Boutte NE -> HOU, Aug 2026), so a
    # stray mover or two is data, not a bug.
    away_moved = [p for p in body["away"] if p["team_label"] != game["away_team_label"]]
    home_moved = [p for p in body["home"] if p["team_label"] != game["home_team_label"]]
    moved_keys = {p["player_key"] for p in away_moved + home_moved}
    assert len(moved_keys) <= 2
    assert all(
        p["opponent_label"] == game["home_team_label"]
        for p in body["away"] if p["player_key"] not in moved_keys
    )
    assert all(
        p["opponent_label"] == game["away_team_label"]
        for p in body["home"] if p["player_key"] not in moved_keys
    )
    assert set(body["vendors"]) >= {"draftkings", "fanduel"}
    assert body["query"].count("from app_copy.") == 2


def test_prop_rows_carry_form_line_and_matchup(client: TestClient, game_with_props: str) -> None:
    body = client.get(f"/api/nfl/games/{game_with_props}").json()
    rows = body["away"] + body["home"]
    with_form = [p for p in rows if p["trailing_games"]]
    assert with_form, "veterans have a trailing window"
    p = with_form[0]
    assert isinstance(p["stat_last3"], list), "the ARRAY column is parsed, not a string"
    assert p["trailing_avg"] is not None and p["trailing_hit_rate"] is not None
    assert p["gap_to_line"] is not None
    assert 1 <= p["opponent_allowed_rank"] <= p["opponent_allowed_teams_ranked"]
    assert all(p["market_type"] in ("over_under", "milestone") for p in rows)


def test_vendor_param_moves_the_game_line(client: TestClient, game_with_props: str) -> None:
    dk = client.get(f"/api/nfl/games/{game_with_props}").json()["game"]
    fd = client.get(f"/api/nfl/games/{game_with_props}", params={"vendor": "fanduel"}).json()
    assert fd["game"]["vendor"] == "fanduel"
    assert fd["game"]["game_key"] == dk["game_key"]
    assert len(fd["away"]) == len(
        client.get(f"/api/nfl/games/{game_with_props}").json()["away"]
    ), "the board itself is served for every book; the page filters"


def test_unknown_game_is_404(client: TestClient) -> None:
    res = client.get("/api/nfl/games/nope")
    assert res.status_code == 404
    assert "no game" in res.json()["detail"]


def test_game_without_props_still_renders(client: TestClient) -> None:
    body = client.get("/api/nfl/slate", params={"season": 2025, "season_type": "Regular Season", "week": 18}).json()
    key = body["rows"][0]["game_key"]
    res = client.get(f"/api/nfl/games/{key}").json()
    assert res["game"]["is_completed"] is True
    assert res["away"] == [] and res["home"] == []
    assert res["vendors"] == []
