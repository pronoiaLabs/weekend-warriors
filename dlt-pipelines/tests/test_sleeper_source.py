"""Unit tests for the Sleeper source. No network: `get` is injected."""
from __future__ import annotations

import sys
from pathlib import Path

import pytest

_ROOT = Path(__file__).parent.parent.resolve()
if str(_ROOT) not in sys.path:
    sys.path.insert(0, str(_ROOT))

from pipelines.batch.sleeper_source import (  # noqa: E402
    APP_HOST,
    COM_HOST,
    LOOKBACK_HOURS,
    get_json,
    players_rows,
    resolve_clock,
    sleeper_source,
    stat_rows,
    state_row,
    trending_rows,
)

_STATE = {
    "week": 2,
    "leg": 0,
    "season": "2026",
    "season_type": "pre",
    "league_season": "2026",
    "previous_season": "2025",
    "season_start_date": "2026-08-06",
    "display_week": 2,
    "league_create_season": "2026",
    "season_has_scores": True,
}

_NOW = "2026-08-23T16:00:00+00:00"


# ---------------------------------------------------------------------------
# Week rules
# ---------------------------------------------------------------------------


def test_scheduled_run_reads_the_state_clock() -> None:
    clock = resolve_clock(_STATE, {})
    assert (clock["season"], clock["season_type"], clock["state_week"]) == (2026, "pre", 2)
    [phase] = clock["phases"]
    assert phase["projection_weeks"] == [2, 3]   # this week and next
    assert phase["stat_weeks"] == [1, 2]         # last week and this


def test_week_lists_stop_at_the_phase_edges() -> None:
    first = resolve_clock({**_STATE, "season_type": "regular", "week": 1}, {})["phases"][0]
    assert first["stat_weeks"] == [1]            # no week 0
    last = resolve_clock({**_STATE, "season_type": "regular", "week": 18}, {})["phases"][0]
    assert last["projection_weeks"] == [18]      # no week 19


def test_backfill_crosses_seasons_and_types_over_every_week() -> None:
    clock = resolve_clock(
        _STATE, {"seasons": [2024, 2023], "season_types": ["regular", "post"]}
    )
    # the stamp is still the live state, so a backfill row says when it was taken
    assert (clock["season"], clock["state_week"]) == (2026, 2)
    phases = [(p["season"], p["season_type"], len(p["stat_weeks"])) for p in clock["phases"]]
    assert phases == [
        (2023, "regular", 18), (2023, "post", 5),
        (2024, "regular", 18), (2024, "post", 5),
    ]


def test_pinned_weeks_apply_to_both_lists() -> None:
    [phase] = resolve_clock(_STATE, {"weeks": [3, 1, 3]})["phases"]
    assert phase["season"] == 2026 and phase["season_type"] == "pre"
    assert phase["projection_weeks"] == [1, 3]
    assert phase["stat_weeks"] == [1, 3]


def test_unknown_season_type_is_named() -> None:
    with pytest.raises(ValueError, match="season_types"):
        resolve_clock(_STATE, {"season_types": ["playoffs"]})


# ---------------------------------------------------------------------------
# Row shaping
# ---------------------------------------------------------------------------


def test_state_row_types_the_season_and_stamps() -> None:
    row = state_row(_STATE, _NOW)
    assert row["season"] == 2026 and row["fetched_at"] == _NOW and row["week"] == 2


def test_players_rows_take_the_id_from_the_key() -> None:
    dump = {
        "4046": {"player_id": "4046", "first_name": "Patrick", "gsis_id": "00-0033873"},
        "KC": {"first_name": "Kansas City", "position": "DEF"},   # team row, no player_id
    }
    rows = list(players_rows(dump, _NOW))
    assert [r["player_id"] for r in rows] == ["4046", "KC"]
    assert all(r["fetched_at"] == _NOW for r in rows)


def test_trending_rows_carry_direction_and_rank() -> None:
    clock = resolve_clock(_STATE, {})
    items = [{"player_id": "13602", "count": 85615}, {"player_id": 10218, "count": 50862}]
    rows = list(trending_rows(items, "add", _NOW, clock))
    assert [(r["player_id"], r["rank"], r["direction"]) for r in rows] == [
        ("13602", 1, "add"),
        ("10218", 2, "add"),
    ]
    assert rows[0]["lookback_hours"] == LOOKBACK_HOURS
    assert (rows[0]["state_season"], rows[0]["state_week"], rows[0]["state_season_type"]) == (
        2026, 2, "pre",
    )


def test_stat_rows_flatten_stats_and_drop_the_player_blob() -> None:
    clock = resolve_clock(_STATE, {})
    items = [
        {
            "player_id": "3294",
            "season": "2025",
            "week": 1,
            "season_type": "regular",
            "team": "DAL",
            "opponent": "PHI",
            "game_id": "202510126",
            "category": "proj",
            "stats": {"pts_ppr": 20.6, "pass_yd": 253.84},
            "player": {"first_name": "Dak", "last_name": "Prescott"},
        }
    ]
    [row] = list(stat_rows(items, _NOW, clock))
    assert row["season"] == 2025 and row["player_id"] == "3294"
    assert row["pts_ppr"] == 20.6 and row["pass_yd"] == 253.84
    assert "player" not in row and "stats" not in row
    assert row["fetched_at"] == _NOW and row["state_season"] == 2026


# ---------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------


class _Resp:
    def __init__(self, status: int, body=None, headers=None):
        self.status_code = status
        self._body = body
        self.headers = headers or {}

    def raise_for_status(self):
        if self.status_code >= 400:
            raise RuntimeError(f"HTTP {self.status_code}")

    def json(self):
        return self._body


def test_get_json_retries_429_and_5xx_then_returns() -> None:
    responses = [_Resp(429, headers={"Retry-After": "2"}), _Resp(503), _Resp(200, {"ok": 1})]
    slept: list[float] = []
    body = get_json(
        "u", http_get=lambda u: responses.pop(0), sleep=slept.append, retries=5
    )
    assert body == {"ok": 1}
    assert slept == [2.0, 2.0]   # Retry-After honoured, then 2**1


def test_get_json_does_not_retry_4xx() -> None:
    with pytest.raises(RuntimeError, match="HTTP 404"):
        get_json("u", http_get=lambda u: _Resp(404), sleep=lambda s: None)


# ---------------------------------------------------------------------------
# The source
# ---------------------------------------------------------------------------


def _fake_get(calls: list):
    def get(url: str):
        calls.append(url)
        if url.endswith("/state/nfl"):
            return _STATE
        if url.endswith("/players/nfl"):
            return {"4046": {"player_id": "4046", "first_name": "Patrick"}}
        if "/trending/" in url:
            return [{"player_id": "1", "count": 10}]
        if "/projections/" in url or "/stats/" in url:
            return [{"player_id": "1", "season": "2026", "week": 2, "season_type": "pre", "stats": {"gp": 1}}]
        raise AssertionError(url)

    return get


def _resources(source) -> dict[str, object]:
    return {r.name: r for r in source.resources.values()}


def test_source_builds_only_the_requested_resources() -> None:
    calls: list = []
    src = sleeper_source(
        name="nfl_sleeper_players",
        config={"resources": ["state", "players"]},
        get=_fake_get(calls),
        now=lambda: _NOW,
    )
    resources = _resources(src)
    assert set(resources) == {"sleeper_state", "sleeper_players"}
    assert calls == [f"{APP_HOST}/state/nfl"]          # state is read once, up front
    assert list(resources["sleeper_state"])[0]["season"] == 2026
    assert list(resources["sleeper_players"])[0]["player_id"] == "4046"
    assert resources["sleeper_players"].write_disposition == "replace"
    assert resources["sleeper_state"].write_disposition == "append"


def test_market_resources_walk_the_clock() -> None:
    calls: list = []
    src = sleeper_source(
        name="nfl_sleeper_market",
        config={"resources": ["trending", "projections", "stats"]},
        get=_fake_get(calls),
        now=lambda: _NOW,
    )
    resources = _resources(src)
    assert len(list(resources["sleeper_trending"])) == 2          # add + drop
    assert len(list(resources["sleeper_projections"])) == 2       # weeks 2 and 3
    assert len(list(resources["sleeper_stats"])) == 2             # weeks 1 and 2
    assert f"{COM_HOST}/projections/nfl/2026/3?season_type=pre" in calls
    assert f"{COM_HOST}/stats/nfl/2026/1?season_type=pre" in calls
    assert f"{APP_HOST}/players/nfl/trending/drop?lookback_hours={LOOKBACK_HOURS}&limit=200" in calls
    assert resources["sleeper_stats"].write_disposition == "merge"
    assert resources["sleeper_projections"].write_disposition == "append"


@pytest.mark.parametrize(
    "config, message",
    [
        ({}, "at least one resource"),
        ({"resources": ["players", "leagues"]}, "unknown resources"),
    ],
)
def test_config_errors_name_the_pipeline(config, message) -> None:
    with pytest.raises(ValueError, match=message) as exc:
        sleeper_source(name="nfl_bad", config=config, get=_fake_get([]), now=lambda: _NOW)
    assert "nfl_bad" in str(exc.value)
