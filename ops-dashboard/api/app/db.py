"""Database session for the ops dashboard API.

  - live default is Snowflake Postgres (`OPS_DASHBOARD_BACKEND=postgres`) as
    role app_api against database `app`, schema observability (the
    obs_to_postgres copy of DLT_DB.OPS). Snowflake warehouse SQL remains
    as `BACKEND=snowflake` for fixture capture, SPCS, and rollback;
  - the Snowflake session is pinned: TIMEZONE UTC, optional USE ROLE with
    secondary roles off, optional USE WAREHOUSE, JSON QUERY_TAG;
  - the cache TTL is OPS_DASHBOARD_CACHE_SECONDS (default 60).

Two Snowflake auth branches, decided by the presence of /snowflake/session/token,
never by an env var. Postgres auth is APP_API_PASSWORD (see config.py).
Fixture mode never imports a driver.
"""

import datetime as dt
import json
import os
import threading
import time
from pathlib import Path
from typing import Any

from app import config

_SPCS_TOKEN = Path("/snowflake/session/token")

_lock = threading.Lock()
_conn: Any = None
_tag: str | None = None
_applied_tag: str | None = None

_CACHE_MAX_ENTRIES = 256
_query_cache: dict[tuple[str, str], tuple[float, list[dict[str, Any]]]] = {}


def in_spcs() -> bool:
    return _SPCS_TOKEN.is_file()


def _connect_snowflake() -> Any:
    import snowflake.connector  # lazy: fixture / postgres never import this

    common: dict[str, Any] = {
        "session_parameters": {"TIMEZONE": "UTC"},
        "client_session_keep_alive": True,
    }
    if in_spcs():
        conn = snowflake.connector.connect(
            host=os.environ["SNOWFLAKE_HOST"],
            account=os.environ["SNOWFLAKE_ACCOUNT"],
            authenticator="oauth",
            token=_SPCS_TOKEN.read_text(),
            warehouse=os.environ.get("SNOWFLAKE_WAREHOUSE"),
            **common,
        )
    else:
        conn = snowflake.connector.connect(connection_name=config.connection_name(), **common)
    cur = conn.cursor()
    try:
        role = config.role()
        if role:
            cur.execute(f"USE ROLE {role}")
            cur.execute("USE SECONDARY ROLES NONE")
        warehouse = config.warehouse()
        if warehouse:
            cur.execute(f"USE WAREHOUSE {warehouse}")
    finally:
        cur.close()
    return conn


def _connect_postgres() -> Any:
    import psycopg
    from psycopg.rows import dict_row

    if not config.pg_host():
        raise RuntimeError("postgres backend needs PGHOST (source repo-root .env.postgres)")
    if not config.pg_password():
        raise RuntimeError(
            "postgres backend needs APP_API_PASSWORD "
            "(make -C dlt-pipelines setup-postgres-api-password CONFIRM=1)"
        )
    return psycopg.connect(
        host=config.pg_host(),
        port=config.pg_port(),
        dbname=config.pg_database(),
        user=config.pg_user(),
        password=config.pg_password(),
        sslmode=config.pg_sslmode(),
        row_factory=dict_row,
        autocommit=True,
    )


def snowflake_connection() -> Any:
    """A fresh Snowflake connection regardless of the read backend.

    The refresh endpoint CALLs ops procs even when reads come from Postgres.
    Opened per call and closed by the caller; the cached read connection and
    its lock are never involved, so a slow proc cannot block page queries.
    """
    return _connect_snowflake()


def query(
    sql: str,
    params: dict[str, Any] | None = None,
    *,
    ttl: float | None = None,
    tag: dict[str, Any] | None = None,
) -> list[dict[str, Any]]:
    """Run one SELECT, returning rows as dicts with lowercase keys.

    Results are cached for `ttl` seconds (OPS_DASHBOARD_CACHE_SECONDS, default
    60, when None). Rows are shallow-copied on every hit because datasource
    normalisation rewrites values in place. The live statement is recorded on
    the request's trace (datasource.record) so the page can show what ran.

    One cached connection per process; a failed cursor tears it down and retries
    once so an expired session heals instead of poisoning every later request.
    """
    from app import datasource

    datasource.record(sql, params)
    key = (sql, json.dumps(params or {}, sort_keys=True, default=str))
    now = time.monotonic()
    hit = _query_cache.get(key)
    if hit is not None and now - hit[0] < (config.cache_seconds() if ttl is None else ttl):
        return [dict(row) for row in hit[1]]

    _set_tag(tag)
    rows = _query_live(sql, params)
    _query_cache[key] = (now, [dict(row) for row in rows])
    if len(_query_cache) > _CACHE_MAX_ENTRIES:
        oldest = min(_query_cache, key=lambda k: _query_cache[k][0])
        del _query_cache[oldest]
    return rows


def _set_tag(tag: dict[str, Any] | None) -> None:
    """The session's QUERY_TAG, changed only when the tile changes: one ALTER
    SESSION per tile, not per query. Postgres ignores this."""
    global _tag
    wanted = json.dumps({"app": "ops-dashboard", **(tag or {})}, separators=(",", ":"))
    if wanted == _tag:
        return
    _tag = wanted


def _query_live(sql: str, params: dict[str, Any] | None) -> list[dict[str, Any]]:
    if config.is_postgres():
        return _query_live_postgres(sql, params)
    return _query_live_snowflake(sql, params)


def _query_live_postgres(sql: str, params: dict[str, Any] | None) -> list[dict[str, Any]]:
    global _conn
    import psycopg

    with _lock:
        for attempt in (1, 2):
            if _conn is None:
                _conn = _connect_postgres()
            try:
                with _conn.cursor() as cur:
                    cur.execute(sql, params or {})
                    return [{str(k).lower(): v for k, v in row.items()} for row in cur.fetchall()]
            except psycopg.Error:
                try:
                    _conn.close()
                except Exception:  # noqa: BLE001, S110
                    pass
                _conn = None
                if attempt == 2:
                    raise
    raise AssertionError("unreachable")


def _query_live_snowflake(sql: str, params: dict[str, Any] | None) -> list[dict[str, Any]]:
    global _conn, _applied_tag
    import snowflake.connector

    with _lock:
        for attempt in (1, 2):
            if _conn is None:
                _conn = _connect_snowflake()
                _applied_tag = None
            try:
                cur = _conn.cursor(snowflake.connector.DictCursor)
                try:
                    if _tag is not None and _applied_tag != _tag:
                        cur.execute("ALTER SESSION SET QUERY_TAG = %(tag)s", {"tag": _tag})
                        _applied_tag = _tag
                    cur.execute(sql, params or {})
                    return [{k.lower(): v for k, v in row.items()} for row in cur.fetchall()]
                finally:
                    cur.close()
            except snowflake.connector.Error:
                try:
                    _conn.close()
                except Exception:  # noqa: BLE001, S110
                    pass
                _conn = None
                if attempt == 2:
                    raise
    raise AssertionError("unreachable")


def render(sql: str, params: dict[str, Any] | None) -> str:
    """The bound statement with literals in place of the binds, for display only."""
    out = sql.strip()
    for name, value in (params or {}).items():
        out = out.replace(f"%({name})s", _literal(value))
    return out if out.endswith(";") else out + ";"


def _literal(value: Any) -> str:
    if value is None:
        return "NULL"
    if isinstance(value, bool):
        return "TRUE" if value else "FALSE"
    if isinstance(value, int | float):
        return str(value)
    if isinstance(value, dt.date | dt.datetime):
        return f"'{value.isoformat()}'"
    return "'" + str(value).replace("'", "''") + "'"


def parse_variant(value: Any) -> Any:
    """VARIANT, ARRAY, and jsonb columns: JSON strings parse; dicts/lists pass through."""
    if value is None or not isinstance(value, str):
        return value
    try:
        return json.loads(value)
    except ValueError:
        return value
