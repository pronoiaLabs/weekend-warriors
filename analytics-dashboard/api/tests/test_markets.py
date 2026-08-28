"""The markets pages in fixture mode. The line history fixture holds 2026 Regular
Season weeks 1 and 2 (every book in week 1; DraftKings priced 16 games once or
twice, Kalshi re-priced 152 times); the prop history fixture holds DraftKings'
week 1 props and FanDuel's QB props for SF at LAR."""

from fastapi.testclient import TestClient

NE_SEA = "9d8f5c2f2bcbb264b89a51806e516c96"
SF_LAR = "56776ceb2af5a3b9fcfe711da4f84c05"


def test_default_week_is_the_first_with_a_line_ahead_of_the_clock(client: TestClient) -> None:
    body = client.get("/api/nfl/markets").json()
    assert body["season"] == 2026
    assert (body["season_type_name"], body["week"]) == ("Regular Season", 1)
    assert body["vendor"] == "draftkings"
    assert [(w["season_type_name"], w["week"]) for w in body["weeks"]] == [("Regular Season", 1), ("Regular Season", 2)]
    assert body["weeks"][0]["games"] == 16, "seven book rows per game count the game once"
    assert body["query"].count("from app_copy.app_line_history") == 2


def test_week_at_a_book_lists_every_snapshot_in_order(client: TestClient) -> None:
    body = client.get("/api/nfl/markets", params={"week": 1, "vendor": "kalshi"}).json()
    rows = body["rows"]
    assert len(rows) == 374
    assert all(r["vendor"] == "kalshi" for r in rows)
    assert len({r["game_key"] for r in rows}) == 16
    assert rows == sorted(rows, key=lambda r: (r["game_datetime_et"], r["game_key"], r["snapshot_number"]))
    moved = [r for r in rows if r["is_closing"] and (r["home_spread_since_open"] or r["total_line_since_open"])]
    assert moved, "kalshi's closing numbers differ from its openers somewhere (week 1: totals, not spreads)"
    first = [r for r in rows if r["is_opening"]]
    assert all(r["home_spread_since_open"] == 0 for r in first), "since-open is zero at the opener"


def test_book_without_lines_for_the_week_returns_no_rows_not_404(client: TestClient) -> None:
    body = client.get("/api/nfl/markets", params={"week": 2, "vendor": "betmgm"}).json()
    assert body["rows"] == []
    assert body["week"] == 2


def test_week_without_a_line_is_404(client: TestClient) -> None:
    res = client.get("/api/nfl/markets", params={"week": 9})
    assert res.status_code == 404
    assert "week 9" in res.json()["detail"]


def test_game_markets_carry_every_book_and_the_chosen_books_props(client: TestClient) -> None:
    body = client.get(f"/api/nfl/markets/{NE_SEA}").json()
    assert body["game"]["game_key"] == NE_SEA
    assert (body["game"]["away_team_label"], body["game"]["home_team_label"]) == ("NE", "SEA")
    assert len(body["vendors"]) == 8
    assert len(body["lines"]) == 51
    assert body["vendor"] == "draftkings"
    props = body["props"]
    assert len(props) == 4676 and all(p["vendor"] == "draftkings" for p in props)
    assert props == sorted(props, key=lambda p: (p["player_name"], p["prop_type"], p["snapshot_number"]))
    assert body["query"].count("from app_copy.") == 2


def test_props_are_bound_to_one_book(client: TestClient) -> None:
    dk = client.get(f"/api/nfl/markets/{SF_LAR}").json()
    fd = client.get(f"/api/nfl/markets/{SF_LAR}", params={"vendor": "fanduel"}).json()
    assert len({p["game_player_vendor_prop_key"] for p in dk["props"]}) == 64
    assert len(fd["props"]) == 1374, "FanDuel re-snapshots every tick"
    assert all(p["position"] == "QB" for p in fd["props"])
    assert dk["lines"] == fd["lines"], "the line paths are served for every book regardless"


def test_unlined_game_is_404(client: TestClient) -> None:
    res = client.get("/api/nfl/markets/nope")
    assert res.status_code == 404
    assert "no lines for game nope" in res.json()["detail"]


def test_sport_without_lines_is_404(client: TestClient) -> None:
    res = client.get("/api/ncaaf/markets")
    assert res.status_code == 404
    assert res.json()["detail"] == "NCAAF has no line_history data"
