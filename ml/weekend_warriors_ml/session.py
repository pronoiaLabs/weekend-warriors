"""Snowpark session: Workspace kernel first, then snow CLI connection."""

from __future__ import annotations

import os

from snowflake.snowpark import Session

DEFAULT_CONNECTION = "weekend-warriors"


def create_session(connection_name: str | None = None) -> Session:
    """CLI / laptop: `connections.toml` via connection_name."""
    name = (
        connection_name
        or os.environ.get("SNOWFLAKE_CONNECTION_NAME")
        or DEFAULT_CONNECTION
    )
    return Session.builder.config("connection_name", name).create()


def get_session(connection_name: str | None = None) -> Session:
    """Workspace Container Runtime uses the kernel session; laptop uses the CLI."""
    try:
        from snowflake.snowpark.context import get_active_session

        return get_active_session()
    except Exception:  # noqa: BLE001 — kernel has no session outside Workspace
        return create_session(connection_name)
