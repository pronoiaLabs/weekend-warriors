"""Read pipeline specs from the DLT_DB.OPS.PIPELINE_REGISTRY control table.

WHY THIS EXISTS
    The image ships no pipeline definitions. A container asks Snowflake what to run, so
    adding or changing a pipeline in production is an INSERT rather than a rebuild and a
    redeploy. This module is the read side of that control plane.

CONTENTS
    1. Table shape ........ REGISTRY_TABLE, _COLUMNS, _fetch
    2. Lookups ............ get_spec, get_all, get_by_group

THE TABLE HALF OF A DUAL-MODE SYSTEM
    The runner chooses between this module and models.load_registry() at run time. The
    table is authoritative inside Snowflake, and registries/*.yml is the local-dev
    fallback. Both produce a PipelineSpec, and the API here mirrors models.Registry so
    callers never learn which one answered:

        get_spec(name)          -> PipelineSpec   (raises if missing or disabled)
        get_all(enabled_only)   -> list[PipelineSpec]
        get_by_group(group)     -> list[PipelineSpec]

    A shape accepted by one backend and rejected by the other is a bug that only appears
    in a container, which is why parsing and validation live in models.py rather than
    being duplicated here.

CONNECTION
    Shared with the rest of the repo through pipelines.common.snowflake_session.connect():
    an ambient OAuth token in SPCS, SNOWFLAKE_* env vars externally. Nothing about auth
    is decided in this module.
"""

from __future__ import annotations

import logging
from typing import TYPE_CHECKING, Any

from pipelines.batch.models import RegistryError, spec_from_row
from pipelines.common.snowflake_session import connect

if TYPE_CHECKING:
    from pipelines.batch.models import PipelineSpec

_log = logging.getLogger("dlt_pipeline")


# ---------------------------------------------------------------------------
# 1. Table shape
#
# Columns are selected by name and read by name, so their order in the table is
# irrelevant and a new column added by a later migration cannot shift anything here.
# The connector is imported inside _fetch rather than at module load, so importing this
# module never hard-requires snowflake-connector-python: the YAML and DuckDB paths must
# work without it.
# ---------------------------------------------------------------------------

# Fully-qualified control table. Database and schema are fixed by the account setup DDL.
REGISTRY_TABLE = "DLT_DB.OPS.PIPELINE_REGISTRY"

# Columns selected from the table; column order is irrelevant since we read by name.
#
# THIS TUPLE MUST LIST EVERY COLUMN spec_from_row READS, AND OMITTING ONE FAILS QUIETLY.
#     An unselected column is simply absent from the row dict. spec_from_row then either
#     substitutes the dataclass default, which is a wrong value that looks like a right
#     one, or gets None and trips validate(). Neither failure names the SELECT list, and
#     the registry table itself looks perfectly correct when you go and inspect it.
#
#     Both halves of that have already bitten:
#
#     season_rollover_month  Added to the table and to registry_sync, but not here, so
#                            every container silently fell back to the default of 8.
#                            A non-default sport would then load stale-season data with
#                            no error at all.
#
#     secret / env_var /     Never columns at all until the migration that added them.
#     external_access        Declared in registries/*.yml and correctly inlined into the
#                            Task DDL by generate_tasks.py, which reads the YAML, so
#                            everything looked right except the container, which rebuilt
#                            its spec from the table, saw None, and raised RegistryError
#                            on every scheduled pipeline of both sports at every fire.
#
#     tests/test_registry_config.py rebuilds a spec from a row containing ONLY these
#     columns, so adding a field to PipelineSpec without adding it here now fails there.
_COLUMNS = (
    "name",
    "source",
    "schedule",
    "target_database",
    "dataset_name",
    "write_disposition",
    "pipeline_group",
    "season_rollover_month",
    "secret",
    "env_var",
    "external_access",
    "config",
    "enabled",
)


def _fetch(where: str, params: tuple[Any, ...]) -> list[dict[str, Any]]:
    """Run a SELECT against the registry table and return rows as dicts."""
    from snowflake.connector import DictCursor  # noqa: PLC0415

    cols = ", ".join(_COLUMNS)
    sql = f"SELECT {cols} FROM {REGISTRY_TABLE} WHERE {where}"

    conn = connect()
    try:
        cur = conn.cursor(DictCursor)
        try:
            cur.execute(sql, params)
            # DictCursor yields uppercase keys; normalise to lowercase for spec_from_row.
            return [{k.lower(): v for k, v in row.items()} for row in cur.fetchall()]
        finally:
            cur.close()
    finally:
        conn.close()


# ---------------------------------------------------------------------------
# 2. Lookups
#
# `enabled` is filtered in SQL rather than in Python on purpose. It is the operator's
# kill switch: setting it FALSE stops a pipeline without editing YAML, rebuilding an
# image, or dropping a Task. A disabled pipeline is therefore indistinguishable from a
# missing one to every caller, which is the intended behaviour.
# ---------------------------------------------------------------------------


def get_spec(name: str) -> PipelineSpec:
    """Return the enabled spec named *name*; raise RegistryError if missing/disabled."""
    rows = _fetch("name = %s AND enabled = TRUE", (name,))
    if not rows:
        raise RegistryError(
            f"no enabled pipeline named '{name}' in {REGISTRY_TABLE}"
        )
    return spec_from_row(rows[0])


def get_all(enabled_only: bool = True) -> list[PipelineSpec]:
    """Return every spec in the table (enabled only by default)."""
    where = "enabled = TRUE" if enabled_only else "1 = 1"
    return [spec_from_row(r) for r in _fetch(where, ())]


def get_by_group(group: str, enabled_only: bool = True) -> list[PipelineSpec]:
    """Return all enabled specs in *group* (empty list if none)."""
    where = "pipeline_group = %s"
    if enabled_only:
        where += " AND enabled = TRUE"
    return [spec_from_row(r) for r in _fetch(where, (group,))]
