"""Generate one Snowflake Task per pipeline from pipelines/batch/registries/.

Each Task fires on the pipeline's cron schedule and launches a run-to-completion
SPCS job (EXECUTE JOB SERVICE) on the shared compute pool. The job spec is read from
deploy/spcs/dlt_job.tmpl.yaml, rendered HERE, and inlined into the Task. See section 1
for why it is not staged and rendered by Snowflake, which is the more obvious design
and the one this used first.

Adding a pipeline still needs no image rebuild: an INSERT (registry_sync) plus the
Task this script emits. Changing the image or the container env now means re-running
`make tasks-apply`, because the spec lives in the Task rather than on a stage.

CONTENTS
    1. Spec template ........ SPEC_TEMPLATE_PATH, _PLACEHOLDER
    2. Emission ............. render_spec, task_sql, resume_sql, main

USAGE
    python -m deploy.tasks.generate_tasks            # print CREATE TASK SQL to stdout
    python -m deploy.tasks.generate_tasks --resume   # print ALTER TASK ... RESUME
    make tasks-sql                                   # -> build/tasks.sql, review it
    make tasks-apply                                 # applies as DLT_LOADER_ROLE

    Run the emitted SQL as DLT_LOADER_ROLE, not as your default role: a Task runs with
    its OWNER's privileges, so applying as SYSADMIN gives every scheduled load far
    more than it needs, and changing it later takes a GRANT OWNERSHIP per Task.

IT EMITS SQL RATHER THAN APPLYING IT
    Nothing here touches Snowflake. Task DDL is reviewable, diffable and re-runnable
    only if it exists as text first, and a generator that also executed would make every
    dry run a production change.

    For the same reason Tasks are created SUSPENDED. Resuming is a deliberate act,
    because generating a schedule and starting a schedule are different decisions.

    That default is right for a human at a terminal and wrong for CI, which re-applies
    on every registry change and would stop the schedule each time -- CREATE OR ALTER
    resets a Task to suspended. Hence `--resume`, a separate output CI applies straight
    after tasks.sql. See resume_sql.

SCHEDULE IS WHAT MAKES A PIPELINE A TASK
    A registry entry with no `schedule` is skipped with a comment rather than an error.
    That is how `sample` stays runnable by hand without ever becoming a production Task,
    and it means "not scheduled" is expressed by omission rather than by a flag.

    Note this reads only `spec.schedule`. `group` plays no part here; it is a selection
    convenience for the runner.

NO EXECUTION DEPENDENCIES
    This imports pipelines.batch.models and nothing else from the repo, because CI runs
    it where neither dlt nor the Snowflake connector is installed. That constraint is
    why models.py is kept import-free.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

# Make the repo root importable so `pipelines` resolves when run as a module or script.
sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from pipelines.batch.models import (  # noqa: E402
    PipelineSpec,
    RegistryError,
    load_registry,
    resolve_database,
)

# ---------------------------------------------------------------------------
# 1. Spec template
#
# The spec is rendered HERE and inlined into each Task, rather than staged and
# rendered by Snowflake.
#
# WHY, BECAUSE THE OBVIOUS DESIGN IS THE OTHER ONE
#     Staging the template and letting `SPECIFICATION_TEMPLATE_FILE = ... USING (...)`
#     render it server-side is tidier on paper: one file, re-uploadable without
#     regenerating any SQL. That is what this did first, and every Task failed two
#     seconds after firing with:
#
#         Unable to render service spec from given template: SQL compilation error:
#         Object 'snowflake.snowpark.pypi_shared_repository' does not exist or not
#         authorized.
#
#     Nothing in the spec references PyPI. Snowflake's renderer resolves its own
#     dependency through that repository, and the Task's role could not reach it.
#     Granting SNOWFLAKE.PYPI_REPOSITORY_USER did not help; it was already granted to
#     PUBLIC. The same template renders fine when submitted interactively by
#     DLT_DEV_ROLE, so it is specific to the Task path.
#
#     Rendering locally removes the whole class of problem: there is no server-side
#     render to fail, no dependency on an object we do not control, and the emitted
#     SQL states exactly what will run instead of pointing at a file on a stage.
#
#     The cost is real and worth naming: changing the image or the container env now
#     means re-running `make tasks-apply`, not re-uploading one file. That is one
#     command, and the Tasks are `CREATE OR ALTER`, so it is idempotent.
#
# SUBSTITUTION IS A REGEX, NOT JINJA, AND THAT IS SAFE HERE
#     This module must not grow dependencies: CI runs it with pyyaml alone, no dlt and
#     no connector. A regex over `{{ name }}` is identical to Jinja for a template
#     containing nothing but simple placeholders, and tests/test_spec_templates.py
#     asserts the required-variable set EXACTLY, so no loop or conditional can appear
#     without that test failing first.
# ---------------------------------------------------------------------------

# The spec template, read from disk at generation time. Still the single definition of
# the container: one file, still rendered, just not by Snowflake.
SPEC_TEMPLATE_PATH = (
    Path(__file__).resolve().parents[1] / "spcs" / "dlt_job.tmpl.yaml"
)

_PLACEHOLDER = re.compile(r"\{\{\s*(\w+)\s*\}\}")

# Where the emitted objects live. Both are in the control plane rather than in a data
# database, because a Task that loads NFL and a Task that loads NBA are the same kind
# of thing and belong together. They match the grants in sql/base/02_control_plane.sql:
# CREATE TASK ON SCHEMA DLT_DB.OPS and CREATE SERVICE ON SCHEMA DLT_DB.DEPLOY.
TASKS_SCHEMA = "DLT_DB.OPS"
JOBS_SCHEMA = "DLT_DB.DEPLOY"


# ---------------------------------------------------------------------------
# 2. Emission
# ---------------------------------------------------------------------------


def render_spec(spec: PipelineSpec, database: str, template: str | None = None) -> str:
    """Substitute a pipeline's values into the job spec template.

    Raises on any placeholder we cannot fill. A missing one would otherwise render as
    the literal text `{{ secret }}` inside a YAML file Snowflake accepts, and the
    container would fail much later looking for a secret by that name.
    """
    text = SPEC_TEMPLATE_PATH.read_text() if template is None else template
    values = {
        "pipeline": spec.name,
        "database": database,
        "secret": spec.secret or "",
        "env_var": spec.env_var or "",
    }

    missing: list[str] = []

    def replace(match: "re.Match[str]") -> str:
        key = match.group(1)
        if not values.get(key):
            missing.append(key)
            return match.group(0)
        return values[key]

    rendered = _PLACEHOLDER.sub(replace, text)
    if missing:
        raise RegistryError(
            f"pipeline '{spec.name}': job spec needs {', '.join(sorted(set(missing)))}, "
            "which the registry entry does not provide"
        )

    # Drop whole-line comments. They document the template for whoever edits it; seven
    # Tasks each carrying 60 lines of prose makes the emitted SQL unreadable, and the
    # point of inlining is that you can read what will run. Only lines that are
    # ENTIRELY a comment go: an inline `key: value  # note` would take its value with
    # it, and YAML has no way to tell us we did that.
    body = "\n".join(
        line for line in rendered.splitlines() if not line.lstrip().startswith("#")
    )
    return body.strip() + "\n"


def task_sql(spec: PipelineSpec) -> str:
    if not spec.schedule:
        return f"-- skipped '{spec.name}': no schedule in registry\n"

    # Qualified, because the grant is CREATE TASK ON SCHEMA DLT_DB.OPS and nothing
    # guarantees the applying session has that as its current schema. CI sets
    # SNOWFLAKE_DATABASE and no SNOWFLAKE_SCHEMA at all, so an unqualified name lands
    # wherever it happens to.
    task_name = f"{TASKS_SCHEMA}.dlt_task_{spec.name}"

    # Always PROD here. A Task IS the production schedule; there is no dev Task, and a
    # generator that could emit a dev target would make that an accident away.
    database = resolve_database(spec, "PROD")

    # NO `NAME =`, DELIBERATELY, AND THIS IS THE SUBTLE ONE.
    #
    # A completed job service is not cleaned up: Snowflake keeps it for 30 days so
    # its logs and metadata stay readable. So a fixed name works exactly once. The
    # second fire of a daily Task failed with:
    #
    #     Object 'DLT_DB.DEPLOY.DLT_JOB_NFL_REFERENCE' already exists.
    #
    # which would have looked healthy on the first morning and broken every morning
    # after. There is no OR REPLACE on EXECUTE JOB SERVICE.
    #
    # Omitting NAME makes Snowflake generate JOB_<query_uuid>, unique per run. The dev
    # path solves the same problem by dropping the service first (Makefile run-spcs),
    # which is fine interactively but would destroy the previous run's logs every
    # night. Here the opposite is wanted: 30 days of per-run history.
    #
    # COMMENT carries the pipeline name so an auto-named job is still identifiable:
    #     SHOW SERVICES IN SCHEMA DLT_DB.DEPLOY;   -- the `comment` column
    #
    # Clause order in EXECUTE JOB SERVICE is fixed:
    #   IN COMPUTE POOL -> [NAME|ASYNC|QUERY_WAREHOUSE|COMMENT]
    #   -> [EXTERNAL_ACCESS_INTEGRATIONS] -> FROM
    # EXTERNAL_ACCESS_INTEGRATIONS after the template file is a SQL compilation error,
    # not a warning. Without it the container has no egress at all and every request
    # to the source API times out.
    eai = (
        f"\n    EXTERNAL_ACCESS_INTEGRATIONS = ({spec.external_access})"
        if spec.external_access
        else ""
    )

    # Rendered here, inlined below. $$-quoting preserves the YAML byte for byte, which
    # matters because YAML is whitespace sensitive and the spec is indented.
    rendered = render_spec(spec, database)

    return f"""\
CREATE OR ALTER TASK {task_name}
  WAREHOUSE = {spec.load_warehouse}
  SCHEDULE = 'USING CRON {spec.schedule} UTC'
AS
  EXECUTE JOB SERVICE
    IN COMPUTE POOL {spec.compute_pool}
    COMMENT = '{spec.name}'{eai}
    FROM SPECIFICATION $$
{rendered}$$;

-- ALTER TASK {task_name} RESUME;   -- uncomment to start scheduling
"""


def resume_sql(spec: PipelineSpec) -> str:
    """Emit `ALTER TASK ... RESUME` for one pipeline.

    WHY THIS EXISTS AS A SEPARATE OUTPUT RATHER THAN A LINE IN task_sql.
    `CREATE OR ALTER TASK` RESETS A TASK TO SUSPENDED. Applying tasks.sql over a
    running schedule therefore stops it, silently: the DDL succeeds, nothing errors,
    and the next cron fire simply never happens. That is not hypothetical -- all seven
    Tasks were found suspended after a re-apply, hours after they were resumed.

    Interactively that is the right default (see IT EMITS SQL RATHER THAN APPLYING IT
    above: generating a schedule and starting one are different decisions). But CI
    re-applies tasks.sql on every registry change, so for CI the default is a trap,
    and the fix is a second file it applies immediately afterwards.

    Same `spec.schedule` test as task_sql, so the two outputs cannot disagree about
    which pipelines are Tasks.
    """
    if not spec.schedule:
        return f"-- skipped '{spec.name}': no schedule in registry\n"
    return f"ALTER TASK {TASKS_SCHEMA}.dlt_task_{spec.name} RESUME;\n"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="generate_tasks",
        description="Emit Snowflake Task DDL from pipelines/batch/registries/.",
    )
    parser.add_argument(
        "--resume",
        action="store_true",
        help="emit ALTER TASK ... RESUME instead of the CREATE OR ALTER TASK DDL. "
        "Apply AFTER tasks.sql: CREATE OR ALTER leaves every Task suspended.",
    )
    args = parser.parse_args(argv)

    registry = load_registry()
    if args.resume:
        print("-- Generated from pipelines/batch/registries/. Apply AFTER tasks.sql.\n")
        for spec in registry.pipelines:
            print(resume_sql(spec), end="")
        return 0

    print("-- Generated from pipelines/batch/registries/. One Task per scheduled pipeline.\n")
    for spec in registry.pipelines:
        print(task_sql(spec))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
