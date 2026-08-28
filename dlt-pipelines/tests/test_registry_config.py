"""Unit tests for the config-as-data layer: spec_from_row + registry_sync SQL.

Pure Python. No Snowflake, no dlt, no network. Only pyyaml is required (pulled
in transitively via pipelines.batch.models).
"""

from __future__ import annotations

import json
import sys
from datetime import date
from pathlib import Path

import pytest

_ROOT = Path(__file__).parent.parent.resolve()
if str(_ROOT) not in sys.path:
    sys.path.insert(0, str(_ROOT))

# models imports yaml at module load; skip cleanly if pyyaml is absent.
pytest.importorskip("yaml")

from pipelines.batch.models import (  # noqa: E402
    ENVIRONMENTS,
    PipelineSpec,
    RegistryError,
    current_season,
    load_registry,
    resolve_database,
    spec_from_row,
)


# ---------------------------------------------------------------------------
# resolve_database: registry stem + environment -> full database name
# ---------------------------------------------------------------------------


def _spec(**overrides) -> PipelineSpec:
    kwargs = {"name": "p", "source": "rest_api", "config": {"a": 1}}
    kwargs.update(overrides)
    return PipelineSpec(**kwargs)


def test_resolve_database_composes_stem_and_environment():
    spec = _spec(database="NFL")
    assert resolve_database(spec, "DEV") == "NFL_DEV_DB"
    assert resolve_database(spec, "PROD") == "NFL_PROD_DB"


def test_resolve_database_default_stem_keeps_the_shared_databases():
    # A pipeline that names no sport must land where everything landed before the
    # per-sport split, so `sample` and anything new stay working untouched.
    assert resolve_database(_spec(), "DEV") == "DLT_DEV_DB"
    assert resolve_database(_spec(), "PROD") == "DLT_PROD_DB"


@pytest.mark.parametrize("env", ["dev", "Prod", " prod "])
def test_resolve_database_accepts_case_and_padding(env):
    assert resolve_database(_spec(database="NFL"), env).startswith("NFL_")


@pytest.mark.parametrize("env", ["staging", "", "DEVELOPMENT", None])
def test_resolve_database_rejects_unknown_environment(env):
    # An unknown environment would compose a plausible name for a database that does
    # not exist, and the failure would surface far from the typo.
    with pytest.raises(RegistryError) as exc:
        resolve_database(_spec(database="NFL"), env)
    assert "environment" in str(exc.value)


@pytest.mark.parametrize("stem", ["", "NFL-DB", "NFL DB", "NFL;DROP", "1NFL", None])
def test_database_stem_must_be_a_bare_identifier(stem):
    # The stem is interpolated into Task DDL and into the job spec USING clause,
    # neither of which is parameterised.
    with pytest.raises(RegistryError) as exc:
        _spec(database=stem).validate()
    assert "`database`" in str(exc.value)


def test_every_environment_is_resolvable():
    for env in ENVIRONMENTS:
        assert resolve_database(_spec(database="NFL"), env).endswith("_DB")


# ---------------------------------------------------------------------------
# The real registry, not a fixture: these are the names data actually lands in
# ---------------------------------------------------------------------------


def test_real_registry_sends_every_nfl_pipeline_to_the_nfl_databases():
    registry = load_registry()
    nfl = [s for s in registry.pipelines if s.name.startswith("nfl_")]
    assert nfl, "expected the NFL pipelines to be present"

    for spec in nfl:
        assert resolve_database(spec, "DEV") == "NFL_DEV_DB"
        assert resolve_database(spec, "PROD") == "NFL_PROD_DB"
        # The sport lives in the database name now, so repeating it in the schema
        # would give NFL_PROD_DB.RAW_NFL. The Postgres copy is the exception: it
        # writes app.app_copy, not a Snowflake RAW schema.
        expected_dataset = "app_copy" if spec.destination == "postgres" else "RAW"
        assert spec.dataset_name == expected_dataset, (
            f"{spec.name}: dataset_name should be {expected_dataset}, got {spec.dataset_name}"
        )


def test_real_registry_sends_every_ncaaf_pipeline_to_the_ncaaf_databases():
    """The second sport follows the same database-stem discipline as the first."""
    registry = load_registry()
    ncaaf = [s for s in registry.pipelines if s.name.startswith("ncaaf_")]
    assert ncaaf, "expected the NCAAF pipelines to be present"

    for spec in ncaaf:
        assert resolve_database(spec, "DEV") == "NCAAF_DEV_DB"
        assert resolve_database(spec, "PROD") == "NCAAF_PROD_DB"
        assert spec.dataset_name == "RAW"
        # Assert the declaration rather than inheriting a silent fallback.
        assert spec.season_rollover_month == 8, (
            f"{spec.name}: college football seasons open in August"
        )


def test_each_source_declares_one_rollover_month() -> None:
    """A league whose pipelines disagree about its own season boundary.

    Nothing downstream would notice: each pipeline resolves its own token, so the
    symptom is one table holding 2026 while its neighbour holds 2027, which reads like
    a load failure rather than a config error.
    """
    by_source: dict[str, set[int]] = {}
    for spec in load_registry().pipelines:
        by_source.setdefault(spec.name.split("_", 1)[0], set()).add(spec.season_rollover_month)

    for source, months in by_source.items():
        assert len(months) == 1, f"{source}: conflicting rollover months {months}"


def test_real_registry_leaves_sample_in_the_shared_databases():
    # sample is the credential-free smoke test. It must not depend on any sport's
    # database existing, or a broken sport would take the smoke test down with it.
    sample = load_registry().get("sample")
    assert resolve_database(sample, "DEV") == "DLT_DEV_DB"


# ---------------------------------------------------------------------------
# current_season: which NFL season is "now"
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "day, expected",
    [
        (date(2026, 7, 31), 2025),  # offseason: last COMPLETED season
        (date(2026, 8, 1), 2026),  # rollover, preseason opens this month
        (date(2026, 8, 6), 2026),  # Hall of Fame Game
        (date(2026, 9, 9), 2026),  # regular season opener
        (date(2026, 12, 25), 2026),  # Christmas games
        (date(2027, 1, 10), 2026),  # Week 18 is still the 2026 season
        (date(2027, 2, 14), 2026),  # Super Bowl LXI, likewise
        (date(2027, 7, 31), 2026),  # whole offseason stays on 2026
        (date(2027, 8, 1), 2027),  # next rollover
    ],
)
def test_current_season_rolls_over_on_1_august(day, expected) -> None:
    assert current_season(today=day) == expected


def test_current_season_does_not_roll_over_at_the_super_bowl() -> None:
    # The tempting alternative. It would make every February-to-July load ask for a
    # season that has not been played, and the API answers that with an empty list
    # rather than an error, so the run would look fine and load nothing.
    assert current_season(today=date(2027, 3, 1)) == 2026


# ---------------------------------------------------------------------------
# Scheduled pipelines must carry what a Task cannot pass
# ---------------------------------------------------------------------------


def test_scheduled_pipeline_without_eai_is_rejected() -> None:
    with pytest.raises(RegistryError) as exc:
        _spec(schedule="0 9 * * *").validate()
    assert "external_access" in str(exc.value)


def test_sql_database_is_not_a_supported_source() -> None:
    with pytest.raises(RegistryError) as exc:
        _spec(source="sql_database").validate()
    assert "not supported" in str(exc.value)


def test_after_and_schedule_are_mutually_exclusive() -> None:
    with pytest.raises(RegistryError) as exc:
        _spec(
            schedule="0 9 * * *",
            after="NFL_PROD_DB.OPS.DBT_HARVEST_NFL",
            external_access="POSTGRES_APP_EAI",
            secret="DLT_DB.OPS.POSTGRES_APP_COPY",
            env_var="DESTINATION__POSTGRES__CREDENTIALS__PASSWORD",
        ).validate()
    assert "mutually exclusive" in str(exc.value)


def test_after_pipeline_requires_eai_and_secret_pair() -> None:
    with pytest.raises(RegistryError) as exc:
        _spec(after="NFL_PROD_DB.OPS.DBT_HARVEST_NFL").validate()
    assert "external_access" in str(exc.value)

    with pytest.raises(RegistryError) as exc:
        _spec(
            after="NFL_PROD_DB.OPS.DBT_HARVEST_NFL",
            external_access="POSTGRES_APP_EAI",
        ).validate()
    assert "secret" in str(exc.value)

    _spec(
        after="NFL_PROD_DB.OPS.DBT_HARVEST_NFL",
        external_access="POSTGRES_APP_EAI",
        secret="DLT_DB.OPS.POSTGRES_APP_COPY",
        env_var="DESTINATION__POSTGRES__CREDENTIALS__PASSWORD",
    ).validate()


def test_after_must_be_a_fully_qualified_task_name() -> None:
    with pytest.raises(RegistryError) as exc:
        _spec(
            after="DBT_HARVEST_NFL",
            external_access="POSTGRES_APP_EAI",
            secret="DLT_DB.OPS.POSTGRES_APP_COPY",
            env_var="DESTINATION__POSTGRES__CREDENTIALS__PASSWORD",
        ).validate()
    assert "fully-qualified" in str(exc.value)


def test_scheduled_pipeline_without_a_secret_is_accepted_when_eai_is_set() -> None:
    # Open-Meteo: no key, but the container still needs egress.
    _spec(schedule="0 9 * * *", external_access="OPENMETEO_API_EAI").validate()


def test_scheduled_pipeline_cannot_declare_secret_without_env_var() -> None:
    with pytest.raises(RegistryError) as exc:
        _spec(
            schedule="0 9 * * *",
            external_access="NFL_API_EAI",
            secret="DLT_DB.OPS.NFL_API_KEY",
        ).validate()
    assert "secret" in str(exc.value) and "env_var" in str(exc.value)


def test_unscheduled_pipeline_needs_no_bindings() -> None:
    # `sample` is exactly this: no schedule, no secret, no egress.
    _spec().validate()


@pytest.mark.parametrize(
    "loader_file_format", ["csv", "insert_values", "jsonl", "model", "parquet"]
)
def test_known_loader_file_formats_are_accepted(loader_file_format) -> None:
    _spec(config={"loader_file_format": loader_file_format}).validate()


def test_unknown_loader_file_format_is_rejected() -> None:
    with pytest.raises(RegistryError, match="config.loader_file_format"):
        _spec(config={"loader_file_format": "xlsx"}).validate()


def test_skip_unchanged_requires_boolean_and_snowflake_app() -> None:
    with pytest.raises(RegistryError, match="must be a boolean"):
        _spec(config={"skip_unchanged": "yes"}).validate()
    with pytest.raises(RegistryError, match="only supported for the snowflake_app"):
        _spec(config={"skip_unchanged": True}).validate()

    _spec(
        source="snowflake_app",
        config={"tables": ["app_game_slate"], "skip_unchanged": True},
    ).validate()


@pytest.mark.parametrize("month", [0, 13, -1, 8.5, "8", None, True])
def test_rollover_month_outside_1_to_12_is_rejected(month) -> None:
    """A bad rollover month produces a wrong YEAR, not an error, so validate() must.

    current_season compares `day.month >= rollover_month`. A 0 makes every date resolve
    to the current calendar year and a 13 makes every date resolve to the previous one.
    Both are plausible years the API accepts, so the load succeeds and quietly holds the
    wrong season.

    True is in the list because bool subclasses int in Python, so `1 <= True <= 12`
    passes on its own and a stray `season_rollover_month: yes` in YAML would be read as
    January.
    """
    with pytest.raises(RegistryError) as exc:
        _spec(season_rollover_month=month).validate()
    assert "season_rollover_month" in str(exc.value)


@pytest.mark.parametrize("month", [1, 5, 8, 12])
def test_valid_rollover_months_are_accepted(month) -> None:
    _spec(season_rollover_month=month).validate()


def test_real_registry_every_scheduled_pipeline_can_actually_run() -> None:
    """The check that stops a 09:00 UTC surprise.

    A Task passes no arguments. A scheduled pipeline missing its secret dies on
    dlt.secrets inside a container; one missing its EAI has no network at all. Both
    fail where nobody is watching, hours after the mistake was made.
    """
    scheduled = [s for s in load_registry().pipelines if s.schedule]
    assert scheduled, "expected the NFL pipelines to be scheduled"

    for spec in scheduled:
        assert spec.external_access, f"{spec.name}: scheduled but no external_access"
        if spec.secret or spec.env_var:
            assert spec.secret, f"{spec.name}: env_var without secret"
            assert spec.env_var, f"{spec.name}: secret without env_var"
        # 5-field cron; Snowflake wraps it as USING CRON <expr> UTC.
        assert len(spec.schedule.split()) == 5, f"{spec.name}: {spec.schedule!r}"


def test_sample_is_never_scheduled() -> None:
    # It is the credential-free smoke test. A Task would give it a cost and a failure
    # mode for no benefit.
    assert load_registry().get("sample").schedule is None
    assert load_registry().get("sample").after is None


def test_nfl_app_to_postgres_is_an_after_task_with_twenty_tables() -> None:
    spec = load_registry().get("nfl_app_to_postgres")
    assert spec.source == "snowflake_app"
    assert spec.destination == "postgres"
    assert spec.dataset_name == "app_copy"
    assert spec.schedule is None
    assert spec.after == "NFL_PROD_DB.OPS.DBT_HARVEST_NFL"
    assert spec.external_access == "POSTGRES_APP_EAI"
    assert spec.secret == "DLT_DB.OPS.POSTGRES_APP_COPY"
    assert spec.env_var == "DESTINATION__POSTGRES__CREDENTIALS__PASSWORD"
    assert spec.write_disposition == "replace"
    assert spec.config["loader_file_format"] == "csv"
    assert spec.config["skip_unchanged"] is True
    assert len(spec.config["tables"]) == 20
    assert "app_game_slate" in spec.config["tables"]
    assert "app_explore_line_moves" in spec.config["tables"]


def test_obs_to_postgres_reads_dlt_db_ops() -> None:
    spec = load_registry().get("obs_to_postgres")
    assert spec.source == "snowflake_app"
    assert spec.destination == "postgres"
    assert spec.dataset_name == "observability"
    assert spec.schedule is None
    assert spec.after == "DLT_DB.OPS.OBS_REFRESH"
    assert spec.external_access == "POSTGRES_APP_EAI"
    assert spec.secret == "DLT_DB.OPS.POSTGRES_APP_COPY"
    assert spec.env_var == "DESTINATION__POSTGRES__CREDENTIALS__PASSWORD"
    # Deliberately NO spec-level write_disposition: run.py would pass it to
    # pipeline.run(), where it bluntly overrides the per-table modes below.
    assert spec.write_disposition is None
    assert spec.config["database"] == "DLT_DB"
    assert spec.config["schema"] == "OPS"

    def table_name(entry):
        return entry if isinstance(entry, str) else entry["name"]

    names = [table_name(t) for t in spec.config["tables"]]
    assert names == [
        "pipeline_runs",
        "task_runs",
        "log_lines",
        "metric_samples",
        "dbt_query_log",
        "dbt_query_operator_stats",
        "pipeline_registry",
        "dbt_builds",
        "dbt_runs",
        "dbt_runs_refresh_log",
        "headlines",
        "alert_state",
    ]
    # The history tables are incremental (the 2026-08-24 OOM), the small
    # tables full replace.
    modes = {
        table_name(t): (t.get("mode") if isinstance(t, dict) else "replace")
        for t in spec.config["tables"]
    }
    assert modes["pipeline_runs"] == "merge"
    assert modes["task_runs"] == "merge"
    assert modes["log_lines"] == "append"
    assert modes["metric_samples"] == "append"
    assert modes["dbt_query_log"] == "merge"
    assert modes["dbt_query_operator_stats"] == "append"
    assert modes["alert_state"] == "replace"
    # Stem NFL is telemetry only; the SELECT source is config.database.
    assert spec.database == "NFL"
    assert "dlt_events" not in names


def test_obs_resync_is_the_weekly_full_replace() -> None:
    # The incremental copy never deletes what Snowflake retention purges;
    # this scheduled twin replace-loads the same tables weekly to re-bound
    # Postgres. Spec-level write_disposition IS the mechanism: pipeline.run()
    # overrides every resource with it.
    spec = load_registry().get("obs_to_postgres_resync")
    assert spec.source == "snowflake_app"
    assert spec.schedule == "0 3 * * 0"
    assert spec.write_disposition == "replace"
    obs = load_registry().get("obs_to_postgres")

    def table_name(entry):
        return entry if isinstance(entry, str) else entry["name"]

    assert spec.config["tables"] == [table_name(t) for t in obs.config["tables"]]
    assert spec.config["database"] == "DLT_DB"
    assert spec.config["schema"] == "OPS"


# ---------------------------------------------------------------------------
# The season token: what a scheduled run substitutes before dlt sees the config
# ---------------------------------------------------------------------------


def test_every_season_scoped_resource_carries_the_token() -> None:
    """Without a season, a scheduled run is wrong in one of two ways.

    /standings and /advanced_stats return HTTP 400 outright. /games and /stats are
    worse: they silently return EVERY season the API holds and report a clean run.
    A Task passes no arguments, so the only place the year can come from is here.
    """
    registry = load_registry()

    def season_params(cfg) -> list:
        found = []

        def walk(node):
            if isinstance(node, dict):
                for key, value in node.items():
                    if key in ("season", "seasons[]"):
                        found.append(value)
                    walk(value)
            elif isinstance(node, list):
                for item in node:
                    walk(item)

        walk(cfg)
        return found

    expected = {
        "nfl_games": 1,  # once, in resource_defaults
        "nfl_stats": 1,  # once, in resource_defaults
        "nfl_standings": 1,  # the resource itself
        "nfl_plays": 3,  # the three parents that drive the fan-out
        "nfl_game_odds": 2,  # regular/post games parents
        "nfl_player_props": 2,  # regular/post games parents
        "nfl_odds_opening": 2,  # regular/post games parents drive both endpoints
        # NCAAF. No season_type parameter exists for this sport, so no resource is
        # triplicated and every pipeline needs exactly one token.
        "ncaaf_games": 1,  # the single games resource
        "ncaaf_stats": 1,  # once, in resource_defaults
        "ncaaf_season_stats": 1,  # once, in resource_defaults
        "ncaaf_standings": 1,  # the standings child; the conference parent is season-free
        "ncaaf_rankings": 1,  # bare season = latest published week, by design
    }
    for name, count in expected.items():
        values = season_params(registry.get(name).config)
        assert values == ["{current_season}"] * count, (
            f"{name}: expected {count} season token(s), got {values}"
        )

    # Nothing season-scoped may be left out of the dict above. Without this, adding a
    # pipeline that needs a season and forgetting to list it here passes silently,
    # which is the exact failure the dict is meant to catch.
    checked = set(expected) | {
        "nfl_reference",
        "nfl_injuries",
        "nfl_news",
        "ncaaf_reference",
        "sample",
        "nfl_weather_forecast",
        "nfl_weather_archive",
        "nfl_weather_hist_forecast",
        "nfl_app_to_postgres",
        "obs_to_postgres",
        "obs_to_postgres_resync",
        # nflverse keeps its own season clock (`seasons: current` in the entry asks
        # nflreadpy, never the registry token). See nflverse_source.py.
        "nfl_nflverse_stats",
        "nfl_nflverse_depth_charts",
        "nfl_nflverse_reference",
        "nfl_nflverse_backfill",
        # Sleeper reads season/week from /state/nfl on every run. See sleeper_source.py.
        "nfl_sleeper_players",
        "nfl_sleeper_market",
        "nfl_sleeper_backfill",
    }
    assert {s.name for s in registry.pipelines} == checked, (
        "a pipeline is neither asserted to carry a season token nor asserted to have "
        "none. Add it to `expected` or to the no-token test below."
    )


def test_pipelines_with_no_season_have_no_token() -> None:
    # teams, players and injuries are current state, not seasonal. A season filter on
    # them would not narrow anything; it would just be a param the API ignores.
    #
    # nfl_news is dated by its search window (tbs), not by season.
    for name in (
        "nfl_reference",
        "nfl_injuries",
        "nfl_news",
        "ncaaf_reference",
        "nfl_weather_forecast",
        "nfl_weather_archive",
        "nfl_weather_hist_forecast",
        "nfl_app_to_postgres",
        "obs_to_postgres",
        "obs_to_postgres_resync",
    ):
        assert "{current_season}" not in json.dumps(load_registry().get(name).config)


# ---------------------------------------------------------------------------
# NFL betting resources: history, fan-out, and pagination
# ---------------------------------------------------------------------------


def _resources(pipeline: str) -> dict[str, dict]:
    resources = load_registry().get(pipeline).config["resources"]
    return {resource["name"]: resource for resource in resources}


def test_live_nfl_betting_resources_preserve_line_movement() -> None:
    for pipeline, names, table in (
        ("nfl_game_odds", ("odds_regular", "odds_post"), "odds"),
        (
            "nfl_player_props",
            ("player_props_regular", "player_props_post"),
            "player_props",
        ),
    ):
        resources = _resources(pipeline)
        for name in names:
            resource = resources[name]
            assert resource["table_name"] == table
            assert resource["merge_key"] == "season_type"
            assert resource["write_disposition"] == {
                "disposition": "merge",
                "strategy": "scd2",
            }
            # SCD2 hashes row content; a primary key would deduplicate versions in
            # staging rather than being needed for identity.
            assert "primary_key" not in resource


def test_game_odds_fans_out_with_cursor_pagination() -> None:
    resources = _resources("nfl_game_odds")
    for season_type, suffix in ((2, "regular"), (3, "post")):
        parent = resources[f"odds_games_{suffix}_ref"]
        child = resources[f"odds_{suffix}"]

        assert parent["selected"] is False
        assert parent["endpoint"]["params"]["season_type"] == season_type
        assert parent["endpoint"]["params"]["seasons[]"] == "{current_season}"
        assert child["constants"]["season_type"] == season_type
        assert child["endpoint"]["params"]["game_ids[]"] == (
            f"{{resources.odds_games_{suffix}_ref.id}}"
        )
        assert child["endpoint"]["params"]["per_page"] == 100
        assert child["endpoint"]["paginator"] == {
            "type": "cursor",
            "cursor_path": "meta.next_cursor",
            "cursor_param": "cursor",
        }


def test_player_props_are_deliberately_unpaginated() -> None:
    resources = _resources("nfl_player_props")
    for suffix in ("regular", "post"):
        endpoint = resources[f"player_props_{suffix}"]["endpoint"]
        assert endpoint["path"] == "odds/player_props"
        assert "paginator" not in endpoint
        assert endpoint["params"]["game_id"] == (f"{{resources.props_games_{suffix}_ref.id}}")


def test_opening_markets_fan_out_and_merge_by_id() -> None:
    resources = _resources("nfl_odds_opening")

    for season_type, suffix in ((2, "regular"), (3, "post")):
        parent = resources[f"opening_games_{suffix}_ref"]
        odds = resources[f"odds_opening_{suffix}"]
        props = resources[f"player_props_opening_{suffix}"]

        assert parent["selected"] is False
        assert parent["endpoint"]["params"]["season_type"] == season_type
        assert parent["endpoint"]["params"]["seasons[]"] == "{current_season}"

        assert odds["primary_key"] == "id"
        assert odds["table_name"] == "odds_opening"
        assert odds["write_disposition"] == "merge"
        assert odds["constants"]["season_type"] == season_type
        assert odds["endpoint"]["params"] == {
            "per_page": 100,
            "game_ids[]": f"{{resources.opening_games_{suffix}_ref.id}}",
        }
        assert odds["endpoint"]["paginator"] == {
            "type": "cursor",
            "cursor_path": "meta.next_cursor",
            "cursor_param": "cursor",
        }

        assert props["primary_key"] == "id"
        assert props["table_name"] == "player_props_opening"
        assert props["write_disposition"] == "merge"
        assert props["constants"]["season_type"] == season_type
        assert "paginator" not in props["endpoint"]


# ---------------------------------------------------------------------------
# spec_from_row: table row -> validated PipelineSpec
# ---------------------------------------------------------------------------


def _base_row(**overrides) -> dict:
    row = {
        "name": "nfl_stats",
        "source": "rest_api",
        "schedule": "0 * * * *",
        "secret": "DLT_DB.OPS.NFL_API_KEY",
        "env_var": "SOURCES__NFL__API_KEY",
        "external_access": "NFL_API_EAI",
        "dataset_name": "RAW",
        "write_disposition": "merge",
        "pipeline_group": "batch_hourly",
        "config": {"credentials": "secret:x", "schema": "public"},
        "enabled": True,
    }
    row.update(overrides)
    return row


def test_spec_from_row_config_as_dict() -> None:
    spec = spec_from_row(_base_row())
    assert spec.name == "nfl_stats"
    assert spec.source == "rest_api"
    assert spec.config["schema"] == "public"
    # pipeline_group column maps onto the `group` field.
    assert spec.group == "batch_hourly"


def test_spec_from_row_config_as_json_string() -> None:
    row = _base_row(config=json.dumps({"credentials": "secret:x", "schema": "s"}))
    spec = spec_from_row(row)
    assert spec.config == {"credentials": "secret:x", "schema": "s"}


def test_spec_from_row_empty_config_string_becomes_error() -> None:
    # An empty VARIANT string parses to {} which fails validate() (config required).
    row = _base_row(config="")
    with pytest.raises(RegistryError, match="non-empty mapping"):
        spec_from_row(row)


def test_spec_from_row_missing_columns_fall_back_to_defaults() -> None:
    # Table has no destination/load_warehouse/compute_pool columns; defaults apply.
    row = {
        "name": "minimal",
        "source": "rest_api",
        "config": {"client": {"base_url": "https://api.example.com"}},
    }
    spec = spec_from_row(row)
    assert spec.destination == "snowflake"
    assert spec.load_warehouse == "DLT_WH"
    assert spec.compute_pool == "DLT_POOL"
    assert spec.dataset_name == "RAW"
    # No write_disposition column means no pipeline-level override.
    assert spec.write_disposition is None
    assert spec.schedule is None
    assert spec.group is None


def test_spec_from_row_reads_target_database_under_its_column_name() -> None:
    # DATABASE is a SQL keyword, so the column is target_database and spec_from_row
    # renames it, exactly as it already does for pipeline_group -> group.
    spec = spec_from_row(_base_row(target_database="NFL"))
    assert spec.database == "NFL"
    assert resolve_database(spec, "PROD") == "NFL_PROD_DB"


def test_spec_from_row_missing_target_database_falls_back_to_shared() -> None:
    # A table that predates the column returns nothing for it. Falling back to DLT
    # reproduces the pre-split behaviour rather than failing the load outright.
    assert spec_from_row(_base_row()).database == "DLT"
    assert spec_from_row(_base_row(target_database=None)).database == "DLT"


def test_spec_from_row_null_column_uses_default() -> None:
    # A NULL dataset_name falls back to the default, but a NULL write_disposition
    # must stay None: it means "no override", which is not the same as "unset".
    row = _base_row(dataset_name=None, write_disposition=None)
    spec = spec_from_row(row)
    assert spec.dataset_name == "RAW"
    assert spec.write_disposition is None


# ---------------------------------------------------------------------------
# write_disposition: VARIANT round trip and validation
# ---------------------------------------------------------------------------


def test_write_disposition_variant_arrives_as_json_string() -> None:
    # A VARIANT column comes back from the connector as JSON text, so a plain
    # string arrives with its quotes still attached.
    spec = spec_from_row(_base_row(write_disposition='"replace"'))
    assert spec.write_disposition == "replace"


def test_write_disposition_dict_form_accepted() -> None:
    row = _base_row(write_disposition=json.dumps({"disposition": "merge", "strategy": "scd2"}))
    spec = spec_from_row(row)
    assert spec.write_disposition == {"disposition": "merge", "strategy": "scd2"}


def test_write_disposition_dict_form_as_native_dict() -> None:
    # Already-parsed VARIANTs pass through untouched.
    spec = spec_from_row(_base_row(write_disposition={"disposition": "append"}))
    assert spec.write_disposition == {"disposition": "append"}


def test_write_disposition_bad_string_rejected() -> None:
    with pytest.raises(RegistryError, match="write_disposition must be"):
        spec_from_row(_base_row(write_disposition='"upsert"'))


def test_write_disposition_dict_without_disposition_rejected() -> None:
    with pytest.raises(RegistryError, match="needs a `disposition`"):
        spec_from_row(_base_row(write_disposition=json.dumps({"strategy": "scd2"})))


def test_write_disposition_wrong_type_rejected() -> None:
    with pytest.raises(RegistryError, match="must be a string, a mapping, or absent"):
        spec_from_row(_base_row(write_disposition=42))


def test_spec_from_row_invalid_source_rejected() -> None:
    with pytest.raises(RegistryError, match="not supported"):
        spec_from_row(_base_row(source="mongodb"))


# ---------------------------------------------------------------------------
# --param: parsing and merging into a resource's endpoint
#
# Pure functions on plain dicts, so these need no dlt and no network. They import
# from run.py, which does import dlt, hence the module-level skip below.
# ---------------------------------------------------------------------------

pytest.importorskip("dlt")

from pipelines.batch.run import _apply_params, _parse_params  # noqa: E402


def test_parse_params_single_pair() -> None:
    # None is the "no resource named" key; the CLI binds it to the selected resource.
    assert _parse_params(["season_type=3"]) == {None: {"season_type": "3"}}


def test_parse_params_repeated_key_accumulates() -> None:
    # An array parameter is one filter with several values. A plain dict would keep
    # only the last and silently narrow the backfill.
    assert _parse_params(["seasons[]=2023", "seasons[]=2022"]) == {
        None: {"seasons[]": ["2023", "2022"]}
    }


def test_parse_params_splits_on_first_equals_only() -> None:
    assert _parse_params(["filter=a=b"]) == {None: {"filter": "a=b"}}


def test_parse_params_qualified_form_names_its_target() -> None:
    # The parent-child case: the filter belongs on the resource that lists the games,
    # not on the one fetching plays for a game already chosen.
    assert _parse_params(["games_post_ref:seasons[]=2025"]) == {
        "games_post_ref": {"seasons[]": "2025"}
    }


def test_parse_params_mixes_qualified_and_plain() -> None:
    assert _parse_params(["games_ref:seasons[]=2025", "per_page=50"]) == {
        "games_ref": {"seasons[]": "2025"},
        None: {"per_page": "50"},
    }


def test_parse_params_colon_in_value_is_not_a_qualifier() -> None:
    # The resource split happens on the key side only, so a value may contain colons.
    assert _parse_params(["url=https://x.test/a"]) == {None: {"url": "https://x.test/a"}}


def test_parse_params_rejects_missing_equals() -> None:
    with pytest.raises(ValueError, match="must be KEY=VALUE"):
        _parse_params(["seasons"])


def test_parse_params_rejects_empty_key() -> None:
    with pytest.raises(ValueError, match="must be KEY=VALUE"):
        _parse_params(["=2023"])


def test_parse_params_rejects_empty_resource_or_param() -> None:
    with pytest.raises(ValueError, match="empty resource or parameter"):
        _parse_params([":seasons[]=2025"])
    with pytest.raises(ValueError, match="empty resource or parameter"):
        _parse_params(["games_ref:=2025"])


def _games_config() -> dict:
    return {
        "client": {"base_url": "https://api.example.com/"},
        "resource_defaults": {"endpoint": {"params": {"per_page": 100}}},
        "resources": [
            {"name": "games_post", "endpoint": {"path": "games", "params": {"season_type": 3}}},
            {"name": "games_pre", "endpoint": {"path": "games", "params": {"season_type": 1}}},
        ],
    }


def test_apply_params_merges_into_the_named_resource_only() -> None:
    config = _games_config()
    out = _apply_params(config, {"games_post": {"seasons[]": "2023"}})

    post = out["resources"][0]["endpoint"]["params"]
    pre = out["resources"][1]["endpoint"]["params"]
    # Added to the target, and the registry's own params on that endpoint survive.
    assert post == {"season_type": 3, "seasons[]": "2023"}
    # The sibling resource is untouched.
    assert pre == {"season_type": 1}


def test_apply_params_handles_several_targets_at_once() -> None:
    # The parent-child shape: filter the parent, adjust the child, in one run.
    out = _apply_params(
        _games_config(),
        {"games_post": {"seasons[]": "2025"}, "games_pre": {"per_page": "10"}},
    )
    assert out["resources"][0]["endpoint"]["params"]["seasons[]"] == "2025"
    assert out["resources"][1]["endpoint"]["params"]["per_page"] == "10"


def test_apply_params_overrides_an_existing_value() -> None:
    out = _apply_params(_games_config(), {"games_post": {"season_type": "1"}})
    assert out["resources"][0]["endpoint"]["params"]["season_type"] == "1"


def test_apply_params_does_not_mutate_the_original() -> None:
    # Registry files share nested structures through YAML anchors, so two pipelines can
    # hold the same dict object. Mutating in place would change the other one.
    config = _games_config()
    _apply_params(config, {"games_post": {"seasons[]": "2023"}})
    assert config["resources"][0]["endpoint"]["params"] == {"season_type": 3}


def test_apply_params_promotes_a_bare_string_endpoint() -> None:
    config = {"resources": [{"name": "teams", "endpoint": "teams"}]}
    out = _apply_params(config, {"teams": {"per_page": "100"}})
    assert out["resources"][0]["endpoint"] == {"path": "teams", "params": {"per_page": "100"}}


def test_apply_params_unknown_resource_rejected() -> None:
    # A typo in a qualified name must not pass silently, or the run proceeds unfiltered.
    with pytest.raises(ValueError, match="does not declare"):
        _apply_params(_games_config(), {"games_nope": {"season_type": "2"}})


# ---------------------------------------------------------------------------
# constants: stamping a value the API filters on but does not return
# ---------------------------------------------------------------------------

from pipelines.batch.run import _apply_constants, _constant_stamper  # noqa: E402


def test_constant_stamper_adds_fields_without_touching_the_row() -> None:
    row = {"id": 1}
    stamped = _constant_stamper({"season_type": 1})(row)
    assert stamped == {"id": 1, "season_type": 1}
    assert row == {"id": 1}, "the source row must not be mutated"


def test_constants_bind_per_resource_not_to_the_last_one() -> None:
    """The bug this whole helper exists to prevent.

    Written as inline lambdas in a loop, all three mappers would close over the same
    variable and stamp season_type 3. Nothing raises; the data is just wrong.
    """
    cfg = {
        "resources": [
            {"name": f"games_{n}", "constants": {"season_type": n}, "endpoint": {"path": "games"}}
            for n in (1, 2, 3)
        ]
    }
    _apply_constants(cfg)

    stamped = [entry["processing_steps"][0]["map"]({}) for entry in cfg["resources"]]
    assert [row["season_type"] for row in stamped] == [1, 2, 3]


def test_apply_constants_removes_the_key_dlt_would_reject() -> None:
    # dlt validates a resource against a TypedDict and rejects unknown fields, so the
    # key must be gone by the time the config is handed over.
    cfg = {"resources": [{"name": "games_pre", "constants": {"season_type": 1}}]}
    _apply_constants(cfg)
    assert "constants" not in cfg["resources"][0]


def test_apply_constants_preserves_existing_processing_steps() -> None:
    def existing(row):
        return row

    cfg = {
        "resources": [
            {
                "name": "games_pre",
                "constants": {"season_type": 1},
                "processing_steps": [{"map": existing}],
            }
        ]
    }
    _apply_constants(cfg)

    steps = cfg["resources"][0]["processing_steps"]
    assert len(steps) == 2 and steps[0]["map"] is existing


def test_apply_constants_is_a_no_op_without_the_key() -> None:
    cfg = {"resources": [{"name": "teams", "endpoint": {"path": "teams"}}]}
    _apply_constants(cfg)
    assert "processing_steps" not in cfg["resources"][0]


# ---------------------------------------------------------------------------
# registry_sync: MERGE / prune SQL builders
# ---------------------------------------------------------------------------


def test_merge_sql_and_row_params_align() -> None:
    from pipelines.batch.models import PipelineSpec  # noqa: PLC0415
    from pipelines.batch.registry_sync import MERGE_SQL, _row_params  # noqa: PLC0415

    spec = PipelineSpec(
        name="nfl_stats",
        source="rest_api",
        config={"credentials": "secret:x"},
        schedule="0 * * * *",
        secret="DLT_DB.OPS.NFL_API_KEY",
        env_var="SOURCES__NFL__API_KEY",
        external_access="NFL_API_EAI",
        group="batch_hourly",
        season_rollover_month=5,
    )
    params = _row_params(spec)

    # One %s per bind value, in the documented order. Update the count AND the
    # indices below when a column is added: this assertion exists to make that a
    # deliberate edit rather than a silently misaligned MERGE, where every value
    # after the new column would land in the wrong field.
    assert MERGE_SQL.count("%s") == len(params) == 12
    assert params[0] == "nfl_stats"
    assert params[3] == "DLT"  # target_database (stem, not full name)
    assert params[4] == "RAW"  # dataset_name
    assert params[6] == "batch_hourly"  # pipeline_group
    assert params[7] == 5  # season_rollover_month
    # The three scheduling bindings. Unsynced, these are None inside SPCS and every
    # scheduled Task dies in spec_from_row before doing any work, while the Task DDL
    # still looks correct because generate_tasks.py reads the YAML rather than the table.
    assert params[8] == "DLT_DB.OPS.NFL_API_KEY"  # secret
    assert params[9] == "SOURCES__NFL__API_KEY"  # env_var
    assert params[10] == "NFL_API_EAI"  # external_access
    assert json.loads(params[11]) == {"credentials": "secret:x"}  # config JSON
    # config bind is wrapped in PARSE_JSON so VARIANT typing is correct.
    assert "PARSE_JSON(%s)" in MERGE_SQL
    assert "MERGE INTO DLT_DB.OPS.PIPELINE_REGISTRY" in MERGE_SQL
    # enabled is only set on INSERT, never on UPDATE (preserves manual disables).
    assert "enabled" not in MERGE_SQL.split("WHEN MATCHED")[1].split("WHEN NOT MATCHED")[0]


def test_scheduled_spec_round_trips_through_the_registry_table() -> None:
    """A row the sync writes must rebuild into a spec that validate() accepts.

    THIS IS THE ASSERTION THAT WAS MISSING, and its absence cost a production outage.
    secret / env_var / external_access were declared in registries/*.yml and were
    correctly inlined into the generated Task DDL, so `make tasks-sql` looked right and
    every existing test passed. They were simply never columns on PIPELINE_REGISTRY.

    A container in SPCS does not read the YAML. It rebuilds its spec from the table, got
    None for all three, and raised RegistryError from spec_from_row before doing any
    work -- on every scheduled pipeline, of both sports, at every fire.

    Asserting on the sync alone would not have caught it, nor would asserting on the
    YAML. Only the round trip does, which is why this test walks the values out through
    the MERGE and back in through spec_from_row rather than checking either half.
    """
    from pipelines.batch.registry_store import _COLUMNS  # noqa: PLC0415
    from pipelines.batch.registry_sync import (  # noqa: PLC0415
        _merge_header,
        _row_params,
    )

    spec = PipelineSpec(
        name="nfl_stats",
        source="rest_api",
        config={"credentials": "secret:x"},
        schedule="0 10 * * *",
        secret="DLT_DB.OPS.NFL_API_KEY",
        env_var="SOURCES__NFL__API_KEY",
        external_access="NFL_API_EAI",
        group="batch_hourly",
        season_rollover_month=5,
    )

    params = _row_params(spec)
    # Take the column names from the MERGE's own SELECT aliases rather than repeating
    # them here, so this breaks if the header and the bind order ever drift apart.
    header = _merge_header([f"<{i}>" for i in range(len(params))])
    # Only the SELECT-list lines, which are the ones carrying a placeholder token. The
    # `MERGE INTO ... AS t` line also contains " AS " and is not a column.
    written = [
        line.split(" AS ")[1].rstrip(",")
        for line in header.splitlines()
        if " AS " in line and line.strip().startswith("<")
    ]
    assert len(written) == len(params), "MERGE header and bind values are misaligned"
    row_written = dict(zip(written, params, strict=True))

    # The store reads a fixed column list. `enabled` is the one column it selects but the
    # MERGE only ever sets on INSERT, so it is not expected in row_written.
    unwritten = [c for c in _COLUMNS if c not in row_written and c != "enabled"]
    assert not unwritten, f"registry_store selects columns the sync never writes: {unwritten}"

    # Simulate the actual SELECT: only _COLUMNS survives the trip back. A field that the
    # sync writes but the store forgets to select disappears exactly here, which is the
    # bug this test exists for.
    row_read = {k: v for k, v in row_written.items() if k in _COLUMNS}
    rebuilt = spec_from_row(row_read)  # raises RegistryError if a binding did not survive

    assert rebuilt.secret == spec.secret
    assert rebuilt.env_var == spec.env_var
    assert rebuilt.external_access == spec.external_access
    assert rebuilt.schedule == spec.schedule
    # Not merely non-None: an unselected column silently becomes the dataclass default of
    # 8, so this non-default value proves the column survived the round trip.
    assert rebuilt.season_rollover_month == 5
    assert rebuilt.config == spec.config


def test_prune_sql_placeholder_count() -> None:
    from pipelines.batch.registry_sync import _prune_sql  # noqa: PLC0415

    sql, params = _prune_sql(["a", "b", "c"])
    assert sql.count("%s") == 3
    assert params == ("a", "b", "c")
    assert "DELETE FROM DLT_DB.OPS.PIPELINE_REGISTRY" in sql
    assert "NOT IN" in sql


def test_emit_sql_is_self_contained() -> None:
    from pipelines.batch.models import PipelineSpec  # noqa: PLC0415
    from pipelines.batch.registry_sync import emit_sql  # noqa: PLC0415

    specs = [
        PipelineSpec(
            name="nfl_stats",
            source="rest_api",
            config={"credentials": "secret:x"},
            schedule="0 * * * *",
            secret="DLT_DB.OPS.NFL_API_KEY",
            env_var="SOURCES__NFL__API_KEY",
            external_access="NFL_API_EAI",
            group="batch_hourly",
        ),
        PipelineSpec(
            name="gh_issues",
            source="rest_api",
            config={"client": {"base_url": "https://api.example.com"}},
        ),
    ]
    out = emit_sql(specs, prune=True)

    # No bind placeholders leak into the emitted script.
    assert "%s" not in out
    # Both pipelines produce a MERGE with inlined literals + dollar-quoted config.
    assert out.count("MERGE INTO DLT_DB.OPS.PIPELINE_REGISTRY") == 2
    assert "'nfl_stats' AS name" in out
    assert "PARSE_JSON($$" in out
    # Missing group renders as NULL, not the string 'None'.
    assert "NULL AS pipeline_group" in out
    assert "'None'" not in out
    # Statements are terminated; prune DELETE is included and scoped to YAML names.
    assert out.count(";") == 3  # 2 MERGE + 1 DELETE
    assert "DELETE FROM DLT_DB.OPS.PIPELINE_REGISTRY WHERE name NOT IN (" in out
    assert "'nfl_stats'" in out and "'gh_issues'" in out


# ---------------------------------------------------------------------------
# Token substitution itself (run.py, so dlt is required)
# ---------------------------------------------------------------------------


def test_resolve_tokens_replaces_only_exact_matches() -> None:
    pytest.importorskip("dlt")
    from pipelines.batch.run import _resolve_tokens  # noqa: PLC0415

    cfg = {
        "resource_defaults": {"endpoint": {"params": {"seasons[]": "{current_season}"}}},
        "resources": [
            {"endpoint": {"params": {"season": "{current_season}", "season_type": 2}}},
            # A placeholder dlt owns, not us. Substituting inside it would break the
            # parent-child fan-out, which is why matching is exact rather than partial.
            {"endpoint": {"params": {"game_id": "{resources.games_pre_ref.id}"}}},
        ],
        "note": "text mentioning {current_season} in prose",
    }
    out = _resolve_tokens(cfg, {"{current_season}": 2026})

    assert out["resource_defaults"]["endpoint"]["params"]["seasons[]"] == 2026
    assert out["resources"][0]["endpoint"]["params"]["season"] == 2026
    assert out["resources"][0]["endpoint"]["params"]["season_type"] == 2
    assert out["resources"][1]["endpoint"]["params"]["game_id"] == ("{resources.games_pre_ref.id}")
    assert out["note"] == "text mentioning {current_season} in prose"


def test_resolve_tokens_does_not_mutate_the_registry() -> None:
    # The spec config is shared: nfl_games and nfl_stats both alias the same client
    # block, and a second pipeline in the same process must not see a resolved year.
    pytest.importorskip("dlt")
    from pipelines.batch.run import _resolve_tokens  # noqa: PLC0415

    spec = load_registry().get("nfl_standings")
    before = json.dumps(spec.config, sort_keys=True)
    _resolve_tokens(spec.config, {"{current_season}": 2026})
    assert json.dumps(spec.config, sort_keys=True) == before
