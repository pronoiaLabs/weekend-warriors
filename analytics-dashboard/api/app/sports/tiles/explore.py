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
import time
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
    Sheet(
        id="plays",
        cap=C.EXPLORE_PLAYS,
        label="Plays",
        description="One row per play: situation, the call, the involved players, EPA and the outcome; drive context on matched plays.",
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


class Clause(BaseModel):
    """One parsed piece of the free-text where bar: column op value."""

    column: str
    op: str
    value: Any


class SheetPayload(BaseModel):
    sport: str
    season: int
    as_of: dt.datetime
    sheet: str
    table: str
    columns: list[Column]
    filters: list[Filter]
    # the free-text where bar as sent and as parsed; rides beside the chip
    # filters, both sets AND together
    q: str | None = None
    clauses: list[Clause] = []
    order: str
    desc: bool
    limit: int
    offset: int
    has_more: bool
    elapsed_ms: float = 0
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


def _cmp(row_value: Any, op: str, wanted: Any, col: Column) -> bool:
    """Fixture-side comparison for a parsed where clause."""
    if row_value is None:
        return False
    if op == "=":
        return _same(row_value, wanted, col)
    if op == "!=":
        return not _same(row_value, wanted, col)
    if col.kind in ("date", "datetime"):
        a, b = str(row_value), str(wanted)
    else:
        a, b = float(row_value), float(wanted)
    return {">": a > b, "<": a < b, ">=": a >= b, "<=": a <= b}[op]


# the where bar's grammar: `column op value` chains joined by `and`. Range ops
# apply to numeric and date kinds only; text and boolean take = and != alone.
# No or, no parens, no in -- the minimal grammar a page (or later, an agent)
# can write safely; everything binds, nothing interpolates.
_CLAUSE_RE = re.compile(
    r"([A-Za-z_][A-Za-z0-9_]*)\s*(>=|<=|!=|=|>|<)\s*(\"[^\"]*\"|'[^']*'|\S+)"
)
_AND_RE = re.compile(r"\s*and\s+", re.IGNORECASE)
_RANGE_KINDS = ("integer", "number", "date", "datetime")


def parse_q(q: str, by_name: dict[str, Column], sheet_id: str) -> list[tuple[Column, str, Any]]:
    """The free-text where bar into (column, op, value) triples. Raises
    BadRequest naming the valid columns on an unknown name, the grammar on a
    token that does not parse, and the kind on an op a column cannot take."""
    parsed: list[tuple[Column, str, Any]] = []
    text = q.strip()
    pos = 0
    while pos < len(text):
        if parsed:
            joiner = _AND_RE.match(text, pos)
            if joiner is None:
                raise BadRequest(
                    f"expected 'and' before {text[pos:pos + 20]!r};"
                    " the where bar takes `column op value` joined by and"
                )
            pos = joiner.end()
        m = _CLAUSE_RE.match(text, pos)
        if m is None:
            raise BadRequest(
                f"could not parse {text[pos:pos + 30]!r};"
                " the where bar takes `column op value` (ops = != > < >= <=)"
            )
        name, op, raw = m.group(1), m.group(2), m.group(3)
        pos = m.end()
        col = by_name.get(name.lower())
        if col is None:
            raise BadRequest(
                f"{sheet_id} has no column {name!r}; columns: {', '.join(sorted(by_name))}"
            )
        if op not in ("=", "!=") and col.kind not in _RANGE_KINDS:
            raise BadRequest(f"{col.name} is {col.kind} and takes = or !=, not {op}")
        if raw and raw[0] in "\"'" and raw[0] == raw[-1] and len(raw) >= 2:
            raw = raw[1:-1]
        parsed.append((col, op, coerce(raw, col)))
    if not parsed:
        raise BadRequest("the where bar is empty; write `column op value`")
    return parsed


def rows(
    profile: SportProfile,
    sheet: Sheet,
    *,
    where: list[tuple[str, str]],
    q: str | None = None,
    order: str | None,
    desc: bool,
    limit: int,
    offset: int,
) -> SheetPayload:
    """One page of the sheet: the chip equality filters AND the free-text
    where bar, both bound. Raises BadRequest on a column the sheet lacks, a
    value that does not parse, or a where bar outside the grammar."""
    cols, describe_sql = columns(profile, sheet)
    by_name = {c.name: c for c in cols}
    filters: list[tuple[Column, Any]] = []
    for name, raw in where:
        col = by_name.get(name.lower())
        if col is None:
            raise BadRequest(f"{sheet.id} has no column {name!r}")
        filters.append((col, coerce(raw, col)))
    parsed = parse_q(q, by_name, sheet.id) if q else []
    order_col = (order or "row_id").lower()
    if order_col not in by_name:
        raise BadRequest(f"{sheet.id} has no column {order_col!r} to order by")

    params: dict[str, Any] = {f"w{i}": value for i, (_, value) in enumerate(filters)}
    clauses = [f"{col.name} = %(w{i})s" for i, (col, _) in enumerate(filters)]
    for i, (col, op, value) in enumerate(parsed):
        params[f"q{i}"] = value
        clauses.append(f"{col.name} {op} %(q{i})s")
    where_sql = " and ".join(clauses) or "1 = 1"
    order_items = [f"{order_col} desc" if desc else order_col]
    if order_col != "row_id":
        order_items.append("row_id")

    def matches(r: dict[str, Any]) -> bool:
        return all(_same(r.get(col.name), value, col) for col, value in filters) and all(
            _cmp(r.get(col.name), op, value, col) for col, op, value in parsed
        )

    # one past the page tells the client whether another page exists
    started = time.perf_counter()
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
    elapsed_ms = round((time.perf_counter() - started) * 1000, 1)
    return SheetPayload(
        sport=profile.key,
        season=profile.default_season,
        as_of=config.now(),
        sheet=sheet.id,
        table=profile.tables[sheet.cap],
        columns=cols,
        filters=[Filter(column=col.name, value=value) for col, value in filters],
        q=q,
        clauses=[Clause(column=col.name, op=op, value=value) for col, op, value in parsed],
        order=order_col,
        desc=desc,
        limit=limit,
        offset=offset,
        has_more=len(page) > limit,
        elapsed_ms=elapsed_ms,
        rows=page[:limit],
        query=f"{describe_sql}\n\n{sql}",
    )
