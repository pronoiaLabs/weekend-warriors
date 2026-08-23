"""The environment contract, in one place.

OPS_DASHBOARD_DATA           live (default) or fixtures; fixtures never open a
                             connection
OPS_DASHBOARD_BACKEND        live store: postgres (default, app.observability as
                             app_api) or snowflake (rollback / make schema)
OPS_DASHBOARD_NOW            ISO-8601 clock pin; the fixture snapshot is frozen,
                             so every "last N days" window is measured from here
OPS_DASHBOARD_CONNECTION     snow CLI connection name on a laptop (weekend-warriors)
OPS_DASHBOARD_ROLE           role to USE after connecting (snowflake only); unset
                             keeps the connection's default
OPS_DASHBOARD_WAREHOUSE      warehouse to USE after connecting (snowflake only)
OPS_DASHBOARD_CACHE_SECONDS  query cache TTL (default 60)
OPS_DASHBOARD_STATIC         built web app to serve; default ../../web/dist
PGHOST / PGPORT / APP_API_PASSWORD
                             Postgres live login. Makefile sources repo-root
                             .env.postgres. User is always app_api.
SNOWFLAKE_HOST / _ACCOUNT / _WAREHOUSE   the SPCS container's OAuth session
"""

import datetime as dt
import os
from pathlib import Path

_BACKENDS = frozenset({"postgres", "snowflake"})


def data_mode() -> str:
    return os.environ.get("OPS_DASHBOARD_DATA", "live")


def is_fixtures() -> bool:
    return data_mode() == "fixtures"


def backend() -> str:
    """Store the API would query: fixtures, postgres, or snowflake."""
    if is_fixtures():
        return "fixtures"
    raw = os.environ.get("OPS_DASHBOARD_BACKEND", "postgres").strip().lower()
    if raw not in _BACKENDS:
        raise ValueError(f"OPS_DASHBOARD_BACKEND must be postgres or snowflake, not {raw!r}")
    return raw


def is_postgres() -> bool:
    return backend() == "postgres"


def is_snowflake() -> bool:
    return backend() == "snowflake"


def now() -> dt.datetime:
    pinned = os.environ.get("OPS_DASHBOARD_NOW")
    if pinned:
        return dt.datetime.fromisoformat(pinned)
    return dt.datetime.now(dt.UTC)


def connection_name() -> str:
    return os.environ.get("OPS_DASHBOARD_CONNECTION", "weekend-warriors")


def role() -> str | None:
    if is_postgres():
        return pg_user()
    return os.environ.get("OPS_DASHBOARD_ROLE") or None


def warehouse() -> str | None:
    return os.environ.get("OPS_DASHBOARD_WAREHOUSE") or None


def cache_seconds() -> float:
    return float(os.environ.get("OPS_DASHBOARD_CACHE_SECONDS", "60"))


def pg_host() -> str:
    return os.environ.get("OPS_DASHBOARD_PGHOST") or os.environ.get("PGHOST") or ""


def pg_port() -> int:
    return int(os.environ.get("OPS_DASHBOARD_PGPORT") or os.environ.get("PGPORT") or "5432")


def pg_database() -> str:
    return os.environ.get("OPS_DASHBOARD_PGDATABASE", "app")


def pg_user() -> str:
    return os.environ.get("OPS_DASHBOARD_PGUSER", "app_api")


def pg_password() -> str:
    return (
        os.environ.get("OPS_DASHBOARD_PGPASSWORD")
        or os.environ.get("APP_API_PASSWORD")
        or ""
    )


def pg_sslmode() -> str:
    return os.environ.get("PGSSLMODE", "require")


def obs_schema() -> str:
    """Schema holding the DLT_DB.OPS copy. Snowflake is DLT_DB.OPS."""
    return os.environ.get("OPS_DASHBOARD_OBS_SCHEMA", "observability")


def static_dir() -> Path | None:
    """The built front end, or None when it has not been built. Resolved
    relative to this package (api/app -> ../../web/dist) so it works regardless
    of the working directory; the override is for the SPCS container."""
    override = os.environ.get("OPS_DASHBOARD_STATIC")
    candidate = Path(override) if override else Path(__file__).resolve().parents[2] / "web" / "dist"
    return candidate if (candidate / "index.html").is_file() else None
