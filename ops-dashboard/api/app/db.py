"""Snowflake session for the dashboard API.

Two auth branches, decided by the presence of /snowflake/session/token, never by an
env var: the token file only exists inside an SPCS container, so a laptop cannot
pretend to be one. Mirrors dlt-pipelines/pipelines/common/snowflake_session.py
(replicated rather than imported: separate uv project).
"""

import json
import os
import threading
import time
from pathlib import Path
from typing import Any

import snowflake.connector

_SPCS_TOKEN = Path("/snowflake/session/token")

_lock = threading.Lock()
_conn: snowflake.connector.SnowflakeConnection | None = None

_CACHE_MAX_ENTRIES = 256
_query_cache: dict[tuple[str, str], tuple[float, list[dict[str, Any]]]] = {}


def in_spcs() -> bool:
    return _SPCS_TOKEN.is_file()


def _connect() -> snowflake.connector.SnowflakeConnection:
    # timezone UTC at the session level: the views expose TIMESTAMP_LTZ, which the
    # connector would otherwise present in the account's local offset (-07:00 here).
    common: dict[str, Any] = {
        "session_parameters": {"TIMEZONE": "UTC"},
        "client_session_keep_alive": True,
    }
    if in_spcs():
        return snowflake.connector.connect(
            host=os.environ["SNOWFLAKE_HOST"],
            account=os.environ["SNOWFLAKE_ACCOUNT"],
            authenticator="oauth",
            token=_SPCS_TOKEN.read_text(),
            warehouse=os.environ.get("SNOWFLAKE_WAREHOUSE"),
            **common,
        )
    return snowflake.connector.connect(
        connection_name=os.environ.get("OPS_DASHBOARD_CONNECTION", "weekend-warriors"),
        **common,
    )


def query(sql: str, params: dict[str, Any] | None = None) -> list[dict[str, Any]]:
    """Run one SELECT, returning rows as dicts with lowercase keys.

    Results are cached for OPS_DASHBOARD_CACHE_SECONDS (default 60): the views
    change at most once per cron fire, so page navigation should cost warehouse
    seconds once per TTL, not once per click. Rows are shallow-copied on every
    hit because datasource normalization rewrites values in place.

    One cached connection per process; a failed cursor tears it down and retries
    once so an expired session heals instead of poisoning every later request.
    """
    key = (sql, json.dumps(params or {}, sort_keys=True, default=str))
    now = time.monotonic()
    hit = _query_cache.get(key)
    if hit is not None and now - hit[0] < _cache_ttl():
        return [dict(row) for row in hit[1]]

    rows = _query_live(sql, params)
    _query_cache[key] = (now, [dict(row) for row in rows])
    if len(_query_cache) > _CACHE_MAX_ENTRIES:
        oldest = min(_query_cache, key=lambda k: _query_cache[k][0])
        del _query_cache[oldest]
    return rows


def _cache_ttl() -> float:
    return float(os.environ.get("OPS_DASHBOARD_CACHE_SECONDS", "60"))


def _query_live(sql: str, params: dict[str, Any] | None) -> list[dict[str, Any]]:
    global _conn
    with _lock:
        for attempt in (1, 2):
            if _conn is None:
                _conn = _connect()
            try:
                cur = _conn.cursor(snowflake.connector.DictCursor)
                try:
                    cur.execute(sql, params or {})
                    return [{k.lower(): v for k, v in row.items()} for row in cur.fetchall()]
                finally:
                    cur.close()
            except snowflake.connector.Error:
                # Closing a dead connection can itself raise; the goal is only
                # to drop it so the retry builds a fresh one.
                try:
                    _conn.close()
                except Exception:  # noqa: BLE001, S110
                    pass
                _conn = None
                if attempt == 2:
                    raise
    raise AssertionError("unreachable")


def parse_variant(value: Any) -> Any:
    """VARIANT columns arrive as JSON strings; None passes through."""
    if value is None or not isinstance(value, str):
        return value
    try:
        return json.loads(value)
    except ValueError:
        return value
