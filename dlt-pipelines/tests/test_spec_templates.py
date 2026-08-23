"""Parse the SPCS job spec templates with the engine Snowflake actually renders them with.

WHY THIS EXISTS
    A bad placeholder in deploy/spcs/*.tmpl.yaml costs a full round trip to find:
    upload the template, submit a job, wait for the pool, read the error. Two separate
    bugs shipped that way, and both were invisible to review:

      1. A comment explaining the templating syntax contained a literal placeholder
         example. Snowflake substitutes over the raw file, so it became a REQUIRED
         variable and every render failed for want of an argument nobody meant to pass.
      2. Another comment wrote an ellipsis inside braces as documentation. Jinja tried
         to evaluate it and died with `unexpected '.'`.

    Neither is a YAML problem, so no YAML linter sees them. Both are caught here in
    milliseconds by asking Jinja what the file actually requires.

WHAT IS ASSERTED
    The required-variable set, exactly. Not a subset: an unexpected variable is the
    signature of a brace that escaped into prose, and a missing one means a caller has
    stopped supplying something the spec still needs. Adding a variable should be a
    deliberate edit here, not a surprise in a container.

    Then that the rendered result is valid YAML, and that `args` survives as the exact
    argv that went in, brackets and all.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

_ROOT = Path(__file__).parent.parent.resolve()
if str(_ROOT) not in sys.path:
    sys.path.insert(0, str(_ROOT))

jinja2 = pytest.importorskip("jinja2")
# jinja2.meta is not imported by the package root, so `jinja2.meta` alone is an
# AttributeError. Import the submodule explicitly.
jinja2_meta = pytest.importorskip("jinja2.meta")
yaml = pytest.importorskip("yaml")

SPECS = _ROOT / "deploy" / "spcs"

# Every variable each template may legitimately require, and nothing else.
#
# The prod template takes `pipeline` rather than `args`, and that is deliberate: a
# scheduled Task has no command line to forward, and it does not need one. The registry
# declares its season as a {current_season} token that run.py resolves at run time, so a
# bare `run <pipeline>` already loads the right season.
EXPECTED_VARIABLES: dict[str, set[str]] = {
    "dlt_dev_job.tmpl.yaml": {"args", "database", "dataset", "secret", "env_var"},
    "dlt_dev_job_nosecret.tmpl.yaml": {"args", "database", "dataset"},
    "dlt_job.tmpl.yaml": {"pipeline", "database", "secret", "env_var"},
    "dlt_job_nosecret.tmpl.yaml": {"pipeline", "database"},
    "dlt_job_postgres.tmpl.yaml": {
        "pipeline",
        "database",
        "dataset",
        "app_database",
        "secret",
        "env_var",
    },
}

# A deliberately awkward argv: brackets the shell would glob, an `=` a naive split
# would break on, and a colon-qualified parameter name.
ARGV = ["nfl_plays", "--resource", "plays_regular", "--param", "games_regular_ref:seasons[]=2023"]

SUBSTITUTIONS = {
    "args": json.dumps(ARGV),
    "pipeline": "nfl_plays",
    "database": "NFL_DEV_DB",
    "dataset": "DEV_JSMITH",
    "app_database": "DLT_DB",
    "secret": "DLT_DB.OPS.NFL_API_KEY",
    "env_var": "SOURCES__NFL__API_KEY",
}


def _env() -> "jinja2.Environment":
    # StrictUndefined so a variable the template needs but we did not supply raises
    # rather than rendering as an empty string, which is how a blank database would
    # otherwise slip through into a job spec.
    return jinja2.Environment(undefined=jinja2.StrictUndefined)


def _required(template_text: str) -> set[str]:
    return jinja2_meta.find_undeclared_variables(_env().parse(template_text))


@pytest.mark.parametrize("filename", sorted(EXPECTED_VARIABLES))
def test_template_requires_exactly_the_expected_variables(filename: str) -> None:
    text = (SPECS / filename).read_text()
    assert _required(text) == EXPECTED_VARIABLES[filename], (
        f"{filename}: an unexpected variable usually means a placeholder was written "
        f"in braces inside a comment, which Snowflake substitutes over anyway"
    )


@pytest.mark.parametrize("filename", sorted(EXPECTED_VARIABLES))
def test_template_parses_as_jinja(filename: str) -> None:
    # Catches the ellipsis-in-a-comment class of bug: syntactically invalid Jinja
    # anywhere in the file, including prose.
    _env().parse((SPECS / filename).read_text())


# The five SPCS platform metric groups. Enabled everywhere on purpose: collecting is
# cheap, and adding a group later means re-applying every Task in the fleet.
EXPECTED_METRIC_GROUPS = {"system", "system_limits", "status", "network", "storage"}


@pytest.mark.parametrize("filename", sorted(EXPECTED_VARIABLES))
def test_every_template_enables_platform_metrics(filename: str) -> None:
    """platformMonitor must be present, complete, and a sibling of `containers`.

    WITHOUT IT THE ACCOUNT COLLECTS ZERO METRIC ROWS AND NOTHING SAYS SO. Container
    logs arrive with no configuration at all, so the absence looks exactly like a
    working setup until someone queries for RECORD_TYPE = 'METRIC' and gets nothing.
    That is how this went unnoticed until the design was already written against
    metric names that were never being emitted.

    The nesting matters as much as the presence. `platformMonitor` belongs under
    `spec`, beside `containers`, NOT inside a container. Indented one level too far it
    is silently ignored: the spec still parses, the job still runs, and no metric is
    ever produced. Asserting on the parsed YAML rather than on the file text is what
    makes that detectable here.
    """
    text = (SPECS / filename).read_text()
    spec = yaml.safe_load(_env().from_string(text).render(**SUBSTITUTIONS))["spec"]

    assert "platformMonitor" not in spec["containers"][0], (
        f"{filename}: platformMonitor is nested inside the container, where it is "
        f"ignored without error. It belongs under spec, beside containers."
    )
    groups = set(spec["platformMonitor"]["metricConfig"]["groups"])
    assert groups == EXPECTED_METRIC_GROUPS, (
        f"{filename}: metric groups are {sorted(groups)}, expected "
        f"{sorted(EXPECTED_METRIC_GROUPS)}. Changing this set requires suspending, "
        f"re-applying and resuming every Task, so it should be a deliberate edit."
    )


@pytest.mark.parametrize("filename", sorted(EXPECTED_VARIABLES))
def test_rendered_template_is_valid_yaml_with_the_expected_shape(filename: str) -> None:
    text = (SPECS / filename).read_text()
    rendered = _env().from_string(text).render(**SUBSTITUTIONS)

    container = yaml.safe_load(rendered)["spec"]["containers"][0]
    env = container["env"]

    assert container["name"] == "dlt"
    assert env["DLT_REGISTRY_SOURCE"] == "auto"
    # The control plane is one database for the whole account and must not follow the
    # per-sport destination.
    assert env["SNOWFLAKE_DATABASE"] == "DLT_DB"
    if filename == "dlt_job_postgres.tmpl.yaml":
        assert env["DLT_DESTINATION"] == "postgres"
        assert env["DLT_DATASET"] == "DEV_JSMITH"
        assert env["SNOWFLAKE_APP_DATABASE"] == "DLT_DB"
        # record_run writes NFL_PROD_DB.OPS._DLT_RUNS (same as other NFL Tasks).
        # The data dest is still postgres; this is telemetry only.
        assert env["DESTINATION__SNOWFLAKE__CREDENTIALS__DATABASE"] == "NFL_DEV_DB"
    else:
        assert env["DESTINATION__SNOWFLAKE__CREDENTIALS__DATABASE"] == "NFL_DEV_DB"


def test_dev_templates_pass_the_full_argv_through_intact() -> None:
    # The JSON array has to survive substitution into a YAML scalar position and come
    # back as a list of strings. This is the whole reason args is encoded as JSON.
    for filename in ("dlt_dev_job.tmpl.yaml", "dlt_dev_job_nosecret.tmpl.yaml"):
        text = (SPECS / filename).read_text()
        rendered = _env().from_string(text).render(**SUBSTITUTIONS)
        args = yaml.safe_load(rendered)["spec"]["containers"][0]["args"]
        assert args == ARGV, f"{filename}: argv did not round-trip"
        assert all(isinstance(a, str) for a in args)


def test_prod_template_binds_a_secret() -> None:
    """Without this the container dies on dlt.secrets at 09:00 UTC.

    Every NFL pipeline resolves `secret:sources.nfl.api_key`, and the prod template
    shipped with no `secrets:` block at all, so the first scheduled run of any real
    source would have raised a KeyError inside a container nobody was watching.
    """
    text = (SPECS / "dlt_job.tmpl.yaml").read_text()
    container = yaml.safe_load(_env().from_string(text).render(**SUBSTITUTIONS))["spec"][
        "containers"
    ][0]
    bound = container["secrets"][0]
    assert bound["snowflakeSecret"] == SUBSTITUTIONS["secret"]
    assert bound["envVarName"] == SUBSTITUTIONS["env_var"]
    assert bound["secretKeyRef"] == "secret_string"

    pg = yaml.safe_load(
        _env().from_string((SPECS / "dlt_job_postgres.tmpl.yaml").read_text()).render(
            **SUBSTITUTIONS
        )
    )["spec"]["containers"][0]
    assert pg["secrets"][0]["envVarName"] == SUBSTITUTIONS["env_var"]
    assert pg["env"]["DLT_DESTINATION"] == "postgres"


def test_only_the_prod_template_enables_alerts() -> None:
    """DLT_ALERTS gates pipelines/common/alerts.py, and prod-only is the design.

    The dev templates and laptop runs never set it, so a developer breaking a
    pipeline on purpose cannot page the alert channel. If a dev template ever
    grows this variable, that is a policy change, not a copy-paste fix.
    """

    def env_of(filename: str) -> dict:
        text = (SPECS / filename).read_text()
        return yaml.safe_load(_env().from_string(text).render(**SUBSTITUTIONS))["spec"][
            "containers"
        ][0]["env"]

    assert env_of("dlt_job.tmpl.yaml")["DLT_ALERTS"] == "1"
    assert env_of("dlt_job_nosecret.tmpl.yaml")["DLT_ALERTS"] == "1"
    assert env_of("dlt_job_postgres.tmpl.yaml")["DLT_ALERTS"] == "1"
    assert "DLT_ALERTS" not in env_of("dlt_dev_job.tmpl.yaml")
    assert "DLT_ALERTS" not in env_of("dlt_dev_job_nosecret.tmpl.yaml")


def test_only_the_secret_template_binds_a_secret() -> None:
    # The pairing the Makefile relies on: SECRET set picks the secret template, unset
    # picks the other. If both grew a secrets block, `sample` would need a credential.
    def containers(filename: str) -> dict:
        text = (SPECS / filename).read_text()
        return yaml.safe_load(_env().from_string(text).render(**SUBSTITUTIONS))["spec"][
            "containers"
        ][0]

    assert "secrets" in containers("dlt_dev_job.tmpl.yaml")
    assert "secrets" not in containers("dlt_dev_job_nosecret.tmpl.yaml")
    assert "secrets" in containers("dlt_job.tmpl.yaml")
    assert "secrets" not in containers("dlt_job_nosecret.tmpl.yaml")
    assert "secrets" in containers("dlt_job_postgres.tmpl.yaml")
