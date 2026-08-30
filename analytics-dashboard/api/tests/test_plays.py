"""The play feed in fixture mode. The fixture holds KC's 2025 week-18 game
(the drive-grouping shape) and Mahomes/Nacua rows from weeks 1-2 (the role-OR
and the usage-strip branch)."""

from fastapi.testclient import TestClient

NACUA = "daca41214b39c5dc66674d09081940f0"
MAHOMES = "e369853df766fa44e1ed0ff613f563bd"


def _kc_game_key(client: TestClient) -> str:
    rows = client.get(
        "/api/nfl/plays", params={"team": "KC", "season": 2025, "week": 18}
    ).json()["rows"]
    return rows[0]["game_key"]


def test_unanchored_feed_is_400(client: TestClient) -> None:
    res = client.get("/api/nfl/plays", params={"season": 2025})
    assert res.status_code == 400
    assert "anchor" in res.json()["detail"]


def test_game_slice_carries_drives_and_order(client: TestClient) -> None:
    game_key = _kc_game_key(client)
    body = client.get("/api/nfl/plays", params={"game_key": game_key}).json()
    rows = body["rows"]
    assert rows and not body["has_more"]
    assert body["usage"] == [] and body["player_key"] is None, "no subject, no strip"
    # drive context rides every matched row; the page groups on it
    driven = [r for r in rows if r["drive_number"] is not None]
    assert driven, "a matched regular-season game has drive ids"
    first = driven[0]
    assert first["drive_play_count"] is not None and first["drive_result"] is not None
    assert first["drive_yards"] is not None
    keys = [(r["drive_number"] or 0, r["play_in_drive"] or 0) for r in driven]
    assert keys == sorted(keys)
    # honest NULLs, never imputed: any unmatched play carries no analytics
    for r in rows:
        if not r["has_nflverse"]:
            assert r["epa"] is None and r["passer_player_key"] is None


def test_player_anchor_matches_any_role_and_pins_the_strip(client: TestClient) -> None:
    body = client.get(
        "/api/nfl/plays", params={"player_key": NACUA, "season": 2025}
    ).json()
    rows = body["rows"]
    assert rows
    assert all(
        NACUA in (r["passer_player_key"], r["rusher_player_key"], r["receiver_player_key"])
        for r in rows
    )
    assert body["player_key"] == NACUA
    assert body["player_name"] == "Puka Nacua"
    assert body["usage"], "a player anchor pins his situational-usage strip"
    assert all(u["player_key"] == NACUA for u in body["usage"])


def test_situation_params_bind(client: TestClient) -> None:
    body = client.get(
        "/api/nfl/plays",
        params={"player_key": MAHOMES, "season": 2025, "down_bucket": "3rd_4th"},
    ).json()
    assert all(r["down_bucket"] == "3rd_4th" for r in body["rows"])
    assert 'down_bucket = ' in body["query"]


def test_unknown_game_is_404(client: TestClient) -> None:
    res = client.get("/api/nfl/plays", params={"game_key": "nope"})
    assert res.status_code == 404
    assert "no plays" in res.json()["detail"]


def test_sport_without_plays_is_404(client: TestClient) -> None:
    res = client.get("/api/ncaaf/plays", params={"team": "UGA"})
    assert res.status_code == 404
    assert "has no" in res.json()["detail"]
