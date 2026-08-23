"""Record rows from a dev build of the APP marts into fixtures/app/<sport>/<table>.json.

Goes through app.db.query, so the fixtures have exactly the shape live tiles see
(lowercase keys, Decimal and timestamp values serialised here). Point the sport at
the dev build and use a role that can read it:

    cd analytics-dashboard/api
    ANALYTICS_DASHBOARD_ROLE=SYSADMIN ANALYTICS_DASHBOARD_WAREHOUSE=DEVELOPMENT_WH \
    NFL_APP_DB=NFL_DEV_DB NFL_APP_SCHEMA=DEV_<user> \
      uv run python scripts/capture_fixtures.py nfl

The selection per table is deliberate and small: enough weeks to exercise every
branch a page has (an upcoming week with lines, a second week for the picker, a
preseason week that is partly played, a completed week with scores), not a copy
of the mart. Rerun after a mart change and commit the result.
"""

import datetime as dt
import decimal
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app import db
from app.sports.capabilities import Capability as C
from app.sports.fixtures import FIXTURES
from app.sports.registry import PROFILES

SELECTION: dict[str, dict[C, str]] = {
    "nfl": {
        C.SCHEDULE: (
            "(season = 2026 and season_type_name = 'Regular Season' and week in (1, 2))"
            " or (season = 2026 and season_type_name = 'Preseason' and week = 3)"
            " or (season = 2025 and season_type_name = 'Regular Season' and week = 18)"
        ),
        C.GAME_PROP_BOARD: "season = 2026",
    },
}


def _json_default(value: object) -> object:
    if isinstance(value, decimal.Decimal):
        return float(value)
    if isinstance(value, dt.datetime | dt.date):
        return value.isoformat()
    raise TypeError(f"unserialisable {type(value).__name__}")


def main(sport: str) -> None:
    profile = PROFILES[sport]
    for cap, where in SELECTION[sport].items():
        table = profile.tables[cap]
        fqn = profile.fqn(cap)
        rows = db.query(
            f"select * from {fqn} where {where}",
            ttl=0,
            tag={"sport": sport, "tile": "capture"},
        )
        out = FIXTURES / sport / f"{table}.json"
        out.parent.mkdir(parents=True, exist_ok=True)
        # one row per line: diffable, and a third of the size of indented JSON
        head = json.dumps({"table": table, "captured_from": fqn, "where": where})[:-1]
        body = ",\n".join(json.dumps(r, default=_json_default, separators=(",", ":")) for r in rows)
        out.write_text(f'{head}, "rows": [\n{body}\n]}}\n')
        print(f"{out.relative_to(FIXTURES.parents[1])}: {len(rows)} rows from {fqn}")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "nfl")
