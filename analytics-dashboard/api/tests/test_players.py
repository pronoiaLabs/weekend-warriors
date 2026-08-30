"""The players pages in fixture mode. The leaders fixture holds the 2025 Regular
Season regulars at QB, RB, WR and TE, the skill positions of the 2026 preseason,
and every season of Puka Nacua and Patrick Mahomes; the weeks and stats fixtures
hold those two players."""

from fastapi.testclient import TestClient

NACUA = "daca41214b39c5dc66674d09081940f0"
MAHOMES = "e369853df766fa44e1ed0ff613f563bd"


def test_default_leaders_are_the_season_type_in_progress(client: TestClient) -> None:
    body = client.get("/api/nfl/players").json()
    assert body["season"] == 2026
    assert body["season_type_name"] == "Preseason"
    assert body["season_types"] == ["Preseason"]
    assert body["position"] is None and body["team"] is None
    assert body["rows"], "the preseason has player games"
    assert body["query"].count("from app_copy.app_player_leaders") == 2
    # the season list for the finder's Season control, newest first
    assert body["seasons"] == sorted(body["seasons"], reverse=True)
    assert {2025, 2026} <= set(body["seasons"])


def test_position_leaderboard_carries_ranks_within_the_position(client: TestClient) -> None:
    body = client.get(
        "/api/nfl/players", params={"season": 2025, "season_type": "Regular Season", "position": "wr"}
    ).json()
    assert body["position"] == "WR"
    rows = body["rows"]
    assert rows and all(r["position"] == "WR" for r in rows)
    top = min(rows, key=lambda r: r["rank_receiving_yards"])
    assert (top["player_name"], top["receiving_yards"], top["rank_receiving_yards"]) == (
        "Jaxon Smith-Njigba",
        1793,
        1,
    )
    assert top["players_at_position"] == 231, "the rank is within every WR in the mart, not the fixture"
    assert all(r["games"] >= 8 for r in rows)
    assert rows == sorted(rows, key=lambda r: (r["rank_fanduel_points"], r["player_name"]))
    # the usage columns the finder sorts by ride on every row
    assert all(r["target_share"] is None or 0 <= r["target_share"] <= 1 for r in rows)
    assert all(r["rank_ppr_points"] >= 1 for r in rows)
    assert any(r["headshot_url"] for r in rows), "the finder renders avatars"
    # the riser window: the delta is the difference of its own windows, and
    # only exists when both windows hold two observations
    for r in rows:
        if r["target_share_delta"] is not None:
            assert r["last3_share_games"] >= 2 and r["prior_share_games"] >= 2
            assert abs(r["target_share_delta"] - (r["target_share_last3"] - r["target_share_prior"])) < 0.002


def test_team_param_is_the_roster(client: TestClient) -> None:
    body = client.get(
        "/api/nfl/players", params={"season": 2025, "season_type": "Regular Season", "team": "lar"}
    ).json()
    assert body["team"] == "LAR"
    assert body["rows"] and all(r["team_label"] == "LAR" for r in body["rows"])
    assert any(r["player_name"] == "Puka Nacua" for r in body["rows"])
    assert body["query"].count("and team_label = 'LAR'") == 1


def test_unknown_season_type_is_404(client: TestClient) -> None:
    res = client.get("/api/nfl/players", params={"season": 2026, "season_type": "Postseason"})
    assert res.status_code == 404
    assert "2026 Postseason" in res.json()["detail"]


def test_player_page_defaults_to_the_latest_season_and_its_latest_type(client: TestClient) -> None:
    body = client.get(f"/api/nfl/players/{NACUA}").json()
    assert body["season"] == 2025, "no 2026 game yet"
    assert body["season_types"] == ["Regular Season", "Postseason"]
    assert body["season_type_name"] == "Postseason", "the type whose last game is latest"
    assert body["player"]["player_name"] == "Puka Nacua"
    assert len(body["weeks"]) == 3
    assert [s["season"] for s in body["seasons"]] == sorted(s["season"] for s in body["seasons"])
    # career + profile + weeks + stats
    assert body["query"].count("from app_copy.") == 4
    assert body["profile"] is not None and body["profile"]["player_name"] == "Puka Nacua"
    assert body["profile"]["team_source"] in ("box_score", "roster", "prior_box_score")


def test_player_season_carries_weeks_and_long_stats(client: TestClient) -> None:
    body = client.get(
        f"/api/nfl/players/{NACUA}", params={"season": 2025, "season_type": "Regular Season"}
    ).json()
    player = body["player"]
    assert (player["position"], player["team_label"], player["games"]) == ("WR", "LAR", 16)
    assert player["rank_receiving_yards"] == 2
    weeks = body["weeks"]
    assert len(weeks) == 16
    assert weeks == sorted(weeks, key=lambda w: w["game_datetime_et"])
    assert weeks[-1]["games_to_date"] == 16
    assert all(w["season_type_name"] == "Regular Season" for w in weeks)
    rec = sorted((s for s in body["stats"] if s["stat_key"] == "receiving_yards"), key=lambda s: s["game_date"])
    assert len(rec) == 16
    first = rec[0]
    assert (first["week"], first["value"], first["trailing3_avg"], first["season_avg_through"]) == (1, 130.0, 130.0, 130.0)
    # the year-over-year columns compare him to his own 2024
    assert (first["prior_season_same_week"], first["prior_season_avg"], first["prior_season_games"]) == (35.0, 90.0, 11)
    assert first["avg_vs_prior_season"] == 40.0
    # 19 box-score stats plus the seven vendor stats (shares, EPA, PPR)
    assert len({s["stat_key"] for s in body["stats"]}) == 26
    # share rows keep NULL for unmatched games and publish no season total
    shares = [s for s in body["stats"] if s["stat_key"] == "target_share"]
    assert shares and all(s["season_total_through"] is None for s in shares)
    assert all(s["values_through"] <= s["games_through"] for s in shares)


def test_player_with_a_preseason_defaults_to_it_when_it_is_latest(client: TestClient) -> None:
    body = client.get(f"/api/nfl/players/{MAHOMES}", params={"season": 2024}).json()
    assert body["season"] == 2024
    assert body["season_types"] == ["Preseason", "Regular Season", "Postseason"]
    assert body["season_type_name"] == "Postseason"


def test_unknown_player_is_404(client: TestClient) -> None:
    res = client.get("/api/nfl/players/nope")
    assert res.status_code == 404
    assert "no player nope" in res.json()["detail"]


def test_player_season_without_games_is_404(client: TestClient) -> None:
    res = client.get(f"/api/nfl/players/{NACUA}", params={"season": 2019})
    assert res.status_code == 404
    assert "season 2019" in res.json()["detail"]


def test_sport_without_players_is_404(client: TestClient) -> None:
    res = client.get("/api/ncaaf/players")
    assert res.status_code == 404
    assert res.json()["detail"] == "NCAAF has no player_leaders data"


def test_player_usage_carries_the_nine_cells_with_the_league_baseline(client: TestClient) -> None:
    body = client.get(
        f"/api/nfl/players/{NACUA}/usage",
        params={"season": 2025, "season_type": "Regular Season"},
    ).json()
    assert body["player_name"] == "Puka Nacua"
    rows = body["rows"]
    assert len(rows) == 9, "three bucket types, three buckets each"
    assert [r["bucket_type"] for r in rows] == sorted(r["bucket_type"] for r in rows)
    for bt in ("down", "field_zone", "script"):
        cells = [r for r in rows if r["bucket_type"] == bt]
        assert [r["bucket_order"] for r in cells] == sorted(r["bucket_order"] for r in cells)
    assert all(r["target_share"] is None or 0 <= r["target_share"] <= 1 for r in rows)
    assert all(r["league_pos_avg_share"] is not None for r in rows)
    assert all(r["league_qualifying_players"] >= 1 for r in rows)


def test_player_usage_is_honestly_empty_for_preseason(client: TestClient) -> None:
    body = client.get(
        f"/api/nfl/players/{NACUA}/usage",
        params={"season": 2023, "season_type": "Preseason"},
    ).json()
    assert body["season"] == 2023
    assert body["season_type_name"] == "Preseason"
    assert body["rows"] == [], "there is no preseason play-by-play"


def test_player_usage_without_the_mart_is_404(client: TestClient) -> None:
    res = client.get("/api/ncaaf/players/nope/usage")
    assert res.status_code == 404
    assert "has no" in res.json()["detail"]


def test_player_props_default_to_the_book_and_the_position_stat(client: TestClient) -> None:
    body = client.get(f"/api/nfl/players/{NACUA}/props").json()
    assert body["player_name"] == "Puka Nacua"
    assert body["vendor"] == "draftkings"
    assert body["stat_key"] == "receiving_yards", "the WR headline stat"
    rows = body["history"] + body["current"]
    assert rows, "the 2026 prop board carries his receiving line"
    assert all(r["vendor"] == "draftkings" and r["stat_key"] == "receiving_yards" for r in rows)
    assert all(r["is_completed"] for r in body["history"])
    assert all(not r["is_completed"] for r in body["current"])


def test_player_props_before_the_odds_feed_are_honestly_empty(client: TestClient) -> None:
    body = client.get(f"/api/nfl/players/{NACUA}/props", params={"season": 2025}).json()
    assert body["season"] == 2025
    assert body["history"] == [] and body["current"] == [], "the odds feed starts in 2026"


def test_player_props_without_the_mart_is_404(client: TestClient) -> None:
    res = client.get("/api/ncaaf/players/nope/props")
    assert res.status_code == 404
    assert "has no" in res.json()["detail"]
