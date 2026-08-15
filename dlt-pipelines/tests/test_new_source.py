"""The scaffold has to keep producing a registry the loader accepts.

WHY THIS EXISTS
    `tools/new_source.py` writes a registry stub from a string template, so it has no
    connection to PipelineSpec beyond someone remembering to update both. Add a
    required field to the model and the generator keeps emitting last month's shape,
    which an adopter discovers as a validation error on a file they did not write.

    The names are the other half. Four generated files have to agree on five
    identifiers, and a mismatch surfaces late and badly: a KeyError from dlt.secrets
    inside a container, or a connection timeout that reads like the API being down.
    Cross-checking them here costs milliseconds.

    Everything renders into tmp_path, so this never touches the repo.
"""
from __future__ import annotations

import sys
from pathlib import Path

import pytest

_ROOT = Path(__file__).parent.parent.resolve()
if str(_ROOT) not in sys.path:
    sys.path.insert(0, str(_ROOT))

pytest.importorskip("yaml")

from pipelines.batch.models import load_registry, resolve_database  # noqa: E402
from tools.new_source import main  # noqa: E402

NAME = "widgets"
HOST = "api.widgets.example"


@pytest.fixture
def scaffold(tmp_path: Path) -> Path:
    assert main([NAME, "--host", HOST, "--out-dir", str(tmp_path)]) == 0
    return tmp_path


def test_writes_the_five_expected_files(scaffold: Path) -> None:
    for rel in (
        f"sql/sources/{NAME}/01_databases.sql",
        f"sql/sources/{NAME}/02_external_access.sql",
        f"sql/sources/{NAME}/03_secrets.sql",
        f"sql/sources/{NAME}/05_dbt_trigger.sql",
        f"pipelines/batch/registries/{NAME}-registry.yml",
    ):
        assert (scaffold / rel).is_file(), rel


def test_generated_registry_loads_and_validates(scaffold: Path) -> None:
    # load_registry() runs full validation, so this fails the moment the stub drifts
    # from PipelineSpec. That is the whole point: an adopter should never be the one
    # to discover a required field is missing.
    registry = load_registry(scaffold / "pipelines" / "batch" / "registries")
    spec = registry.get(f"{NAME}_example")

    assert resolve_database(spec, "DEV") == "WIDGETS_DEV_DB"
    assert resolve_database(spec, "PROD") == "WIDGETS_PROD_DB"
    assert spec.dataset_name == "RAW"
    assert spec.group == NAME


def test_generated_stub_is_not_scheduled(scaffold: Path) -> None:
    # A schedule on an unproven pipeline is a Task that fails at 09:00 UTC. The stub
    # tells you to add one only after a manual run works.
    registry = load_registry(scaffold / "pipelines" / "batch" / "registries")
    assert registry.get(f"{NAME}_example").schedule is None


def test_the_five_names_agree_across_all_four_files(scaffold: Path) -> None:
    registry = load_registry(scaffold / "pipelines" / "batch" / "registries")
    spec = registry.get(f"{NAME}_example")
    sql = "".join(
        p.read_text() for p in sorted((scaffold / "sql" / "sources" / NAME).glob("*.sql"))
    )

    # 1 and 2: the secret object the container mounts.
    assert spec.secret == "DLT_DB.OPS.WIDGETS_API_KEY"
    assert f"CREATE SECRET IF NOT EXISTS {spec.secret}" in sql

    # 3: the EAI that grants egress, emitted into the Task DDL.
    assert spec.external_access == "WIDGETS_API_EAI"
    assert f"EXTERNAL ACCESS INTEGRATION {spec.external_access}" in sql

    # 4: the databases the stem resolves to.
    for env in ("DEV", "PROD"):
        assert f"CREATE DATABASE IF NOT EXISTS {resolve_database(spec, env)}" in sql

    # 5: env_var must be the dlt-mangled form of the config's secret: path, or the
    # container binds the key to a name dlt never looks up.
    ref = spec.config["client"]["auth"]["api_key"]
    assert ref == f"secret:sources.{NAME}.api_key"
    assert spec.env_var == ref.removeprefix("secret:").upper().replace(".", "__")


def test_dbt_trigger_names_agree(scaffold: Path) -> None:
    # The trigger file's stream, task, environment and project object must all
    # carry the sport name, or the build fires against the wrong sport. The
    # scaffold follows the <name>_prod env convention (NFL's plain 'prod' is a
    # grandfathered hand-edit, not the pattern).
    sql = (scaffold / "sql" / "sources" / NAME / "05_dbt_trigger.sql").read_text()
    upper = NAME.upper()
    assert f"CREATE OR ALTER TASK {upper}_PROD_DB.OPS.DBT_BUILD_{upper}" in sql
    assert f"ON TABLE {upper}_PROD_DB.RAW._DLT_LOADS" in sql
    assert f"DLT_DB.DEPLOY.CORTEX_LIFECYCLE_{upper}" in sql
    # ENVIRONMENT rides inside the EXECUTE IMMEDIATE string, hence the
    # doubled quotes; the DBT_BUILDS row carries it plain.
    assert f"ENVIRONMENT = ''{NAME}_prod''" in sql
    assert f"'{NAME}', '{NAME}_prod'" in sql
    # the harvest child follows the build and calls the shared proc
    assert f"CREATE OR ALTER TASK {upper}_PROD_DB.OPS.DBT_HARVEST_{upper}" in sql
    assert f"AFTER {upper}_PROD_DB.OPS.DBT_BUILD_{upper}" in sql
    assert "CALL DLT_DB.OPS.SP_DBT_HARVEST();" in sql
    # the audit-table type trap: TZ, never NTZ (failed live, WORKFLOW-4)
    assert "TIMESTAMP_NTZ" not in sql
    # the observability trap: never the generated-task prefix
    assert "DLT_TASK_" not in sql.replace("DLT_TASK_ prefix", "")


def test_dbt_trigger_alerts_and_reraises(scaffold: Path) -> None:
    # The scaffold's proc must carry the Slack transition alerting the live
    # sports have (sql/ops/09_alerting.sql): a failure handler that pings the
    # FIRST failure of a streak and then RAISEs so TASK_HISTORY and the
    # auto-suspend counter are untouched, plus the recovery ping on the first
    # success after. A scaffold without the handler would give the next sport
    # exactly the two-day-silent outage this exists to prevent.
    sql = (scaffold / "sql" / "sources" / NAME / "05_dbt_trigger.sql").read_text()

    assert f"'dbt_build_{NAME}'" in sql, "alert scope must carry the sport name"
    assert "DLT_DB.OPS.ALERT_STATE" in sql
    assert "SLACK_ALERTS_INT" in sql
    assert "SANITIZE_WEBHOOK_CONTENT" in sql
    assert "RECOVERED dbt_build_" in sql
    # the handler must re-raise, not swallow: a swallowed dbt failure would
    # mark the task successful and fire the harvest child on a broken build
    assert "RAISE;" in sql


def test_host_reaches_both_the_network_rule_and_the_base_url(scaffold: Path) -> None:
    # A network rule that does not cover base_url is a timeout, not an auth error,
    # so it gets misread as the API being down.
    eai = (scaffold / "sql" / "sources" / NAME / "02_external_access.sql").read_text()
    spec = load_registry(scaffold / "pipelines" / "batch" / "registries").get(
        f"{NAME}_example"
    )

    assert f"'{HOST}:443'" in eai, "the port is required in VALUE_LIST"
    assert HOST in spec.config["client"]["base_url"]


def test_existing_files_are_never_clobbered(scaffold: Path) -> None:
    target = scaffold / "sql" / "sources" / NAME / "01_databases.sql"
    target.write_text("-- hand-edited, do not lose me\n")

    assert main([NAME, "--host", HOST, "--out-dir", str(scaffold)]) == 0
    assert target.read_text() == "-- hand-edited, do not lose me\n"


@pytest.mark.parametrize("bad", ["9lives", "my-source", "my source", "", "Weather!"])
def test_invalid_names_are_rejected(bad: str, tmp_path: Path) -> None:
    # The name becomes a database prefix and a SQL identifier, interpolated into DDL
    # that is not parameterised.
    with pytest.raises(SystemExit):
        main([bad, "--out-dir", str(tmp_path)])
