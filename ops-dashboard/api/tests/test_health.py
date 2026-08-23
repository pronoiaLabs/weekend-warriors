from fastapi.testclient import TestClient


def test_health(client: TestClient) -> None:
    body = client.get("/api/health").json()
    assert body["status"] == "ok"
    assert body["service"] == "ops-dashboard"
    assert body["data"] == "fixtures"
    assert body["backend"] == "fixtures"


def test_unknown_api_path_is_404_not_html(client: TestClient) -> None:
    response = client.get("/api/nope")
    assert response.status_code == 404
