"""Environment contract for the analytics dashboard API.

Every knob is an ANALYTICS_DASHBOARD_* variable, read at call time so tests can
monkeypatch them. Nothing here imports the Snowflake connector.

  ANALYTICS_DASHBOARD_DATA        "fixtures" serves recorded JSON and never opens
                                  a connection; anything else is live.
  ANALYTICS_DASHBOARD_NOW         pins the clock (ISO-8601) for fixture-era tests.
  ANALYTICS_DASHBOARD_CONNECTION  snow CLI connection name (default weekend-warriors).
  ANALYTICS_DASHBOARD_ROLE        applied with USE ROLE on connect (default
                                  ANALYTICS_DASHBOARD_ROLE). Secondary roles are
                                  always dropped, so the session holds this role alone.
  ANALYTICS_DASHBOARD_WAREHOUSE   USE WAREHOUSE on connect (default DLT_OPS_WH).
  ANALYTICS_DASHBOARD_CACHE_SECONDS  default query cache TTL (default 60).
  <SPORT>_APP_DB / <SPORT>_APP_SCHEMA  where a sport's APP marts live; defaults to
                                  <SPORT>_PROD_DB.APP. Point a sport at NFL_DEV_DB
                                  and DEV_<user> to read a dev build.
"""

import datetime as dt
import os


def data_mode() -> str:
    return os.environ.get("ANALYTICS_DASHBOARD_DATA", "live")


def is_fixtures() -> bool:
    return data_mode() == "fixtures"


def now() -> dt.datetime:
    pinned = os.environ.get("ANALYTICS_DASHBOARD_NOW")
    if pinned:
        return dt.datetime.fromisoformat(pinned)
    return dt.datetime.now(dt.UTC)


def connection_name() -> str:
    return os.environ.get("ANALYTICS_DASHBOARD_CONNECTION", "weekend-warriors")


def role() -> str:
    return os.environ.get("ANALYTICS_DASHBOARD_ROLE", "ANALYTICS_DASHBOARD_ROLE")


def warehouse() -> str:
    return os.environ.get("ANALYTICS_DASHBOARD_WAREHOUSE", "DLT_OPS_WH")


def cache_seconds() -> float:
    return float(os.environ.get("ANALYTICS_DASHBOARD_CACHE_SECONDS", "60"))


def app_location(sport_key: str) -> tuple[str, str]:
    """(database, schema) holding a sport's APP marts."""
    stem = sport_key.upper()
    db = os.environ.get(f"{stem}_APP_DB", f"{stem}_PROD_DB")
    schema = os.environ.get(f"{stem}_APP_SCHEMA", "APP")
    return db, schema
