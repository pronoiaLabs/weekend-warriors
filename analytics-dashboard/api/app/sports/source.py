"""The one way a tile reads a mart: a single SELECT of named columns with bound
filters, or the same selection applied to the recorded fixture rows.

A tile passes the columns it needs (its row model's fields), a WHERE clause with
%(name)s binds, the matching predicate for fixture rows, and an ORDER BY column
list. It gets the rows and the SQL it would have run with the binds rendered as
literals, which every page shows in its "Show query" expander. No joins, no
aggregation and no per-sport branches live here or in any tile; those belong in
dbt.
"""

import datetime as dt
from collections.abc import Callable, Iterable
from typing import Any

from app import config, db
from app.sports import fixtures
from app.sports.capabilities import Capability
from app.sports.profile import SportProfile

Row = dict[str, Any]
Predicate = Callable[[Row], bool]


def select(
    profile: SportProfile,
    cap: Capability,
    columns: Iterable[str],
    *,
    where: str,
    params: dict[str, Any],
    matches: Predicate,
    order: Iterable[str],
    tag: str,
    ttl: float | None = None,
) -> tuple[list[Row], str]:
    """Rows from the mart behind `cap`, and the rendered SQL."""
    cols = list(columns)
    order_cols = list(order)
    sql = (
        f"select {', '.join(cols)}\nfrom {profile.fqn(cap)}\nwhere {where}\n"
        f"order by {', '.join(order_cols)}"
    )
    if config.is_fixtures():
        table = profile.tables[cap]
        rows = [
            {c: r.get(c) for c in cols} for r in fixtures.rows(profile.key, table) if matches(r)
        ]
        rows.sort(key=lambda r: tuple(_sort_key(r.get(c)) for c in order_cols))
    else:
        rows = db.query(sql, params, ttl=ttl, tag={"sport": profile.key, "tile": tag})
    return rows, render(sql, params)


def render(sql: str, params: dict[str, Any]) -> str:
    """The bound SQL with literals in place of the binds, for display only."""
    out = sql
    for name, value in params.items():
        out = out.replace(f"%({name})s", _literal(value))
    return out + ";"


def _literal(value: Any) -> str:
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int | float):
        return str(value)
    if isinstance(value, dt.date | dt.datetime):
        return f"'{value.isoformat()}'"
    return "'" + str(value).replace("'", "''") + "'"


def _sort_key(value: Any) -> tuple[int, Any]:
    """Nulls last, then the value; strings sort by themselves so ISO timestamps and
    numbers captured as numbers order the way Snowflake would."""
    if value is None:
        return (1, 0)
    if isinstance(value, bool):
        return (0, int(value))
    return (0, value)
