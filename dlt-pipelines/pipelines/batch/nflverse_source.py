"""nflverse source: season files from GitHub releases, read through nflreadpy.

WHY THIS IS A CUSTOM SOURCE
    nflverse publishes each dataset as one parquet file per season on a GitHub
    release, behind a 302 to release-assets.githubusercontent.com. The rest_api
    source reads JSON; it cannot follow a redirect to a binary file and unpack it.
    nflreadpy (nflverse's own Python package) owns the release layout, the asset
    names and the season rules, so this module is a thin adapter around its
    `load_*` functions rather than a re-implementation of their URLs.

    The source type is named for the vendor (`nflverse`). Pipelines keep the
    `nfl_` prefix (`nfl_nflverse_stats`) so the registry tests pin them to the
    NFL databases, and tables carry the vendor too (`nflverse_players`,
    `nflverse_injuries`) because BallDontLie already owns `players`, `injuries`
    and `stats` in the same RAW schema. There is no API key.

CONTENTS
    1. Dataset table ..... Dataset, DATASETS
    2. Season rules ...... resolve_seasons
    3. Rows .............. fetch_rows (the only place nflreadpy and polars are imported)
    4. The source ........ nflverse_source

WHAT ONE RUN DOES
    for each dataset in config.datasets:
        season-keyed  ->  resolve config.seasons ("current" or a list)  ->  one
                          nflreadpy call per season  ->  yield rows in slices
        all-history   ->  one call, the whole file  ->  replace the table

TWO SEASON CLOCKS, NEITHER OURS
    nflreadpy decides what "current" means, and it has two answers. Game data
    (pbp, player stats, snap counts, injuries, Next Gen) rolls to the new year on
    the Thursday after Labor Day; roster-shaped data (depth charts) rolls on
    15 March. Its validators reject a season past that clock, so asking for 2026
    play-by-play in August fails outright. The registry's `{current_season}` token
    (rolling on 1 August) is therefore never used here: `seasons: current` asks
    nflreadpy for its own year per dataset, and the resolved year is logged the
    way run.py logs the rest_api token, because a wrong year is invisible
    afterwards.

FULL WIDTH, ON PURPOSE
    Every column the file carries is loaded (play-by-play is 372 wide). RAW is the
    archive; the prep layer chooses. Rows are yielded in slices so a season of
    play-by-play never sits in memory as 49k dicts at once.

WHERE IT LIVES
    Under `pipelines/`, like the other custom sources: the Dockerfile copies that
    package and nothing else. `nflreadpy` and `polars` are imported inside
    fetch_rows so importing this module needs neither (CI import-checks with a
    minimal set, and generate_tasks.py runs on a runner that has only pyyaml).
"""

from __future__ import annotations

import logging
import os
from collections.abc import Callable, Iterator
from dataclasses import dataclass
from datetime import timezone
from typing import Any

import dlt

log = logging.getLogger("dlt_pipeline.nflverse")

# nflreadpy reads its settings when it is imported. A container is ephemeral, so a
# cache could only ever serve a stale file; tqdm progress bars are noise in a log.
# setdefault so a developer can still opt back in locally.
os.environ.setdefault("NFLREADPY_CACHE", "off")
os.environ.setdefault("NFLREADPY_VERBOSE", "false")

# Rows per yielded slice. Bounds memory for the wide tables without making the
# per-slice to_dicts() overhead matter.
SLICE_ROWS = 5000

CURRENT = "current"

# ---------------------------------------------------------------------------
# 1. Dataset table
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class Dataset:
    """Everything the runner needs to know about one nflverse dataset.

    Held here rather than in the registry so an entry only names datasets and
    seasons; keys and dispositions are facts about the files, not choices.
    """

    loader: str                      # nflreadpy function name
    table: str                       # RAW table, vendor-prefixed
    write_disposition: str           # "merge" or "replace"
    primary_key: tuple[str, ...] = ()
    season_keyed: bool = True        # one file per season vs one all-history file
    roster_year: bool = False        # which nflreadpy clock "current" follows
    stamp_season: bool = False       # the file has no season column; add one
    cursor: str | None = None        # yield only rows past the last loaded value
    kwargs: tuple[tuple[str, Any], ...] = ()


DATASETS: dict[str, Dataset] = {
    "pbp": Dataset(
        loader="load_pbp",
        table="nflverse_pbp",
        write_disposition="merge",
        primary_key=("game_id", "play_id"),
    ),
    "player_stats": Dataset(
        loader="load_player_stats",
        table="nflverse_player_stats",
        write_disposition="merge",
        primary_key=("player_id", "game_id"),
        kwargs=(("summary_level", "week"),),
    ),
    "snap_counts": Dataset(
        loader="load_snap_counts",
        table="nflverse_snap_counts",
        write_disposition="merge",
        primary_key=("pfr_game_id", "pfr_player_id"),
    ),
    # Next Gen Stats are three disjoint tables: a player appears in exactly one
    # discipline, which is why sv_nfl_player_advanced stays disabled downstream.
    "nextgen_passing": Dataset(
        loader="load_nextgen_stats",
        table="nflverse_nextgen_passing",
        write_disposition="merge",
        primary_key=("season", "season_type", "week", "player_gsis_id"),
        kwargs=(("stat_type", "passing"),),
    ),
    "nextgen_rushing": Dataset(
        loader="load_nextgen_stats",
        table="nflverse_nextgen_rushing",
        write_disposition="merge",
        primary_key=("season", "season_type", "week", "player_gsis_id"),
        kwargs=(("stat_type", "rushing"),),
    ),
    "nextgen_receiving": Dataset(
        loader="load_nextgen_stats",
        table="nflverse_nextgen_receiving",
        write_disposition="merge",
        primary_key=("season", "season_type", "week", "player_gsis_id"),
        kwargs=(("stat_type", "receiving"),),
    ),
    "injuries": Dataset(
        loader="load_injuries",
        table="nflverse_injuries",
        write_disposition="merge",
        primary_key=("season", "game_type", "week", "team", "gsis_id"),
    ),
    # A daily snapshot table: every row carries the `dt` it was observed at and
    # the season file grows by one snapshot a day (~3k rows). `dt` is an ISO-8601
    # string in the file, so string comparison orders it correctly.
    "depth_charts": Dataset(
        loader="load_depth_charts",
        table="nflverse_depth_charts",
        write_disposition="merge",
        primary_key=("dt", "team", "pos_id", "pos_slot", "pos_rank", "player_name"),
        roster_year=True,
        stamp_season=True,
        cursor="dt",
    ),
    # All-history files, small, replaced wholesale.
    "players": Dataset(
        loader="load_players",
        table="nflverse_players",
        write_disposition="replace",
        season_keyed=False,
    ),
    "officials": Dataset(
        loader="load_officials",
        table="nflverse_officials",
        write_disposition="replace",
        season_keyed=False,
        kwargs=(("seasons", True),),
    ),
    "combine": Dataset(
        loader="load_combine",
        table="nflverse_combine",
        write_disposition="replace",
        season_keyed=False,
        kwargs=(("seasons", True),),
    ),
    "trades": Dataset(
        loader="load_trades",
        table="nflverse_trades",
        write_disposition="replace",
        season_keyed=False,
    ),
}

# ---------------------------------------------------------------------------
# 2. Season rules
# ---------------------------------------------------------------------------


def resolve_seasons(
    value: Any,
    dataset: Dataset,
    *,
    current_season: Callable[[bool], int],
) -> list[int]:
    """Turn the registry's `seasons` into the years to request for *dataset*.

    `current` (the default) asks nflreadpy's clock for the dataset's kind of data;
    an int or a list of ints passes through. Anything else is a config error and
    says so, because nflreadpy would otherwise raise a bare "Season must be
    between" from inside a container.
    """
    if value is None or value == CURRENT:
        return [int(current_season(dataset.roster_year))]
    if isinstance(value, bool):
        raise ValueError(f"seasons must be 'current' or a list of years, got {value!r}")
    if isinstance(value, int):
        return [value]
    if isinstance(value, (list, tuple)) and value and all(
        isinstance(v, int) and not isinstance(v, bool) for v in value
    ):
        return sorted(set(value))
    raise ValueError(f"seasons must be 'current' or a list of years, got {value!r}")


def cursor_text(value: Any) -> str:
    """The cursor's last value as `YYYY-MM-DDTHH:MM:SS` in UTC, whatever dlt
    hands back: the file's own string (with a Z), a datetime, or a date."""
    if hasattr(value, "astimezone") and hasattr(value, "strftime"):
        tzinfo = getattr(value, "tzinfo", None)
        moment = value.astimezone(timezone.utc) if tzinfo is not None else value
        return moment.strftime("%Y-%m-%dT%H:%M:%S")
    if hasattr(value, "isoformat"):
        return f"{value.isoformat()}T00:00:00"
    return str(value)[:19]


def _nflreadpy_current_season(roster: bool) -> int:
    import nflreadpy  # noqa: PLC0415

    return nflreadpy.get_current_season(roster=roster)


# ---------------------------------------------------------------------------
# 3. Rows
# ---------------------------------------------------------------------------


def fetch_rows(
    dataset: Dataset,
    season: int | None,
    *,
    after: str | None = None,
) -> Iterator[dict[str, Any]]:
    """Load one file through nflreadpy and yield its rows in slices.

    *season* is None for the all-history datasets. *after* is the incremental
    cursor's last value; only rows past it are yielded, filtered in polars before
    any dict is built. The season stamp is applied here because the file itself
    is the only thing that knows which year it is.
    """
    import nflreadpy  # noqa: PLC0415
    import polars as pl  # noqa: PLC0415

    loader = getattr(nflreadpy, dataset.loader)
    kwargs = dict(dataset.kwargs)
    if dataset.season_keyed:
        kwargs["seasons"] = season
    df = loader(**kwargs)

    if dataset.cursor and after is not None:
        # Compare as "YYYY-MM-DDTHH:MM:SS" text on both sides. The file holds ISO
        # strings with a Z; dlt may hand the last value back as that string or as
        # a datetime once the destination has typed the column. Either way the
        # first 19 characters order correctly and ignore the offset spelling.
        floor = cursor_text(after)
        df = df.filter(pl.col(dataset.cursor).cast(pl.Utf8).str.slice(0, 19) > floor)
    if dataset.stamp_season and season is not None:
        df = df.with_columns(pl.lit(season).alias("season"))

    # A merge key cannot be NULL. The files carry a few such rows and they are
    # placeholders, not data: player_stats has one nameless all-zero row per
    # team-game (22 in 2025), depth charts have empty slots with no player (644).
    # Dropped here, counted in the log, so a jump in the count is visible.
    dropped = 0
    if dataset.primary_key:
        keyed = df.filter(pl.all_horizontal([pl.col(c).is_not_null() for c in dataset.primary_key]))
        dropped = df.height - keyed.height
        df = keyed

    log.info(
        "nflverse %s season=%s: %s rows x %s columns%s%s",
        dataset.loader,
        season if season is not None else "all",
        df.height,
        df.width,
        f" (after {after})" if after is not None else "",
        f", dropped {dropped} rows with a NULL key" if dropped else "",
    )
    # One list per slice, not one dict per row. dlt runs every yielded item
    # through its pipe (and the incremental transform) individually; measured at
    # ~300 rows/s for single dicts on the 462k-row depth-chart file, against
    # seconds for the same rows as lists.
    for piece in df.iter_slices(SLICE_ROWS):
        yield piece.to_dicts()


# ---------------------------------------------------------------------------
# 4. The source
# ---------------------------------------------------------------------------


def _make_resource(
    key: str,
    dataset: Dataset,
    seasons: list[int] | None,
    fetch: Callable[..., Iterator[dict[str, Any]]],
) -> Any:
    """One dlt resource per dataset, named for its table."""

    def emit(after: str | None) -> Iterator[dict[str, Any]]:
        if seasons is None:
            yield from fetch(dataset, None, after=after)
            return
        for season in seasons:
            yield from fetch(dataset, season, after=after)

    if dataset.cursor:
        cursor_name = dataset.cursor

        def rows(cursor=dlt.sources.incremental(cursor_name)) -> Iterator[dict[str, Any]]:
            yield from emit(cursor.last_value)

    else:

        def rows() -> Iterator[dict[str, Any]]:
            yield from emit(None)

    rows.__name__ = dataset.table
    return dlt.resource(
        rows,
        name=dataset.table,
        primary_key=list(dataset.primary_key) or None,
        write_disposition=dataset.write_disposition,
    )


@dlt.source(name="nflverse")
def nflverse_source(
    name: str,
    config: dict[str, Any],
    *,
    fetch: Callable[..., Iterator[dict[str, Any]]] | None = None,
    current_season: Callable[[bool], int] | None = None,
) -> Any:
    """One resource per entry in config.datasets. `fetch` and `current_season`
    are the test seams; the defaults go through nflreadpy."""
    keys = list(config.get("datasets") or [])
    if not keys:
        raise ValueError(f"pipeline '{name}': config.datasets must list at least one dataset")
    unknown = [k for k in keys if k not in DATASETS]
    if unknown:
        raise ValueError(
            f"pipeline '{name}': unknown datasets {unknown}; expected from {sorted(DATASETS)}"
        )
    if len(set(keys)) != len(keys):
        raise ValueError(f"pipeline '{name}': config.datasets repeats a dataset")

    fetch = fetch or fetch_rows
    current_season = current_season or _nflreadpy_current_season
    seasons_cfg = config.get("seasons", CURRENT)

    resources = []
    for key in keys:
        dataset = DATASETS[key]
        seasons = (
            resolve_seasons(seasons_cfg, dataset, current_season=current_season)
            if dataset.season_keyed
            else None
        )
        log.info(
            "nflverse %s -> %s seasons=%s",
            key,
            dataset.table,
            seasons if seasons is not None else "all-history",
        )
        resources.append(_make_resource(key, dataset, seasons, fetch))
    return resources
