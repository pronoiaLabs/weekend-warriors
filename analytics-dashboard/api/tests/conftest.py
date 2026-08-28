"""One client fixture for every endpoint test file.

  ANALYTICS_DASHBOARD_DATA=fixtures  serve recorded JSON, never import the
                                     Snowflake connector.
  ANALYTICS_DASHBOARD_NOW=...        pin the clock to the fixture snapshot's era
                                     so windows measured from "now" stay stable.
"""

import os

import pytest
from fastapi.testclient import TestClient

from app.main import create_app

SNAPSHOT_NOW = "2026-08-28T17:00:00+00:00"


@pytest.fixture()
def client(monkeypatch: pytest.MonkeyPatch) -> TestClient:
    monkeypatch.setenv("ANALYTICS_DASHBOARD_DATA", "fixtures")
    monkeypatch.setenv("ANALYTICS_DASHBOARD_NOW", SNAPSHOT_NOW)
    return TestClient(create_app())


def pytest_collection_modifyitems(config: pytest.Config, items: list[pytest.Item]) -> None:
    if os.environ.get("ANALYTICS_DASHBOARD_LIVE") == "1":
        return
    skip = pytest.mark.skip(reason="live test; set ANALYTICS_DASHBOARD_LIVE=1")
    for item in items:
        if "live" in item.keywords:
            item.add_marker(skip)
