"""Unit tests for the nflverse adapter. No network, no nflreadpy.

The nflreadpy and polars calls live in fetch_rows, which the source takes as an
injectable seam; everything around it (dataset table, season rules, resource
shape, season stamping, the cursor) is tested with a fake fetch.
"""
from __future__ import annotations

import sys
from pathlib import Path

import pytest

_ROOT = Path(__file__).parent.parent.resolve()
if str(_ROOT) not in sys.path:
    sys.path.insert(0, str(_ROOT))

from pipelines.batch.nflverse_source import (  # noqa: E402
    CURRENT,
    DATASETS,
    Dataset,
    nflverse_source,
    resolve_seasons,
)


def _clock(roster: bool) -> int:
    # Two clocks, as in nflreadpy: game data still 2025 in August, rosters 2026.
    return 2026 if roster else 2025


# ---------------------------------------------------------------------------
# Dataset table
# ---------------------------------------------------------------------------


def test_every_dataset_is_complete() -> None:
    for key, ds in DATASETS.items():
        assert ds.loader.startswith("load_"), key
        assert ds.table.startswith("nflverse_"), key
        assert ds.write_disposition in {"merge", "replace"}, key
        if ds.write_disposition == "merge":
            assert ds.primary_key, f"{key}: merge without a key"
        else:
            assert not ds.primary_key, f"{key}: replace does not need a key"
        if ds.cursor:
            assert ds.cursor in ds.primary_key, f"{key}: cursor must be part of the key"


def test_tables_are_unique() -> None:
    tables = [ds.table for ds in DATASETS.values()]
    assert len(tables) == len(set(tables))


def test_all_history_datasets_are_replaced_and_not_season_keyed() -> None:
    for key in ("players", "officials", "combine", "trades", "teams"):
        ds = DATASETS[key]
        assert not ds.season_keyed, key
        assert ds.write_disposition == "replace", key


def test_nextgen_is_three_disciplines() -> None:
    types = {dict(DATASETS[k].kwargs)["stat_type"] for k in DATASETS if k.startswith("nextgen_")}
    assert types == {"passing", "rushing", "receiving"}


# ---------------------------------------------------------------------------
# Season rules
# ---------------------------------------------------------------------------


def test_current_follows_the_dataset_clock() -> None:
    assert resolve_seasons(CURRENT, DATASETS["pbp"], current_season=_clock) == [2025]
    assert resolve_seasons(None, DATASETS["pbp"], current_season=_clock) == [2025]
    assert resolve_seasons(CURRENT, DATASETS["depth_charts"], current_season=_clock) == [2026]


def test_explicit_seasons_pass_through_sorted_and_deduped() -> None:
    assert resolve_seasons(2024, DATASETS["pbp"], current_season=_clock) == [2024]
    assert resolve_seasons([2025, 2023, 2023], DATASETS["pbp"], current_season=_clock) == [
        2023,
        2025,
    ]


@pytest.mark.parametrize("bad", [True, "2024", [], ["2024"], [2024, True], {"from": 2023}])
def test_bad_seasons_are_named(bad) -> None:
    with pytest.raises(ValueError, match="seasons must be"):
        resolve_seasons(bad, DATASETS["pbp"], current_season=_clock)


def test_depth_chart_shapes_are_split_at_2025() -> None:
    # the file changed shape with the 2025 season: two datasets, two windows
    assert resolve_seasons([2025], DATASETS["depth_charts"], current_season=_clock) == [2025]
    assert resolve_seasons(
        [2023, 2024], DATASETS["depth_charts_weekly"], current_season=_clock
    ) == [2023, 2024]
    with pytest.raises(ValueError, match=r"nflverse_depth_charts holds seasons 2025 to current; \[2024\]"):
        resolve_seasons([2024, 2025], DATASETS["depth_charts"], current_season=_clock)
    with pytest.raises(ValueError, match=r"through 2024"):
        resolve_seasons([2025], DATASETS["depth_charts_weekly"], current_season=_clock)
    with pytest.raises(ValueError):
        # "current" is 2026 on the roster clock, past the weekly shape's window
        resolve_seasons(CURRENT, DATASETS["depth_charts_weekly"], current_season=_clock)


def test_row_hash_datasets_merge_on_row_id() -> None:
    ds = DATASETS["depth_charts_weekly"]
    assert ds.row_hash and ds.primary_key == ("row_id",) and ds.write_disposition == "merge"


def test_a_dataset_entry_may_carry_its_own_seasons() -> None:
    calls: list = []
    src = nflverse_source(
        name="nfl_nflverse_backfill",
        config={
            "seasons": [2023, 2024, 2025],
            "datasets": [
                "injuries",
                {"name": "depth_charts_weekly", "seasons": [2023, 2024]},
                {"name": "depth_charts", "seasons": [2025]},
            ],
        },
        fetch=_fake_fetch(calls),
        current_season=_clock,
    )
    resources = _resources(src)
    assert set(resources) == {
        "nflverse_injuries", "nflverse_depth_charts_weekly", "nflverse_depth_charts",
    }
    for r in resources.values():
        list(r)
    by_table: dict[str, list] = {}
    for table, season, _ in calls:
        by_table.setdefault(table, []).append(season)
    assert by_table == {
        "nflverse_injuries": [2023, 2024, 2025],
        "nflverse_depth_charts_weekly": [2023, 2024],
        "nflverse_depth_charts": [2025],
    }


def test_malformed_dataset_entry_is_named() -> None:
    with pytest.raises(ValueError, match="name or"):
        nflverse_source(
            name="nfl_bad",
            config={"datasets": [{"seasons": [2023]}]},
            fetch=_fake_fetch([]),
            current_season=_clock,
        )


def test_cursor_text_normalises_whatever_dlt_stored() -> None:
    from datetime import date, datetime, timedelta, timezone

    from pipelines.batch.nflverse_source import cursor_text

    assert cursor_text("2026-08-23T07:28:22Z") == "2026-08-23T07:28:22"
    assert cursor_text(datetime(2026, 8, 23, 7, 28, 22, tzinfo=timezone.utc)) == "2026-08-23T07:28:22"
    eastern = datetime(2026, 8, 23, 3, 28, 22, tzinfo=timezone(timedelta(hours=-4)))
    assert cursor_text(eastern) == "2026-08-23T07:28:22"     # converted to UTC
    assert cursor_text(datetime(2026, 8, 23, 7, 28, 22)) == "2026-08-23T07:28:22"  # naive as-is
    assert cursor_text(date(2026, 8, 23)) == "2026-08-23T00:00:00"


# ---------------------------------------------------------------------------
# The source
# ---------------------------------------------------------------------------


def _fake_fetch(calls: list) :
    def fetch(dataset: Dataset, season, *, after=None):
        calls.append((dataset.table, season, after))
        row = {"season": season, "k": f"{dataset.table}-{season}"}
        if dataset.cursor:
            # dlt binds the cursor on iteration and dedups on the key, so a row
            # must carry every key column, cursor included
            for column in dataset.primary_key:
                row[column] = "x"
            row[dataset.cursor] = "2026-08-23T07:00:00Z"
        yield row

    return fetch


def _resources(source) -> dict[str, object]:
    return {r.name: r for r in source.resources.values()}


def test_source_builds_one_resource_per_dataset() -> None:
    calls: list = []
    src = nflverse_source(
        name="nfl_nflverse_stats",
        config={"datasets": ["pbp", "players"], "seasons": CURRENT},
        fetch=_fake_fetch(calls),
        current_season=_clock,
    )
    resources = _resources(src)
    assert set(resources) == {"nflverse_pbp", "nflverse_players"}
    assert resources["nflverse_pbp"].write_disposition == "merge"
    assert resources["nflverse_players"].write_disposition == "replace"

    rows = list(resources["nflverse_pbp"])
    assert rows == [{"season": 2025, "k": "nflverse_pbp-2025"}]  # no cursor, no dt
    assert list(resources["nflverse_players"]) == [{"season": None, "k": "nflverse_players-None"}]
    assert calls == [("nflverse_pbp", 2025, None), ("nflverse_players", None, None)]


def test_backfill_fetches_each_season_in_order() -> None:
    calls: list = []
    src = nflverse_source(
        name="nfl_nflverse_backfill",
        config={"datasets": ["injuries"], "seasons": [2025, 2023, 2024]},
        fetch=_fake_fetch(calls),
        current_season=_clock,
    )
    rows = list(_resources(src)["nflverse_injuries"])
    assert [r["season"] for r in rows] == [2023, 2024, 2025]
    assert [c[1] for c in calls] == [2023, 2024, 2025]


def test_primary_keys_reach_the_resource_hints() -> None:
    src = nflverse_source(
        name="x",
        config={"datasets": ["snap_counts"]},
        fetch=_fake_fetch([]),
        current_season=_clock,
    )
    hints = _resources(src)["nflverse_snap_counts"].compute_table_schema()
    keyed = [c for c, spec in hints["columns"].items() if spec.get("primary_key")]
    assert keyed == ["pfr_game_id", "pfr_player_id"]


def test_depth_charts_carry_a_cursor_and_the_roster_year() -> None:
    calls: list = []
    src = nflverse_source(
        name="nfl_nflverse_depth_charts",
        config={"datasets": ["depth_charts"], "seasons": CURRENT},
        fetch=_fake_fetch(calls),
        current_season=_clock,
    )
    resource = _resources(src)["nflverse_depth_charts"]
    # dlt wraps the function because it carries an incremental argument; the
    # cursor column itself is pinned by the DATASETS integrity test.
    assert resource.incremental is not None
    # Iterating the resource outside a pipeline never has a stored value: the fetch
    # must be asked for everything, not for rows after some sentinel.
    assert list(resource)
    assert calls == [("nflverse_depth_charts", 2026, None)]


@pytest.mark.parametrize(
    "config, message",
    [
        ({}, "at least one dataset"),
        ({"datasets": []}, "at least one dataset"),
        ({"datasets": ["pbp", "rosters"]}, "unknown datasets"),
        ({"datasets": ["pbp", "pbp"]}, "repeats"),
    ],
)
def test_config_errors_name_the_pipeline(config, message) -> None:
    with pytest.raises(ValueError, match=message) as exc:
        nflverse_source(name="nfl_bad", config=config, fetch=_fake_fetch([]), current_season=_clock)
    assert "nfl_bad" in str(exc.value)


# ---------------------------------------------------------------------------
# fetch_rows itself, only where polars is installed (the full suite, not CI-min)
# ---------------------------------------------------------------------------


def test_fetch_rows_filters_stamps_and_slices(monkeypatch) -> None:
    pl = pytest.importorskip("polars")
    import types

    from pipelines.batch import nflverse_source as mod

    frame = pl.DataFrame(
        {
            "dt": ["2026-08-21T07:00:00Z", "2026-08-22T07:00:00Z", "2026-08-23T07:00:00Z"],
            "team": ["KC", "KC", "KC"],
            "pos_id": ["1", "1", "1"],
            "pos_slot": [1, 1, 1],
            "pos_rank": [1, 1, 1],
            "player_name": ["A", "B", None],   # an empty slot: no key, dropped
        }
    )
    fake = types.SimpleNamespace(load_depth_charts=lambda seasons: frame)
    monkeypatch.setitem(sys.modules, "nflreadpy", fake)
    monkeypatch.setattr(mod, "SLICE_ROWS", 1)

    def flat(after=None):
        batches = list(mod.fetch_rows(DATASETS["depth_charts"], 2026, after=after))
        assert all(isinstance(b, list) for b in batches)   # one list per slice
        return [r for b in batches for r in b]

    rows = flat(after="2026-08-21T07:00:00Z")
    assert [r["dt"] for r in rows] == ["2026-08-22T07:00:00Z"]
    assert all(r["season"] == 2026 for r in rows)

    everything = flat()
    assert [r["player_name"] for r in everything] == ["A", "B"]
    # SLICE_ROWS is 1 here, so every surviving row is its own batch
    assert len(list(mod.fetch_rows(DATASETS["depth_charts"], 2026))) == 2


def test_row_id_is_stable_and_collapses_exact_duplicates(monkeypatch) -> None:
    pl = pytest.importorskip("polars")
    import types

    from pipelines.batch import nflverse_source as mod

    frame = pl.DataFrame(
        {
            "season": [2023, 2023, 2023],
            "week": [1, 1, None],
            "club_code": ["ATL", "ATL", "ATL"],
            "gsis_id": ["00-1", "00-1", "00-2"],   # rows 0 and 1 are exact duplicates
        }
    )
    fake = types.SimpleNamespace(load_depth_charts=lambda seasons: frame)
    monkeypatch.setitem(sys.modules, "nflreadpy", fake)

    rows = [r for b in mod.fetch_rows(DATASETS["depth_charts_weekly"], 2023) for r in b]
    ids = [r["row_id"] for r in rows]
    assert len(ids) == 3 and ids[0] == ids[1] and ids[0] != ids[2]
    assert all(len(i) == 32 for i in ids)                      # md5 hex
    assert rows[2]["week"] is None                             # NULL is not a key column here
    # the same rows hash the same on a second pass (no run-dependent salt)
    again = [r["row_id"] for b in mod.fetch_rows(DATASETS["depth_charts_weekly"], 2023) for r in b]
    assert again == ids
