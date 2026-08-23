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


def describe_sql(profile: SportProfile, cap: Capability) -> tuple[str, dict[str, Any]]:
    """Statement that lists a mart's columns. Postgres has no DESCRIBE TABLE."""
    table = profile.tables[cap]
    if config.is_snowflake():
        return f"describe table {profile.fqn(cap)}", {}
    _, schema = profile.location()
    sql = (
        "select column_name as name, data_type as type\n"
        "from information_schema.columns\n"
        "where table_schema = %(schema)s and table_name = %(table)s\n"
        "order by ordinal_position"
    )
    return sql, {"schema": schema, "table": table}


def describe(
    profile: SportProfile, cap: Capability, *, ttl: float | None = 3600
) -> tuple[list[Row], str]:
    """Live column list (name, type), minus dlt metadata, and the rendered SQL."""
    sql, params = describe_sql(profile, cap)
    rows = [
        row
        for row in db.query(
            sql, params, ttl=ttl, tag={"sport": profile.key, "tile": "describe"}
        )
        if not str(row.get("name", "")).lower().startswith("_dlt_")
    ]
    return rows, render(sql, params)


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
    limit: int | None = None,
    offset: int = 0,
) -> tuple[list[Row], str]:
    """Rows from the mart behind `cap`, and the rendered SQL. `limit` and
    `offset` page a sheet; they are validated integers, written as literals."""
    cols = list(columns)
    order_cols = list(order)
    sql = (
        f"select {', '.join(cols)}\nfrom {profile.fqn(cap)}\nwhere {where}\n"
        f"order by {', '.join(order_cols)}"
    )
    if limit is not None:
        sql += f"\nlimit {int(limit)} offset {int(offset)}"
    if config.is_fixtures():
        table = profile.tables[cap]
        rows = [
            {c: r.get(c) for c in cols} for r in fixtures.rows(profile.key, table) if matches(r)
        ]
        # an ORDER BY item is "col" or "col desc"; sorts are stable, so applying
        # them last-key-first yields the same order as the SQL
        for item in reversed(order_cols):
            name, _, direction = item.partition(" ")
            rows.sort(
                key=lambda r, c=name: _sort_key(r.get(c)),
                reverse=direction.strip().lower() == "desc",
            )
        if limit is not None:
            rows = rows[offset : offset + limit]
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
