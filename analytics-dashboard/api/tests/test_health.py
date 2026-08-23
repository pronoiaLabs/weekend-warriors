from fastapi.testclient import TestClient


def test_health_reports_fixture_mode_and_sports(client: TestClient) -> None:
    body = client.get("/api/health").json()
    assert body["ok"] is True
    assert body["data"] == "fixtures"
    assert body["sports"] == ["ncaaf", "nfl"]


def test_unknown_api_path_is_404_not_html(client: TestClient) -> None:
    assert client.get("/api/nope").status_code == 404
