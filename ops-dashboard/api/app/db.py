"""Snowflake session for the dashboard API.

Two auth branches, decided by the presence of /snowflake/session/token, never by an
env var: the token file only exists inside an SPCS container, so a laptop cannot
pretend to be one. Mirrors dlt-pipelines/pipelines/common/snowflake_session.py
(replicated rather than imported: separate uv project).
"""

import json
import os
import threading
from pathlib import Path
from typing import Any

import snowflake.connector

_SPCS_TOKEN = Path("/snowflake/session/token")

_lock = threading.Lock()
_conn: snowflake.connector.SnowflakeConnection | None = None


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

    One cached connection per process; a failed cursor tears it down and retries
    once so an expired session heals instead of poisoning every later request.
    """
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
