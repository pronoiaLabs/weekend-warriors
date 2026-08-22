"""What a Snowflake Task emits, and what the registry must carry for it to work.

WHY THIS EXISTS
    A Task is the one execution path with nobody watching. Every other run prints its
    errors to a terminal someone is looking at; a Task fires at 09:00 UTC and reports
    itself only in TASK_HISTORY. So the failures that matter here are the ones that
    cannot be seen at generation time:

      * a missing EXTERNAL_ACCESS_INTEGRATIONS, which leaves the container with no
        network at all and every request timing out
      * that clause placed after the FROM, which is a SQL compilation error, because
        EXECUTE JOB SERVICE fixes its clause order
      * an unqualified object name, which lands the Task wherever the applying
        session happened to point
      * a missing secret binding, which reaches dlt.secrets and raises KeyError
      * an unsubstituted placeholder, which is valid YAML and therefore silently
        wrong: the container would look for a secret literally named "{{ secret }}"
      * a fixed job-service NAME, which works on the first fire and fails on every
        one after, because a completed job persists for 30 days and there is no
        OR REPLACE

    All four are cheap to assert on the emitted text and expensive to find any other
    way. `generate_tasks` imports only models, so this needs no dlt and no connection.
"""
from __future__ import annotations

import sys
from pathlib import Path

import pytest

_ROOT = Path(__file__).parent.parent.resolve()
if str(_ROOT) not in sys.path:
    sys.path.insert(0, str(_ROOT))

pytest.importorskip("yaml")

from deploy.tasks.generate_tasks import task_sql  # noqa: E402
from pipelines.batch.models import load_registry, resolve_database  # noqa: E402


def _scheduled():
    return [s for s in load_registry().pipelines if s.schedule]


def _sql(name: str) -> str:
    return task_sql(load_registry().get(name))


# ---------------------------------------------------------------------------
# Emission
# ---------------------------------------------------------------------------


def test_unscheduled_pipeline_emits_no_task() -> None:
    # Omission is how "do not schedule this" is expressed. `sample` must never become
    # a production Task, and a comment rather than an error is what lets one registry
    # hold both scheduled and manual pipelines.
    out = _sql("sample")
    assert "CREATE OR ALTER TASK" not in out
    assert out.startswith("-- skipped")


@pytest.mark.parametrize("spec", _scheduled(), ids=lambda s: s.name)
def test_every_scheduled_task_is_runnable(spec) -> None:
    sql = task_sql(spec)

    # Qualified, because the grant is on a specific schema and CI sets no schema.
    assert f"CREATE OR ALTER TASK DLT_DB.OPS.dlt_task_{spec.name}" in sql

    # NO fixed job name: a completed job service persists for 30 days, so a fixed
    # name succeeds once and then collides forever. Snowflake generates a unique one
    # when NAME is omitted; COMMENT keeps the job identifiable in SHOW SERVICES.
    assert "NAME =" not in sql, "a fixed job-service name collides on the second run"
    assert f"COMMENT = '{spec.name}'" in sql

    # Egress. Without it the container cannot reach the source API at all.
    assert f"EXTERNAL_ACCESS_INTEGRATIONS = ({spec.external_access})" in sql

    # The spec is inlined, not staged, so everything the container needs is visible
    # in the DDL itself.
    assert "FROM SPECIFICATION $$" in sql
    assert "SPECIFICATION_TEMPLATE_FILE" not in sql, "should not depend on the stage"

    # Production, always, and never a dev database. A Task IS the production
    # schedule, so a generator able to emit a dev target would put a scheduled write
    # into somebody's sandbox one typo away.
    #
    # Derived from the spec rather than hardcoded: this is parametrized over EVERY
    # scheduled pipeline, and the registry now spans more than one sport. A literal
    # "NFL_PROD_DB" here asserted that every league loads into the NFL's database.
    assert resolve_database(spec, "PROD") in sql
    assert "_DEV_DB" not in sql

    assert f"SCHEDULE = 'USING CRON {spec.schedule} UTC'" in sql

    # The cost tag rides in the task block because CREATE OR ALTER TASK cannot carry
    # one inline; a new pipeline's Task must be tagged on its very first apply.
    assert (
        f"ALTER TASK DLT_DB.OPS.dlt_task_{spec.name} "
        "SET TAG DLT_DB.OPS.COST_CENTER = 'ingestion';"
    ) in sql


@pytest.mark.parametrize("spec", _scheduled(), ids=lambda s: s.name)
def test_inlined_spec_is_valid_yaml_with_the_right_bindings(spec) -> None:
    """The inlined spec has to survive $$-quoting as parseable YAML.

    Whitespace matters here in a way it did not when the spec lived on a stage: it is
    interpolated into a SQL string, and a broken indent produces a spec Snowflake
    rejects at Task run time, which is the worst place to find out.
    """
    yaml = pytest.importorskip("yaml")

    body = task_sql(spec).split("FROM SPECIFICATION $$", 1)[1].rsplit("$$;", 1)[0]
    container = yaml.safe_load(body)["spec"]["containers"][0]

    assert container["args"] == [spec.name]
    assert container["env"]["DESTINATION__SNOWFLAKE__CREDENTIALS__DATABASE"] == (
        resolve_database(spec, "PROD")
    )
    # The control plane is one database for the account and must not follow the
    # per-source destination.
    assert container["env"]["SNOWFLAKE_DATABASE"] == "DLT_DB"

    if spec.secret:
        bound = container["secrets"][0]
        assert bound["snowflakeSecret"] == spec.secret
        assert bound["envVarName"] == spec.env_var
    else:
        assert "secrets" not in container


def test_unsubstituted_placeholder_is_rejected() -> None:
    """A leftover placeholder is valid YAML, so nothing downstream would catch it."""
    from dataclasses import replace as dc_replace  # noqa: PLC0415

    from deploy.tasks.generate_tasks import (  # noqa: PLC0415
        SPEC_TEMPLATE_PATH,
        render_spec,
    )

    spec = dc_replace(load_registry().get("nfl_reference"), secret=None)
    with pytest.raises(Exception) as exc:
        render_spec(spec, "NFL_PROD_DB", template=SPEC_TEMPLATE_PATH.read_text())
    assert "secret" in str(exc.value)


@pytest.mark.parametrize("spec", _scheduled(), ids=lambda s: s.name)
def test_external_access_precedes_from(spec) -> None:
    """Clause order in EXECUTE JOB SERVICE is fixed, and getting it wrong is fatal.

    IN COMPUTE POOL -> NAME -> [EXTERNAL_ACCESS_INTEGRATIONS] -> FROM -> USING.
    Placing the integration after SPECIFICATION_TEMPLATE_FILE compiles to
    `syntax error ... unexpected 'EXTERNAL_ACCESS_INTEGRATIONS'`, and only for runs
    that pass one, so a source needing no egress hides the mistake entirely.
    """
    sql = task_sql(spec)
    assert sql.index("EXTERNAL_ACCESS_INTEGRATIONS") < sql.index("FROM SPECIFICATION")


def test_tasks_are_emitted_suspended() -> None:
    # CREATE OR ALTER TASK leaves a task suspended, and the resume is a commented
    # suggestion rather than a statement. Generating a schedule and starting one are
    # different decisions. The SET TAG ALTER is the one uncommented ALTER allowed in
    # the block; nothing that RESUMES may run from tasks.sql.
    sql = _sql("nfl_reference")
    assert "-- ALTER TASK DLT_DB.OPS.dlt_task_nfl_reference RESUME" in sql
    assert not any(
        line.startswith("ALTER TASK") and "RESUME" in line for line in sql.splitlines()
    ), "resume must stay commented out"


def test_suspend_and_resume_cover_the_same_pipelines_as_tasks() -> None:
    """The three outputs must agree about which pipelines are Tasks.

    They are applied as one sequence, suspend -> apply -> resume, so a pipeline present
    in one and missing from another leaves the fleet half-stopped or half-applied. All
    three gate on the same `spec.schedule`, and this asserts they still do.
    """
    from deploy.tasks.generate_tasks import resume_sql, suspend_sql  # noqa: PLC0415

    scheduled = [s for s in load_registry().pipelines if s.schedule]
    assert scheduled, "registry declares no scheduled pipelines"

    for spec in scheduled:
        assert f"dlt_task_{spec.name} SUSPEND" in suspend_sql(spec)
        assert f"dlt_task_{spec.name} RESUME" in resume_sql(spec)
        assert f"dlt_task_{spec.name}" in task_sql(spec)

    # `sample` has no schedule and must appear in none of them.
    unscheduled = [s for s in load_registry().pipelines if not s.schedule]
    for spec in unscheduled:
        assert "ALTER TASK" not in suspend_sql(spec)
        assert "ALTER TASK" not in resume_sql(spec)


def test_suspend_tolerates_a_task_that_does_not_exist_yet() -> None:
    """`IF EXISTS` on suspend, and deliberately NOT on resume.

    Suspend runs before tasks.sql, when a first deploy or a partially built fleet means
    a Task legitimately may not exist; without IF EXISTS the pass aborts on the first
    missing name and leaves the rest started, which is the exact problem it prevents.

    Resume runs after tasks.sql created them, so a missing Task there means the apply
    failed partway and the error is the only thing that would say so.
    """
    from deploy.tasks.generate_tasks import resume_sql, suspend_sql  # noqa: PLC0415

    spec = next(s for s in load_registry().pipelines if s.schedule)
    assert "ALTER TASK IF EXISTS" in suspend_sql(spec)
    assert "IF EXISTS" not in resume_sql(spec)


def test_suspend_and_resume_are_mutually_exclusive() -> None:
    """Asking for both selects neither coherently, so argparse must reject the pair."""
    from deploy.tasks.generate_tasks import main  # noqa: PLC0415

    with pytest.raises(SystemExit):
        main(["--suspend", "--resume"])


def test_generator_covers_every_scheduled_pipeline() -> None:
    from deploy.tasks.generate_tasks import main  # noqa: PLC0415

    assert main() == 0  # prints to stdout; exercised for import and runtime errors

    # Counted per source rather than as one total. A single number has to be edited
    # every time any league gains or loses a pipeline, which makes it a chore that gets
    # updated without being read, and it cannot tell "WNBA arrived" from "an NFL
    # pipeline silently lost its schedule".
    scheduled = {s.name for s in _scheduled()}
    by_source: dict[str, set[str]] = {}
    for name in scheduled:
        by_source.setdefault(name.split("_", 1)[0], set()).add(name)

    assert by_source["nfl"] == {
        "nfl_reference", "nfl_games", "nfl_stats", "nfl_plays",
        "nfl_standings", "nfl_advanced_stats", "nfl_injuries",
        "nfl_game_odds", "nfl_player_props", "nfl_odds_opening",
        "nfl_news",
        "nfl_weather_forecast",
    }
    # WNBA is PAUSED (2026-08-12): schedules commented out in wnba-registry.yml,
    # account tasks suspended. The pipelines stay registered and hand-runnable;
    # they must simply emit no Task. Reviving WNBA means restoring the ten-name
    # set assertion here.
    assert "wnba" not in by_source
    assert by_source["ncaaf"] == {
        "ncaaf_reference", "ncaaf_games", "ncaaf_stats",
        "ncaaf_season_stats", "ncaaf_standings", "ncaaf_rankings",
    }

    # `sample` is the guard on the whole mechanism: it exists precisely to be the
    # pipeline that is runnable by hand and never becomes a Task.
    assert "sample" not in scheduled
