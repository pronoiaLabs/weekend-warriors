"""The Explorer in fixture mode: the catalog from the recorded schemas, and the
team games sheet (every 2025 Regular Season team game, 544 rows, one more than
the default page)."""

from fastapi.testclient import TestClient


def test_catalog_lists_every_sheet_with_typed_columns(client: TestClient) -> None:
    body = client.get("/api/nfl/explore").json()
    ids = [s["id"] for s in body["sheets"]]
    assert ids == ["player_games", "defender_games", "team_games", "game_lines", "player_props", "news", "line_moves"]
    team_games = next(s for s in body["sheets"] if s["id"] == "team_games")
    assert team_games["table"] == "app_explore_team_games"
    kinds = {c["name"]: c["kind"] for c in team_games["columns"]}
    assert kinds["row_id"] == "text"
    assert kinds["season"] == "integer"
    assert kinds["yards_per_play"] == "number"
    assert kinds["is_home"] == "boolean"
    assert kinds["game_date"] == "date"
    assert all(s["columns"][0]["name"] == "row_id" for s in body["sheets"])
    assert body["query"].count("describe table NFL_PROD_DB.APP.app_explore_") == 7


def test_sheet_pages_with_has_more(client: TestClient) -> None:
    body = client.get("/api/nfl/explore/team_games").json()
    assert body["sheet"] == "team_games"
    assert (body["limit"], body["offset"], body["has_more"]) == (500, 0, True)
    assert len(body["rows"]) == 500
    assert body["order"] == "row_id" and body["desc"] is False
    assert [c["name"] for c in body["columns"]][:3] == ["row_id", "team", "team_name"]
    assert "limit 501 offset 0" in body["query"]
    last = client.get("/api/nfl/explore/team_games", params={"offset": 500}).json()
    assert len(last["rows"]) == 44 and last["has_more"] is False


def test_where_and_order_are_bound_and_validated(client: TestClient) -> None:
    body = client.get(
        "/api/nfl/explore/team_games",
        params={"where": ["team:KC", "is_home:true"], "order": "point_margin", "desc": "true", "limit": 100},
    ).json()
    rows = body["rows"]
    assert len(rows) == 9 and all(r["team"] == "KC" and r["is_home"] is True for r in rows)
    assert [r["point_margin"] for r in rows] == sorted((r["point_margin"] for r in rows), reverse=True)
    assert body["filters"] == [{"column": "team", "value": "KC"}, {"column": "is_home", "value": True}]
    assert "where team = 'KC' and is_home = true" in body["query"]
    assert "order by point_margin desc, row_id" in body["query"]


def test_numeric_filters_are_coerced(client: TestClient) -> None:
    body = client.get("/api/nfl/explore/team_games", params={"where": ["week:1"], "limit": 100}).json()
    assert len(body["rows"]) == 32
    assert "where week = 1" in body["query"]


def test_unknown_column_and_bad_value_are_400(client: TestClient) -> None:
    res = client.get("/api/nfl/explore/team_games", params={"where": "nope:1"})
    assert res.status_code == 400 and "no column 'nope'" in res.json()["detail"]
    res = client.get("/api/nfl/explore/team_games", params={"where": "week:one"})
    assert res.status_code == 400 and "takes a integer" in res.json()["detail"]
    res = client.get("/api/nfl/explore/team_games", params={"order": "nope"})
    assert res.status_code == 400 and "to order by" in res.json()["detail"]
    res = client.get("/api/nfl/explore/team_games", params={"where": "no-colon"})
    assert res.status_code == 400 and "column:value" in res.json()["detail"]


def test_unknown_sheet_is_404(client: TestClient) -> None:
    res = client.get("/api/nfl/explore/nope")
    assert res.status_code == 404
    assert "no sheet 'nope'" in res.json()["detail"]


def test_sport_without_sheets_has_an_empty_catalog(client: TestClient) -> None:
    body = client.get("/api/ncaaf/explore").json()
    assert body["sheets"] == [] and body["query"] is None
    assert client.get("/api/ncaaf/explore/team_games").status_code == 404
