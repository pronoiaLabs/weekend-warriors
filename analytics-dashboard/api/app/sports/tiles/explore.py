"""The Explorer: flat sheets, one per grain, read column-for-column.

A sheet is one app_explore_* table. Its columns are its contract, so the
catalog is the table's own description (information_schema on Postgres,
DESCRIBE TABLE on Snowflake; the recorded schema in fixture mode) typed
into the few kinds a grid needs, and a sheet
request is one select with equality filters on named columns, one ORDER BY
column, and a page. Filter and sort columns are validated against the
catalog before any SQL is built, so a client can name only columns the table
has; values are bound. No aggregation happens here: the page pivots and
totals the rows it was given.
"""

import datetime as dt
import re
from typing import Any, Literal

from pydantic import BaseModel

from app import config
from app.sports import fixtures, source
from app.sports.capabilities import Capability as C
from app.sports.profile import SportProfile

Kind = Literal["integer", "number", "text", "boolean", "date", "datetime"]

DEFAULT_LIMIT = 500
MAX_LIMIT = 5000


class Sheet(BaseModel):
    id: str
    cap: C
    label: str
    description: str


# In the order the page lists them; the id is the URL segment.
SHEETS: tuple[Sheet, ...] = (
    Sheet(
        id="player_games",
        cap=C.EXPLORE_PLAYER_GAMES,
        label="Player games",
        description="One row per offensive player game: the box score, fantasy points, the team result.",
    ),
    Sheet(
        id="defender_games",
        cap=C.EXPLORE_DEFENDER_GAMES,
        label="Defender games",
        description="One row per defensive player game: tackles, sacks, pressures, takeaways.",
    ),
    Sheet(
        id="team_games",
        cap=C.EXPLORE_TEAM_GAMES,
        label="Team games",
        description="One row per team game: both sides of the box score and the result, no line.",
    ),
    Sheet(
        id="game_lines",
        cap=C.EXPLORE_GAME_LINES,
        label="Game lines",
        description="One row per game and book with a closing line: opener, close, movement, implied totals, results.",
    ),
    Sheet(
        id="player_props",
        cap=C.EXPLORE_PLAYER_PROPS,
        label="Player props",
        description="One row per prop at a book: the line, the player's form against it, the matchup, the outcome.",
    ),
    Sheet(
        id="news",
        cap=C.EXPLORE_NEWS,
        label="News",
        description="One row per player mention: headline, topic, the sentence, the next game.",
    ),
    Sheet(
        id="line_moves",
        cap=C.EXPLORE_LINE_MOVES,
        label="Line moves",
        description="One row per pregame line change at a book: the snapshot, the change, the move since open.",
    ),
)

BY_ID: dict[str, Sheet] = {s.id: s for s in SHEETS}


class Column(BaseModel):
    name: str
    kind: Kind
    type: str


class SheetRef(BaseModel):
    id: str
    cap: C
    table: str
    label: str
    description: str
    columns: list[Column]


class CatalogPayload(BaseModel):
    sport: str
    as_of: dt.datetime
    sheets: list[SheetRef]
    query: str | None = None


class Filter(BaseModel):
    column: str
    value: Any


class SheetPayload(BaseModel):
    sport: str
    season: int
    as_of: dt.datetime
    sheet: str
    table: str
    columns: list[Column]
    filters: list[Filter]
    order: str
    desc: bool
    limit: int
    offset: int
    has_more: bool
    rows: list[dict[str, Any]]
    query: str | None = None


class BadRequest(ValueError):
    """A filter or sort names a column the sheet lacks, or a value that does not
    parse for the column's kind; the router turns it into a 400."""


def kind_of(sql_type: str) -> Kind:
    t = sql_type.upper()
    if t.startswith("NUMBER"):
        m = re.match(r"NUMBER\((\d+),(\d+)\)", t)
        return "integer" if m and m.group(2) == "0" else "number"
    if t in (
        "INTEGER",
        "INT",
        "INT2",
        "INT4",
        "INT8",
        "BIGINT",
        "SMALLINT",
        "SERIAL",
        "BIGSERIAL",
    ):
        return "integer"
    if t.startswith(("FLOAT", "DOUBLE", "REAL", "DECIMAL", "NUMERIC")):
        return "number"
    if t.startswith("BOOLEAN") or t == "BOOL":
        return "boolean"
    if t.startswith("TIMESTAMP") or t == "TIMESTAMPTZ":
        return "datetime"
    if t == "DATE":
        return "date"
    return "text"


def _is_dlt_column(name: str) -> bool:
    return name.lower().startswith("_dlt_")


def columns(profile: SportProfile, sheet: Sheet) -> tuple[list[Column], str]:
    """The sheet's columns in table order, and the statement that described them."""
    table = profile.tables[sheet.cap]
    sql, params = source.describe_sql(profile, sheet.cap)
    if config.is_fixtures():
        spec = fixtures.schema(table)
        described = [
            {"name": c["name"], "type": c["type"]} for c in (spec or {}).get("columns", [])
        ]
        rendered = source.render(sql, params)
    else:
        described, rendered = source.describe(profile, sheet.cap)
    return [
        Column(name=str(c["name"]).lower(), kind=kind_of(str(c["type"])), type=str(c["type"]))
        for c in described
        if not _is_dlt_column(str(c["name"]))
    ], rendered


def catalog(profile: SportProfile) -> CatalogPayload:
    refs: list[SheetRef] = []
    statements: list[str] = []
    for sheet in SHEETS:
        if not profile.has(sheet.cap):
            continue
        cols, sql = columns(profile, sheet)
        statements.append(sql)
        refs.append(
            SheetRef(
                id=sheet.id,
                cap=sheet.cap,
                table=profile.tables[sheet.cap],
                label=sheet.label,
                description=sheet.description,
                columns=cols,
            )
        )
    return CatalogPayload(
        sport=profile.key, as_of=config.now(), sheets=refs, query="\n".join(statements) or None
    )


def coerce(value: str, col: Column) -> Any:
    try:
        if col.kind == "integer":
            return int(value)
        if col.kind == "number":
            return float(value)
    except ValueError:
        raise BadRequest(f"{col.name} takes a {col.kind}, not {value!r}") from None
    if col.kind == "boolean":
        low = value.strip().lower()
        if low in ("true", "1", "yes"):
            return True
        if low in ("false", "0", "no"):
            return False
        raise BadRequest(f"{col.name} takes true or false, not {value!r}")
    return value


def _same(row_value: Any, wanted: Any, col: Column) -> bool:
    """Fixture-side equality with the row's JSON value; dates are ISO strings."""
    if row_value is None:
        return False
    if col.kind in ("date", "datetime", "text"):
        return str(row_value) == str(wanted)
    if col.kind == "number":
        return float(row_value) == wanted
    return row_value == wanted


def rows(
    profile: SportProfile,
    sheet: Sheet,
    *,
    where: list[tuple[str, str]],
    order: str | None,
    desc: bool,
    limit: int,
    offset: int,
) -> SheetPayload:
    """One page of the sheet with equality filters. Raises BadRequest on a column
    the sheet lacks or a value that does not parse."""
    cols, describe_sql = columns(profile, sheet)
    by_name = {c.name: c for c in cols}
    filters: list[tuple[Column, Any]] = []
    for name, raw in where:
        col = by_name.get(name.lower())
        if col is None:
            raise BadRequest(f"{sheet.id} has no column {name!r}")
        filters.append((col, coerce(raw, col)))
    order_col = (order or "row_id").lower()
    if order_col not in by_name:
        raise BadRequest(f"{sheet.id} has no column {order_col!r} to order by")

    params: dict[str, Any] = {f"w{i}": value for i, (_, value) in enumerate(filters)}
    clauses = [f"{col.name} = %(w{i})s" for i, (col, _) in enumerate(filters)]
    where_sql = " and ".join(clauses) or "1 = 1"
    order_items = [f"{order_col} desc" if desc else order_col]
    if order_col != "row_id":
        order_items.append("row_id")

    def matches(r: dict[str, Any]) -> bool:
        return all(_same(r.get(col.name), value, col) for col, value in filters)

    # one past the page tells the client whether another page exists
    page, sql = source.select(
        profile,
        sheet.cap,
        [c.name for c in cols],
        where=where_sql,
        params=params,
        matches=matches,
        order=order_items,
        tag=f"explore_{sheet.id}",
        limit=limit + 1,
        offset=offset,
    )
    return SheetPayload(
        sport=profile.key,
        season=profile.default_season,
        as_of=config.now(),
        sheet=sheet.id,
        table=profile.tables[sheet.cap],
        columns=cols,
        filters=[Filter(column=col.name, value=value) for col, value in filters],
        order=order_col,
        desc=desc,
        limit=limit,
        offset=offset,
        has_more=len(page) > limit,
        rows=page[:limit],
        query=f"{describe_sql}\n\n{sql}",
    )
