"""The teams pages in fixture mode. The standings fixture holds 2025 (every season
type and split) and 2026 (preseason, in progress); the weeks and allowed fixtures
hold KC and DET for both seasons. No 2025 game carries a closing line, so the
vendor collapse is exercised directly on synthetic rows."""

from fastapi.testclient import TestClient

from app.sports.tiles import teams


def test_default_standings_are_the_season_type_in_progress(client: TestClient) -> None:
    body = client.get("/api/nfl/teams").json()
    assert body["season"] == 2026
    assert body["season_type_name"] == "Preseason", "nothing else has been played in 2026"
    assert body["season_types"] == ["Preseason"]
    assert body["split"] == "all"
    assert len(body["rows"]) == 32
    assert body["query"].count("from app_copy.app_team_standings") == 1


def test_completed_season_ranks_every_team(client: TestClient) -> None:
    body = client.get("/api/nfl/teams", params={"season": 2025, "season_type": "Regular Season"}).json()
    rows = body["rows"]
    assert len(rows) == 32
    assert body["season_types"] == ["Preseason", "Regular Season", "Postseason"], "calendar order"
    assert [r["rank_overall"] for r in rows] == sorted(r["rank_overall"] for r in rows)
    first = rows[0]
    assert (first["team_label"], first["wins"], first["losses"], first["rank_overall"]) == ("SEA", 14, 3, 1)
    assert all(r["games"] == 17 for r in rows)
    assert all(r["wins"] + r["losses"] + r["ties"] == r["games"] for r in rows)
    assert all(isinstance(r["last_results"], list) for r in rows), "the ARRAY column is parsed"


def test_home_and_away_splits_add_up_to_all(client: TestClient) -> None:
    params = {"season": 2025, "season_type": "Regular Season"}
    by_split = {
        split: {r["team_label"]: r for r in client.get("/api/nfl/teams", params={**params, "split": split}).json()["rows"]}
        for split in ("all", "home", "away")
    }
    for label, row in by_split["all"].items():
        assert by_split["home"][label]["games"] + by_split["away"][label]["games"] == row["games"]
        assert by_split["home"][label]["wins"] + by_split["away"][label]["wins"] == row["wins"]


def test_unknown_split_is_422_and_unknown_season_type_is_404(client: TestClient) -> None:
    assert client.get("/api/nfl/teams", params={"split": "neutral"}).status_code == 422
    res = client.get("/api/nfl/teams", params={"season": 2026, "season_type": "Postseason"})
    assert res.status_code == 404
    assert "2026 Postseason" in res.json()["detail"]


def test_team_page_carries_the_whole_season(client: TestClient) -> None:
    body = client.get("/api/nfl/teams/kc", params={"season": 2025, "season_type": "Regular Season"}).json()
    team = body["team"]
    assert (team["team_label"], team["split"], team["wins"], team["losses"]) == ("KC", "all", 6, 11)
    assert len(team["last_results"]) == 5, "the five most recent, newest first"
    assert team["last_results"][:3] == ["L", "L", "L"]
    # the denorm puts the split records on every row; KC 2025 went 4-4 at home
    assert team["home_record"] and team["away_record"]
    # the EPA block is real for a pbp-covered season
    assert team["off_epa_per_play"] is not None
    assert 1 <= team["off_epa_per_play_rank"] <= 32
    assert [s["split"] for s in body["splits"]] == ["all", "home", "away"]
    assert body["season_types"] == ["Preseason", "Regular Season"], "KC missed the 2025 postseason"
    weeks = body["weeks"]
    assert len(weeks) == 17
    assert weeks == sorted(weeks, key=lambda w: w["game_datetime_et"])
    assert (weeks[0]["opponent_label"], weeks[0]["is_home"], weeks[0]["result"]) == ("LAC", False, "L")
    assert (weeks[-1]["wins_to_date"], weeks[-1]["losses_to_date"]) == (6, 11)
    assert all(w["vendor"] is None and w["spread"] is None for w in weeks), "no 2025 lines"
    assert body["vendor"] == "draftkings" and body["vendors"] == []
    allowed = body["allowed"]
    assert len(allowed) == 27, "props pairs + volume + fantasy + efficiency"
    assert {a["stat_key"] for a in allowed} >= {"passing_yards_per_attempt", "draftkings_points"}
    assert all(1 <= a["allowed_rank"] <= a["teams_ranked"] == 32 for a in allowed)
    assert body["ats"] == [], "no book priced a 2025 game"
    situations = body["situations"]
    assert body["situation_season_type_name"] == "Regular Season"
    assert situations and {r["side"] for r in situations} == {"offense", "defense"}
    assert all(r["team_label"] == "KC" for r in situations)
    # standings + weeks + allowed + ats + situations
    assert body["query"].count("from app_copy.") == 5


def test_team_defaults_to_the_season_type_in_progress(client: TestClient) -> None:
    body = client.get("/api/nfl/teams/DET").json()
    assert body["season"] == 2026
    assert body["season_type_name"] == "Preseason"
    assert len(body["weeks"]) == body["team"]["games"] >= 1


def test_unknown_team_is_404(client: TestClient) -> None:
    res = client.get("/api/nfl/teams/xxx")
    assert res.status_code == 404
    assert "team XXX" in res.json()["detail"]


def test_sport_without_teams_is_404(client: TestClient) -> None:
    res = client.get("/api/ncaaf/teams")
    assert res.status_code == 404
    assert res.json()["detail"] == "NCAAF has no team_standings data"


def test_collapse_keeps_the_game_and_blanks_a_missing_book(client: TestClient) -> None:
    base = client.get("/api/nfl/teams/kc", params={"season": 2025, "season_type": "Regular Season"}).json()["weeks"][0]
    base = {k: v for k, v in base.items() if k != "vendors_available"}
    rows = [
        {**base, "vendor": "draftkings", "spread": -3.5, "total_line": 44.5, "spread_result": "cover"},
        {**base, "vendor": "fanduel", "spread": -3.0, "total_line": 44.0, "spread_result": "cover"},
    ]
    dk = teams.collapse(rows, "draftkings")
    assert len(dk) == 1 and dk[0].vendor == "draftkings" and dk[0].spread == -3.5
    assert dk[0].vendors_available == ["draftkings", "fanduel"]
    none = teams.collapse(rows, "betmgm")
    assert len(none) == 1, "the game keeps its row"
    assert none[0].vendor is None and none[0].spread is None and none[0].spread_result is None
    assert none[0].points_for == base["points_for"], "the box score is not a line field"
    assert none[0].off_epa_per_play == base["off_epa_per_play"], "EPA sits outside LINE_FIELDS"
    assert none[0].vendors_available == ["draftkings", "fanduel"]
