"""Sleeper source: live player state, trending adds/drops, weekly projections and stats.

WHY THIS IS A CUSTOM SOURCE
    Sleeper's player dump is a dict keyed by player id, not a list, so no
    rest_api data_selector yields one row per player. And every other call
    needs the season, week and season_type that only `/v1/state/nfl` knows:
    the items of one call decide the arguments of the next, which AGENTS.md
    names as the case for a custom source. There is no API key.

    The source type is named for the vendor (`sleeper`); pipelines keep the
    `nfl_` prefix (`nfl_sleeper_market`) so the registry tests pin them to the
    NFL databases; tables carry the vendor (`sleeper_players`) beside the
    BallDontLie and nflverse tables in RAW.

CONTENTS
    1. HTTP ............... get_json (retry on 429 and 5xx; `get` is the test seam)
    2. Week rules ......... resolve_clock
    3. Row shaping ........ state_row, players_rows, trending_rows, stat_rows
    4. The source ......... sleeper_source

WHAT ONE RUN DOES
    GET /v1/state/nfl  ->  season, week, season_type (or the config's pins)
      state        one row per run: a log of Sleeper's week clock         (append)
      players      /v1/players/nfl, ~12k rows incl. 32 DEF team rows      (replace)
      trending     /players/nfl/trending/{add,drop}, 24h counts           (append)
      projections  /projections/nfl/{season}/{week} this week and next    (append)
      stats        /stats/nfl/{season}/{week} this week and last          (merge)

SNAPSHOTS, NOT STATE
    Projections and trending change through the week and their history is the
    point (line-movement for fantasy), so every pull is appended with
    `fetched_at` and the run's state columns. Stats are facts about a played
    week and merge on (player_id, season, season_type, week). The players dump
    is current state only: replaced, once a day, which is what Sleeper's docs
    ask for ("intended only to be used once per day at most").

TWO HOSTS
    `api.sleeper.app/v1` is the documented API (state, players, trending). The
    weekly stats and projections live on `api.sleeper.com` (no /v1), return a
    list of objects with a nested `stats` dict, and are unofficial but the ones
    Sleeper's own app calls. Both hosts are in the network rule.

WHERE IT LIVES
    Under `pipelines/`, like the other custom sources. `requests` arrives with
    dlt; nothing else is imported.
"""

from __future__ import annotations

import logging
import time
from collections.abc import Callable, Iterator
from datetime import datetime, timezone
from typing import Any

import dlt

log = logging.getLogger("dlt_pipeline.sleeper")

APP_HOST = "https://api.sleeper.app/v1"
COM_HOST = "https://api.sleeper.com"
USER_AGENT = "weekend-warriors-dlt/1.0 (+https://github.com/pronoiaLabs/weekend-warriors)"

HTTP_RETRIES = 5
HTTP_TIMEOUT_S = 120
TRENDING_LIMIT = 200
LOOKBACK_HOURS = 24

RESOURCES = ("state", "players", "trending", "projections", "stats")

# Weeks per season_type, so "next week" never asks past the end of a phase.
MAX_WEEK = {"pre": 4, "regular": 18, "post": 5}

# Nested values kept as one JSON column rather than flattened or split into a
# child table. `fantasy_positions` and `competitions` are lists; `metadata` is a
# free-form dict whose keys vary by player.
PLAYER_JSON_COLUMNS = {
    "metadata": {"data_type": "json"},
    "fantasy_positions": {"data_type": "json"},
    "competitions": {"data_type": "json"},
}

# ---------------------------------------------------------------------------
# 1. HTTP
# ---------------------------------------------------------------------------


def _retry_after_seconds(response: Any, attempt: int) -> float:
    raw = getattr(response, "headers", {}).get("Retry-After")
    if raw is not None:
        try:
            return max(float(raw), 1.0)
        except (TypeError, ValueError):
            pass
    return float(min(2**attempt, 60))


def _is_retryable_http_error(exc: BaseException) -> bool:
    name = type(exc).__name__.lower()
    return "timeout" in name or "timeout" in str(exc).lower() or "connection" in name


def get_json(
    url: str,
    *,
    get: Callable[[str], Any] | None = None,
    http_get: Callable[[str], Any] | None = None,
    sleep: Callable[[float], None] = time.sleep,
    retries: int = HTTP_RETRIES,
) -> Any:
    """GET JSON, retrying 429s, 5xxs and read timeouts. `get` is the test seam."""
    if get is not None:
        return get(url)

    if http_get is None:
        import requests  # noqa: PLC0415

        def http_get(u: str) -> Any:
            return requests.get(u, timeout=HTTP_TIMEOUT_S, headers={"User-Agent": USER_AGENT})

    last: Any = None
    for attempt in range(retries):
        try:
            response = http_get(url)
        except Exception as exc:
            if not _is_retryable_http_error(exc) or attempt + 1 >= retries:
                raise
            wait = float(min(2**attempt, 60))
            log.warning("sleeper request error; sleeping %.1fs (%s/%s): %s", wait, attempt + 1, retries, exc)
            sleep(wait)
            continue
        last = response
        status = getattr(response, "status_code", None)
        if status == 429 or (status is not None and status >= 500):
            wait = _retry_after_seconds(response, attempt)
            log.warning("sleeper HTTP %s; sleeping %.1fs (%s/%s)", status, wait, attempt + 1, retries)
            sleep(wait)
            continue
        response.raise_for_status()
        return response.json()
    if last is not None:
        last.raise_for_status()
    raise RuntimeError(f"sleeper GET failed with no response: {url}")


# ---------------------------------------------------------------------------
# 2. Week rules
# ---------------------------------------------------------------------------


def resolve_clock(state: dict[str, Any], config: dict[str, Any]) -> dict[str, Any]:
    """What the run is about: the state stamp for every row, and the phases
    (season, season_type, projection weeks, stat weeks) to request.

    A scheduled run pins nothing and gets one phase from the state call:
    projections for this week and next (a projection exists before the week
    starts and keeps moving until it does), stats for this week and last (a
    week's stats finalize after its Monday game). A backfill pins `seasons`
    and `season_types` (lists, crossed) and optionally `weeks`; without
    `weeks` a phase is every week it has.
    """
    state_season = int(state["season"])
    state_week = int(state.get("week") or 0)
    state_type = str(state.get("season_type") or "regular")
    stamp = {"season": state_season, "state_week": state_week, "season_type": state_type}

    seasons = config.get("seasons")
    types = config.get("season_types")
    if not seasons and not types and not config.get("weeks"):
        if state_type not in MAX_WEEK:
            raise ValueError(f"state season_type {state_type!r} is not one of {sorted(MAX_WEEK)}")
        last = MAX_WEEK[state_type]
        phase = {
            "season": state_season,
            "season_type": state_type,
            "projection_weeks": [w for w in (state_week, state_week + 1) if 1 <= w <= last],
            "stat_weeks": [w for w in (state_week - 1, state_week) if 1 <= w <= last],
        }
        return {**stamp, "phases": [phase]}

    season_list = sorted({int(s) for s in (seasons or [state_season])})
    type_list = list(types or [state_type])
    bad = [t for t in type_list if t not in MAX_WEEK]
    if bad:
        raise ValueError(f"season_types must be from {sorted(MAX_WEEK)}, got {bad}")
    pinned = config.get("weeks")
    phases = []
    for season in season_list:
        for season_type in type_list:
            weeks = (
                sorted({int(w) for w in pinned})
                if pinned
                else list(range(1, MAX_WEEK[season_type] + 1))
            )
            phases.append(
                {
                    "season": season,
                    "season_type": season_type,
                    "projection_weeks": weeks,
                    "stat_weeks": weeks,
                }
            )
    return {**stamp, "phases": phases}


# ---------------------------------------------------------------------------
# 3. Row shaping
# ---------------------------------------------------------------------------


def _stamp(row: dict[str, Any], fetched_at: str, clock: dict[str, Any]) -> dict[str, Any]:
    row["fetched_at"] = fetched_at
    row["state_season"] = clock["season"]
    row["state_week"] = clock["state_week"]
    row["state_season_type"] = clock["season_type"]
    return row


def state_row(state: dict[str, Any], fetched_at: str) -> dict[str, Any]:
    row = dict(state)
    row["season"] = int(row["season"]) if row.get("season") else None
    row["fetched_at"] = fetched_at
    return row


def players_rows(dump: dict[str, Any], fetched_at: str) -> Iterator[dict[str, Any]]:
    """One row per key of the dump; the key is the id even when the body omits it."""
    for player_id, body in dump.items():
        row = dict(body or {})
        row["player_id"] = str(row.get("player_id") or player_id)
        row["fetched_at"] = fetched_at
        yield row


def trending_rows(
    items: list[dict[str, Any]],
    direction: str,
    fetched_at: str,
    clock: dict[str, Any],
) -> Iterator[dict[str, Any]]:
    for rank, item in enumerate(items, start=1):
        yield _stamp(
            {
                "player_id": str(item["player_id"]),
                "direction": direction,
                "count": item.get("count"),
                "rank": rank,
                "lookback_hours": LOOKBACK_HOURS,
            },
            fetched_at,
            clock,
        )


def stat_rows(
    items: list[dict[str, Any]],
    fetched_at: str,
    clock: dict[str, Any],
) -> Iterator[dict[str, Any]]:
    """Flatten the api.sleeper.com list shape: `stats.*` become columns, the
    embedded `player` is dropped (sleeper_players has it), the rest is kept."""
    for item in items:
        row = {k: v for k, v in item.items() if k not in ("stats", "player")}
        row["player_id"] = str(row.get("player_id"))
        if row.get("season") is not None:
            row["season"] = int(row["season"])
        for key, value in (item.get("stats") or {}).items():
            row[key] = value
        yield _stamp(row, fetched_at, clock)


# ---------------------------------------------------------------------------
# 4. The source
# ---------------------------------------------------------------------------


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


@dlt.source(name="sleeper")
def sleeper_source(
    name: str,
    config: dict[str, Any],
    *,
    get: Callable[[str], Any] | None = None,
    now: Callable[[], str] = _now_iso,
) -> Any:
    """One resource per entry in config.resources. `get` is the test seam."""
    wanted = list(config.get("resources") or [])
    if not wanted:
        raise ValueError(f"pipeline '{name}': config.resources must list at least one resource")
    unknown = [r for r in wanted if r not in RESOURCES]
    if unknown:
        raise ValueError(
            f"pipeline '{name}': unknown resources {unknown}; expected from {list(RESOURCES)}"
        )

    fetched_at = now()
    state = get_json(f"{APP_HOST}/state/nfl", get=get)
    clock = resolve_clock(state, config)
    log.info(
        "sleeper clock: season=%s type=%s week=%s; phases=%s",
        clock["season"],
        clock["season_type"],
        clock["state_week"],
        [
            (p["season"], p["season_type"], p["projection_weeks"], p["stat_weeks"])
            for p in clock["phases"]
        ],
    )

    @dlt.resource(name="sleeper_state", write_disposition="append")
    def sleeper_state() -> Iterator[dict[str, Any]]:
        yield state_row(state, fetched_at)

    @dlt.resource(
        name="sleeper_players",
        write_disposition="replace",
        columns=PLAYER_JSON_COLUMNS,
    )
    def sleeper_players() -> Iterator[dict[str, Any]]:
        dump = get_json(f"{APP_HOST}/players/nfl", get=get)
        log.info("sleeper players: %s entries", len(dump))
        yield from players_rows(dump, fetched_at)

    @dlt.resource(name="sleeper_trending", write_disposition="append")
    def sleeper_trending() -> Iterator[dict[str, Any]]:
        for direction in ("add", "drop"):
            url = (
                f"{APP_HOST}/players/nfl/trending/{direction}"
                f"?lookback_hours={LOOKBACK_HOURS}&limit={TRENDING_LIMIT}"
            )
            items = get_json(url, get=get) or []
            log.info("sleeper trending %s: %s players", direction, len(items))
            yield from trending_rows(items, direction, fetched_at, clock)

    def weekly(kind: str, weeks_key: str) -> Iterator[dict[str, Any]]:
        for phase in clock["phases"]:
            for week in phase[weeks_key]:
                url = (
                    f"{COM_HOST}/{kind}/nfl/{phase['season']}/{week}"
                    f"?season_type={phase['season_type']}"
                )
                items = get_json(url, get=get) or []
                log.info(
                    "sleeper %s %s %s wk%s: %s rows",
                    kind,
                    phase["season"],
                    phase["season_type"],
                    week,
                    len(items),
                )
                yield from stat_rows(items, fetched_at, clock)

    @dlt.resource(name="sleeper_projections", write_disposition="append")
    def sleeper_projections() -> Iterator[dict[str, Any]]:
        yield from weekly("projections", "projection_weeks")

    @dlt.resource(
        name="sleeper_stats",
        write_disposition="merge",
        primary_key=["player_id", "season", "season_type", "week"],
    )
    def sleeper_stats() -> Iterator[dict[str, Any]]:
        yield from weekly("stats", "stat_weeks")

    available = {
        "state": sleeper_state,
        "players": sleeper_players,
        "trending": sleeper_trending,
        "projections": sleeper_projections,
        "stats": sleeper_stats,
    }
    return [available[r] for r in wanted]
