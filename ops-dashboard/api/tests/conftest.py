"""One client fixture for every endpoint test file.

The two env pins matter more than the fixture itself:

  OPS_DASHBOARD_DATA=fixtures  -- serve recorded JSON, never import the
                                  Snowflake connector.
  OPS_DASHBOARD_NOW=...        -- pin the clock to the fixture snapshot's
                                  era (runs span early Aug 2026). Every
                                  "last N days" window otherwise empties
                                  as real time drifts past the frozen
                                  data; the 7-day incidents window was
                                  the first to age out and broke CI on
                                  every branch. A new snapshot means
                                  updating ONE literal, here.
"""

import pytest
from fastapi.testclient import TestClient

from app.main import create_app

SNAPSHOT_NOW = "2026-08-09T18:00:00+00:00"


@pytest.fixture()
def client(monkeypatch: pytest.MonkeyPatch) -> TestClient:
    monkeypatch.setenv("OPS_DASHBOARD_DATA", "fixtures")
    monkeypatch.setenv("OPS_DASHBOARD_NOW", SNAPSHOT_NOW)
    return TestClient(create_app())
