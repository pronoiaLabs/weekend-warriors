"""Snowflake session for the analytics dashboard API.

Copied from ops-dashboard/api/app/db.py rather than imported (separate uv project,
separate origin), then changed in three ways that matter here:

  - the session is pinned to ONE role: USE ROLE <ANALYTICS_DASHBOARD_ROLE> and
    USE SECONDARY ROLES NONE on connect. An interactive session carries the
    user's secondary roles, so without the second statement a dashboard role
    would silently read CORE through SYSADMIN and the least-privilege boundary
    would never be tested by the app itself;
  - every query carries a JSON QUERY_TAG ({"app": "analytics-dashboard",
    "sport": ..., "tile": ...}) for cost attribution, read with TRY_PARSE_JSON;
  - the cache TTL can be set per call, because a slate tile and a standings tile
    go stale at different rates.

Two auth branches, decided by the presence of /snowflake/session/token, never by
an env var: the token file only exists inside an SPCS container.
"""

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

_CACHE_MAX_ENTRIES = 512
_query_cache: dict[tuple[str, str], tuple[float, list[dict[str, Any]]]] = {}


def in_spcs() -> bool:
    return _SPCS_TOKEN.is_file()


def _connect() -> Any:
    import snowflake.connector  # lazy: fixture mode never imports the connector

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
            **common,
        )
    else:
        conn = snowflake.connector.connect(connection_name=config.connection_name(), **common)
    cur = conn.cursor()
    try:
        cur.execute(f"use role {config.role()}")
        cur.execute("use secondary roles none")
        cur.execute(f"use warehouse {config.warehouse()}")
    finally:
        cur.close()
    return conn


def query(
    sql: str,
    params: dict[str, Any] | None = None,
    *,
    ttl: float | None = None,
    tag: dict[str, Any] | None = None,
) -> list[dict[str, Any]]:
    """Run one SELECT, returning rows as dicts with lowercase keys.

    Cached for `ttl` seconds (default ANALYTICS_DASHBOARD_CACHE_SECONDS). Rows are
    shallow-copied on every hit because callers shape them in place. One cached
    connection per process; a failed cursor tears it down and retries once.
    """
    key = (sql, json.dumps(params or {}, sort_keys=True, default=str))
    now = time.monotonic()
    hit = _query_cache.get(key)
    if hit is not None and now - hit[0] < (ttl if ttl is not None else config.cache_seconds()):
        return [dict(row) for row in hit[1]]

    rows = _query_live(sql, params, tag)
    _query_cache[key] = (now, [dict(row) for row in rows])
    if len(_query_cache) > _CACHE_MAX_ENTRIES:
        oldest = min(_query_cache, key=lambda k: _query_cache[k][0])
        del _query_cache[oldest]
    return rows


def _query_live(
    sql: str, params: dict[str, Any] | None, tag: dict[str, Any] | None
) -> list[dict[str, Any]]:
    global _conn
    import snowflake.connector

    query_tag = json.dumps({"app": "analytics-dashboard", **(tag or {})}, separators=(",", ":"))
    with _lock:
        for attempt in (1, 2):
            if _conn is None:
                _conn = _connect()
            try:
                cur = _conn.cursor(snowflake.connector.DictCursor)
                try:
                    cur.execute("alter session set query_tag = %(tag)s", {"tag": query_tag})
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


def parse_variant(value: Any) -> Any:
    """VARIANT and ARRAY columns arrive as JSON strings; None passes through."""
    if value is None or not isinstance(value, str):
        return value
    try:
        return json.loads(value)
    except ValueError:
        return value
