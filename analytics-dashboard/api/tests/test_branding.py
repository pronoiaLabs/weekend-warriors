"""Team branding: 32 rows, fetched once, joined client-side by team_key."""

from fastapi.testclient import TestClient


def test_branding_serves_every_team_once(client: TestClient) -> None:
    body = client.get("/api/nfl/teams/branding").json()
    rows = body["rows"]
    assert len(rows) == 32
    assert len({r["team_key"] for r in rows}) == 32
    labels = [r["team_label"] for r in rows]
    assert labels == sorted(labels)
    assert body["query"].count("from app_copy.app_team_branding") == 1


def test_branding_rows_carry_the_visual_identity(client: TestClient) -> None:
    rows = client.get("/api/nfl/teams/branding").json()["rows"]
    assert all(r["color_primary"] and r["logo_url"] for r in rows)


def test_literal_path_is_not_swallowed_by_the_team_segment(client: TestClient) -> None:
    # /teams/branding must hit the branding route, not get_team('branding')
    body = client.get("/api/nfl/teams/branding").json()
    assert "rows" in body and "standings" not in body


def test_sport_without_branding_is_404(client: TestClient) -> None:
    res = client.get("/api/ncaaf/teams/branding")
    assert res.status_code == 404
    assert res.json()["detail"] == "NCAAF has no team_branding data"
