from fastapi.testclient import TestClient


def test_nfl_capabilities_list_the_first_two_marts(client: TestClient) -> None:
    body = client.get("/api/nfl/capabilities").json()
    assert body["sport"] == "nfl"
    assert body["capabilities"] == ["schedule", "game_prop_board"]
    assert body["default_vendor"] == "draftkings"
    assert "fantasy" in body["extensions"]
    assert body["app_location"] == "NFL_PROD_DB.APP"


def test_ncaaf_has_no_page_capabilities_yet(client: TestClient) -> None:
    body = client.get("/api/ncaaf/capabilities").json()
    assert body["capabilities"] == []
    assert body["extensions"] == ["rankings"]


def test_sport_segment_is_case_insensitive(client: TestClient) -> None:
    assert client.get("/api/NFL/capabilities").json()["sport"] == "nfl"


def test_unknown_sport_is_404(client: TestClient) -> None:
    res = client.get("/api/nhl/capabilities")
    assert res.status_code == 404
    assert "unknown sport" in res.json()["detail"]


def test_app_location_follows_env(client: TestClient, monkeypatch) -> None:
    monkeypatch.setenv("NFL_APP_DB", "NFL_DEV_DB")
    monkeypatch.setenv("NFL_APP_SCHEMA", "DEV_SOMEONE")
    assert client.get("/api/nfl/capabilities").json()["app_location"] == "NFL_DEV_DB.DEV_SOMEONE"
