"""Environment contract for the analytics dashboard API.

Every knob is an ANALYTICS_DASHBOARD_* variable, read at call time so tests can
monkeypatch them. Nothing here imports a database driver.

  ANALYTICS_DASHBOARD_DATA        "fixtures" serves recorded JSON and never opens
                                  a connection; anything else is live.
  ANALYTICS_DASHBOARD_BACKEND     live store: "postgres" (default) or "snowflake"
                                  (fixture capture and rollback). Ignored when
                                  DATA=fixtures.
  ANALYTICS_DASHBOARD_NOW         pins the clock (ISO-8601) for fixture-era tests.
  ANALYTICS_DASHBOARD_CONNECTION  snow CLI connection name (default weekend-warriors).
  ANALYTICS_DASHBOARD_ROLE        Snowflake USE ROLE on connect (default
                                  ANALYTICS_DASHBOARD_ROLE). Secondary roles are
                                  always dropped, so the session holds this role alone.
  ANALYTICS_DASHBOARD_WAREHOUSE   USE WAREHOUSE on connect (default DLT_OPS_WH).
  ANALYTICS_DASHBOARD_CACHE_SECONDS  default query cache TTL (default 60).
  <SPORT>_APP_DB / <SPORT>_APP_SCHEMA  where a sport's APP marts live. Postgres
                                  defaults to app / app_copy; Snowflake defaults
                                  to <SPORT>_PROD_DB / APP. Point Snowflake at
                                  NFL_DEV_DB and DEV_<user> to capture a dev build.

Postgres live reads PGHOST / PGPORT from the environment (Makefile sources
repo-root .env.postgres). The login is always app_api; the password is
APP_API_PASSWORD (or ANALYTICS_DASHBOARD_PGPASSWORD). PGPASSWORD / PGUSER from
.env.postgres are the instance admin and are not used.
"""

import datetime as dt
import os

_BACKENDS = frozenset({"postgres", "snowflake"})


def data_mode() -> str:
    return os.environ.get("ANALYTICS_DASHBOARD_DATA", "live")


def is_fixtures() -> bool:
    return data_mode() == "fixtures"


def backend() -> str:
    """Store the API would query: fixtures, postgres, or snowflake."""
    if is_fixtures():
        return "fixtures"
    raw = os.environ.get("ANALYTICS_DASHBOARD_BACKEND", "postgres").strip().lower()
    if raw not in _BACKENDS:
        raise ValueError(
            f"ANALYTICS_DASHBOARD_BACKEND must be postgres or snowflake, not {raw!r}"
        )
    return raw


def is_postgres() -> bool:
    return backend() == "postgres"


def is_snowflake() -> bool:
    return backend() == "snowflake"


def now() -> dt.datetime:
    pinned = os.environ.get("ANALYTICS_DASHBOARD_NOW")
    if pinned:
        return dt.datetime.fromisoformat(pinned)
    return dt.datetime.now(dt.UTC)


def connection_name() -> str:
    return os.environ.get("ANALYTICS_DASHBOARD_CONNECTION", "weekend-warriors")


def role() -> str:
    if is_postgres():
        return pg_user()
    return os.environ.get("ANALYTICS_DASHBOARD_ROLE", "ANALYTICS_DASHBOARD_ROLE")


def warehouse() -> str:
    return os.environ.get("ANALYTICS_DASHBOARD_WAREHOUSE", "DLT_OPS_WH")


def cache_seconds() -> float:
    return float(os.environ.get("ANALYTICS_DASHBOARD_CACHE_SECONDS", "60"))


def pg_host() -> str:
    return os.environ.get("ANALYTICS_DASHBOARD_PGHOST") or os.environ.get("PGHOST") or ""


def pg_port() -> int:
    return int(os.environ.get("ANALYTICS_DASHBOARD_PGPORT") or os.environ.get("PGPORT") or "5432")


def pg_database() -> str:
    return os.environ.get("ANALYTICS_DASHBOARD_PGDATABASE", "app")


def pg_user() -> str:
    return os.environ.get("ANALYTICS_DASHBOARD_PGUSER", "app_api")


def pg_password() -> str:
    return (
        os.environ.get("ANALYTICS_DASHBOARD_PGPASSWORD")
        or os.environ.get("APP_API_PASSWORD")
        or ""
    )


def pg_sslmode() -> str:
    return os.environ.get("PGSSLMODE", "require")


def app_location(sport_key: str) -> tuple[str, str]:
    """(database, schema) holding a sport's APP marts."""
    stem = sport_key.upper()
    db_override = os.environ.get(f"{stem}_APP_DB")
    schema_override = os.environ.get(f"{stem}_APP_SCHEMA")
    if is_snowflake():
        return (
            db_override or f"{stem}_PROD_DB",
            schema_override or "APP",
        )
    return (
        db_override or pg_database(),
        schema_override or "app_copy",
    )
