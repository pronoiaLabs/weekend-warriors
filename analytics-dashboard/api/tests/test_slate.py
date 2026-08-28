"""The game day board in fixture mode. The NFL fixture holds 2026 Regular Season
weeks 1 and 2, 2026 Preseason week 3 (partly played) and 2025 Regular Season
week 18 (completed, with scores); the clock is pinned to 2026-08-28."""

from fastapi.testclient import TestClient


def test_default_week_is_the_one_in_progress(client: TestClient) -> None:
    body = client.get("/api/nfl/slate").json()
    assert body["sport"] == "nfl"
    assert body["season"] == 2026
    # 2026-08-28 sits after preseason week 3's last kickoff, so the opener is next up
    assert (body["season_type_name"], body["week"]) == ("Regular Season", 1)
    assert body["vendor"] == "draftkings"
    assert body["rows"], "the week has games"
    assert body["query"].count("from app_copy.app_game_slate") == 2


def test_weeks_list_counts_each_game_once(client: TestClient) -> None:
    body = client.get("/api/nfl/slate").json()
    by_key = {(w["season_type_name"], w["week"]): w for w in body["weeks"]}
    assert set(by_key) == {
        ("Preseason", 3),
        ("Regular Season", 1),
        ("Regular Season", 2),
    }
    wk1 = by_key[("Regular Season", 1)]
    assert wk1["games"] == 16, "seven vendor rows per game collapse to one game"
    assert wk1["completed"] == 0
    first = body["weeks"][0]
    assert (first["season_type_name"], first["week"]) == ("Preseason", 3), "kickoff order"


def test_one_card_per_game_with_the_requested_book(client: TestClient) -> None:
    body = client.get("/api/nfl/slate", params={"season_type": "Regular Season", "week": 1}).json()
    rows = body["rows"]
    assert len(rows) == 16
    assert len({r["game_key"] for r in rows}) == 16
    assert all(r["vendor"] == "draftkings" for r in rows)
    assert all(r["home_spread"] is not None and r["total_line"] is not None for r in rows)
    assert rows == sorted(rows, key=lambda r: r["game_datetime_et"])
    first = rows[0]
    assert first["kickoff_slot_et"] == "Wed 8:20 PM"
    assert "draftkings" in first["vendors_available"] and len(first["vendors_available"]) == 8


def test_a_book_without_a_line_keeps_the_card_and_blanks_the_line(client: TestClient) -> None:
    body = client.get(
        "/api/nfl/slate", params={"season_type": "Regular Season", "week": 2, "vendor": "betmgm"}
    ).json()
    rows = body["rows"]
    assert len(rows) == 16, "week 2 has 16 games even though betmgm priced none of them"
    missing = [r for r in rows if r["vendor"] is None]
    assert missing, "some games have no betmgm line"
    assert all(r["home_spread"] is None and r["total_line"] is None for r in missing)
    assert all(r["vendors_available"] for r in rows), "every game has some book"
    assert all(r["home_team_label"] and r["away_team_label"] for r in rows)


def test_completed_week_carries_scores_and_results(client: TestClient) -> None:
    body = client.get(
        "/api/nfl/slate", params={"season": 2025, "season_type": "Regular Season", "week": 18}
    ).json()
    rows = body["rows"]
    assert len(rows) == 16
    assert all(r["is_completed"] for r in rows)
    assert all(r["home_score"] is not None and r["away_score"] is not None for r in rows)
    assert all(r["vendor"] is None for r in rows), "no odds feed in 2025"


def test_week_outside_the_season_is_404(client: TestClient) -> None:
    res = client.get("/api/nfl/slate", params={"season_type": "Regular Season", "week": 40})
    assert res.status_code == 404
    assert "week 40" in res.json()["detail"]


def test_sport_without_schedule_is_404(client: TestClient) -> None:
    res = client.get("/api/ncaaf/slate")
    assert res.status_code == 404
    assert res.json()["detail"] == "NCAAF has no schedule data"
