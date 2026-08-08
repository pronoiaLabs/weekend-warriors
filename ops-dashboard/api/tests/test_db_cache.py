"""The query TTL cache, exercised with a stubbed live path (no connector)."""

import pytest

from app import db


@pytest.fixture(autouse=True)
def clean_cache() -> None:
    db._query_cache.clear()


def test_second_call_within_ttl_hits_cache(monkeypatch: pytest.MonkeyPatch) -> None:
    calls: list[str] = []

    def fake_live(sql: str, params: dict | None) -> list[dict]:
        calls.append(sql)
        return [{"n": 1}]

    monkeypatch.setattr(db, "_query_live", fake_live)
    assert db.query("SELECT 1") == [{"n": 1}]
    assert db.query("SELECT 1") == [{"n": 1}]
    assert len(calls) == 1
    db.query("SELECT 2")
    assert len(calls) == 2


def test_expired_entry_refetches(monkeypatch: pytest.MonkeyPatch) -> None:
    calls: list[str] = []
    monkeypatch.setattr(db, "_query_live", lambda sql, params: calls.append(sql) or [{"n": 1}])
    monkeypatch.setenv("OPS_DASHBOARD_CACHE_SECONDS", "0")
    db.query("SELECT 1")
    db.query("SELECT 1")
    assert len(calls) == 2


def test_hits_return_copies(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(db, "_query_live", lambda sql, params: [{"row_counts": "{}"}])
    first = db.query("SELECT 1")
    first[0]["row_counts"] = {"mutated": True}
    second = db.query("SELECT 1")
    assert second[0]["row_counts"] == "{}"


def test_params_are_part_of_the_key(monkeypatch: pytest.MonkeyPatch) -> None:
    calls: list[dict | None] = []
    monkeypatch.setattr(db, "_query_live", lambda sql, params: calls.append(params) or [])
    db.query("SELECT :x", {"x": 1})
    db.query("SELECT :x", {"x": 2})
    assert len(calls) == 2
