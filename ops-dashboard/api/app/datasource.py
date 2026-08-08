"""The seam between routes and data.

OPS_DASHBOARD_DATA selects the implementation: "live" (default) queries Snowflake,
"fixtures" serves recorded JSON from app/fixtures/ and never imports the connector.
Routes call these functions and know nothing about which is active, which is what
lets tests and offline dev run with zero network.
"""

import json
import os
from datetime import datetime
from pathlib import Path
from typing import Any

_FIXTURES = Path(__file__).parent / "fixtures"


def _mode() -> str:
    return os.environ.get("OPS_DASHBOARD_DATA", "live")


def _fixture(name: str) -> Any:
    return json.loads((_FIXTURES / f"{name}.json").read_text())


def _iso_utc(value: Any) -> Any:
    """datetime -> ISO-8601 with a trailing Z. The session is already UTC."""
    if isinstance(value, datetime):
        return value.strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"
    return value


def list_sports() -> list[str]:
    if _mode() == "fixtures":
        rows = _fixture("registry")
        return sorted(
            {
                r["target_database"]
                for r in rows
                if r.get("schedule") is not None
            }
        )
    from app import registry

    return registry.sports()


def recent_runs(sport: str | None, limit: int) -> list[dict[str, Any]]:
    """Recent runs newest first, each row tagged with its sport."""
    if _mode() == "fixtures":
        runs = _fixture("runs")["runs"]
        if sport:
            runs = [r for r in runs if r["sport"] == sport]
        return runs[:limit]

    from app import db, registry

    wanted = [sport] if sport else registry.sports()
    # Sport names are validated against the registry by the route, so the
    # identifier interpolation below only ever sees registry-derived values.
    branches = [
        f"SELECT '{s}' AS SPORT, * FROM {registry.runs_view(s)}" for s in wanted
    ]
    sql = (
        "SELECT * FROM (" + " UNION ALL ".join(branches) + ") "
        "ORDER BY RUN_STARTED_AT DESC LIMIT %(limit)s"
    )
    rows = db.query(sql, {"limit": limit})
    for row in rows:
        row["row_counts"] = db.parse_variant(row.get("row_counts"))
        row["resources"] = db.parse_variant(row.get("resources"))
        for key in ("run_started_at", "run_ended_at"):
            row[key] = _iso_utc(row.get(key))
    return rows
