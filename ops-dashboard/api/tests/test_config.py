"""The env contract: defaults, pins, and what the health endpoint reports."""

import datetime as dt

import pytest
from fastapi.testclient import TestClient

from app import config


def test_defaults_are_live_postgres(monkeypatch: pytest.MonkeyPatch) -> None:
    for key in (
        "OPS_DASHBOARD_DATA",
        "OPS_DASHBOARD_BACKEND",
        "OPS_DASHBOARD_ROLE",
        "OPS_DASHBOARD_WAREHOUSE",
        "OPS_DASHBOARD_NOW",
    ):
        monkeypatch.delenv(key, raising=False)
    assert config.data_mode() == "live"
    assert config.backend() == "postgres"
    assert config.is_postgres() is True
    assert config.role() == "app_api"
    assert config.connection_name() == "weekend-warriors"
    assert config.cache_seconds() == 60
    assert config.now().tzinfo is not None


def test_live_backend_snowflake(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("OPS_DASHBOARD_DATA", "live")
    monkeypatch.setenv("OPS_DASHBOARD_BACKEND", "snowflake")
    monkeypatch.delenv("OPS_DASHBOARD_ROLE", raising=False)
    from app import datasource

    assert config.is_snowflake() is True
    assert config.role() is None
    assert datasource.object_fqn("pipeline_runs") == "DLT_DB.OPS.PIPELINE_RUNS"
    assert datasource.object_fqn("v_log_lines") == "DLT_DB.OPS.V_LOG_LINES"


def test_postgres_fqns_use_copied_tables(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("OPS_DASHBOARD_DATA", "live")
    monkeypatch.setenv("OPS_DASHBOARD_BACKEND", "postgres")
    from app import datasource

    assert datasource.object_fqn("pipeline_runs") == "observability.pipeline_runs"
    assert datasource.object_fqn("v_log_lines") == "observability.log_lines"
    assert datasource.object_fqn("v_metrics") == "observability.metric_samples"
    assert datasource.object_fqn("v_dbt_runs") == "observability.dbt_runs"
    assert datasource.object_fqn("dbt_trigger_loads") is None


def test_pins_are_read(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("OPS_DASHBOARD_BACKEND", "snowflake")
    monkeypatch.setenv("OPS_DASHBOARD_NOW", "2026-08-09T18:00:00+00:00")
    monkeypatch.setenv("OPS_DASHBOARD_ROLE", "OPS_DASHBOARD_ROLE")
    monkeypatch.setenv("OPS_DASHBOARD_CACHE_SECONDS", "5")
    assert config.now() == dt.datetime(2026, 8, 9, 18, tzinfo=dt.UTC)
    assert config.role() == "OPS_DASHBOARD_ROLE"
    assert config.cache_seconds() == 5


def test_health_reports_mode_and_role(client: TestClient, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("OPS_DASHBOARD_ROLE", raising=False)
    body = client.get("/api/health").json()
    assert body["status"] == "ok"
    assert body["data"] == "fixtures"
    assert body["backend"] == "fixtures"
    assert body["role"] == "connection default"
