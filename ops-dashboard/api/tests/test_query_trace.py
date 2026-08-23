"""Every payload carries the SQL the request built, rendered with literals in
place of the binds, in fixture mode exactly as it would in live mode."""

from fastapi.testclient import TestClient

from app import db


def test_slate_carries_the_statements_it_built(client: TestClient) -> None:
    body = client.get("/api/slate", params={"sport": "NFL"}).json()
    q = body["query"]
    assert "FROM DLT_DB.OPS.PIPELINE_REGISTRY" in q
    assert "FROM DLT_DB.OPS.PIPELINE_RUNS" in q and "AND SPORT = 'NFL'" in q
    assert "FROM DLT_DB.OPS.V_DBT_RUNS" in q and "WHERE SPORT = 'nfl'" in q
    assert "%(" not in q, "binds are rendered as literals"
    assert q.count("FROM DLT_DB.OPS.PIPELINE_REGISTRY") == 1, (
        "a repeated statement is recorded once"
    )


def test_every_endpoint_has_a_query(client: TestClient) -> None:
    run = client.get("/api/runs", params={"limit": 1}).json()
    assert "LIMIT 1;" in run["query"]
    qid = run["runs"][0]["query_id"]
    for path in (
        f"/api/runs/{qid}",
        f"/api/runs/{qid}/logs",
        f"/api/runs/{qid}/metrics",
        "/api/pipelines",
        "/api/headlines",
        "/api/dbt/builds",
    ):
        body = client.get(path).json()
        assert body["query"] and body["query"].endswith(";"), path


def test_render_quotes_and_escapes() -> None:
    assert (
        db.render("SELECT %(a)s, %(b)s, %(c)s", {"a": "O'Neil", "b": 3, "c": None})
        == "SELECT 'O''Neil', 3, NULL;"
    )
