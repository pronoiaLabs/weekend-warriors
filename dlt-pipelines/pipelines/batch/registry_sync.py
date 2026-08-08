"""Sync pipelines/batch/registries/*.yml into the DLT_DB.OPS.PIPELINE_REGISTRY table.

The YAML file is the human-edited source of truth in git; this script pushes it
into the control table that the runner reads at execution time. Run it from a
laptop or CI after editing a registry file:

    python -m pipelines.batch.registry_sync             # upsert every YAML entry
    python -m pipelines.batch.registry_sync --prune     # ...and delete table rows not in YAML
    python -m pipelines.batch.registry_sync --dry-run   # print SQL + params, touch nothing
    python -m pipelines.batch.registry_sync --emit-sql  # print a runnable .sql (for `snow sql -f`)

The --emit-sql mode inlines all values as literals and does not open a
connection, so CD can pipe it straight into `snow sql` using only the OIDC
`snow` auth -- no Python-connector credentials required in the runner.

Upsert semantics (MERGE):
  * config fields are overwritten from YAML on every sync.
  * `enabled` is set TRUE only on INSERT; a manual disable in the table is
    preserved across syncs (we never flip it back on).
  * `updated_at` is stamped with CURRENT_TIMESTAMP() on insert and update.

Connection reuses pipelines.common.snowflake_session.connect() (SNOWFLAKE_* env vars externally).

CONTENTS
    1. Statement construction .. _MERGE_TAIL, _merge_header, MERGE_SQL, _row_params
    2. Literal rendering ....... _sql_literal, merge_sql_literal
    3. Prune ................... _prune_sql, _prune_sql_literal
    4. Entry points ............ emit_sql, sync, main

WHY THERE ARE TWO CODE PATHS FOR ONE STATEMENT
    The MERGE is built twice: once with `%s` binds for the Python connector, once with
    inlined literals for `--emit-sql`. That exists so CD can apply the registry through
    `snow sql -f` with only OIDC auth, never handling connector credentials.

    Two renderings of the same statement is exactly the kind of thing that drifts, so
    the shared parts are factored out deliberately. `_MERGE_TAIL` holds every clause
    that does not vary, and `_merge_header` takes the seven value tokens positionally.
    Adding a column means editing both of those and nothing else; if you find yourself
    editing one rendering only, the two are already out of step.

VARIANT COLUMNS
    `config` and `write_disposition` are both VARIANT and both go through PARSE_JSON on
    the way in. The value is json.dumps'd first, so None becomes the JSON text "null",
    which PARSE_JSON turns into a SQL NULL. That is why the absent case needs no
    special handling on either path.
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import sys
from typing import Any

from pipelines.batch.models import PipelineSpec, load_registry
from pipelines.batch.registry_store import REGISTRY_TABLE
from pipelines.common.snowflake_session import connect

log = logging.getLogger("dlt_pipeline")

# ---------------------------------------------------------------------------
# 1. Statement construction
# ---------------------------------------------------------------------------

# Every clause of the MERGE that does not vary between the two renderings. Shared by
# the parameterised (connector) path and the literal (--emit-sql) path so the two
# never drift.
_MERGE_TAIL = """) AS s
ON t.name = s.name
WHEN MATCHED THEN UPDATE SET
    source = s.source,
    schedule = s.schedule,
    target_database = s.target_database,
    dataset_name = s.dataset_name,
    write_disposition = s.write_disposition,
    pipeline_group = s.pipeline_group,
    season_rollover_month = s.season_rollover_month,
    secret = s.secret,
    env_var = s.env_var,
    external_access = s.external_access,
    config = s.config,
    updated_at = CURRENT_TIMESTAMP()
WHEN NOT MATCHED THEN INSERT
    (name, source, schedule, target_database, dataset_name, write_disposition,
     pipeline_group, season_rollover_month, secret, env_var, external_access,
     config, enabled, updated_at)
    VALUES
    (s.name, s.source, s.schedule, s.target_database, s.dataset_name,
     s.write_disposition, s.pipeline_group, s.season_rollover_month, s.secret,
     s.env_var, s.external_access, s.config,
     TRUE, CURRENT_TIMESTAMP())"""


def _merge_header(vals: "list[str]") -> str:
    """Build the MERGE ... USING(SELECT ...) header from 12 value tokens.

    vals order: name, source, schedule, target_database, dataset_name,
    write_disposition, pipeline_group, season_rollover_month, secret, env_var,
    external_access, config. The write_disposition and config tokens arrive already
    wrapped in PARSE_JSON(...) by the caller, since both columns are VARIANT.

    WHY secret / env_var / external_access ARE HERE AND NOT ONLY IN THE YAML.
        Same reason as season_rollover_month: a container in SPCS builds its spec from
        THIS TABLE, not from registries/*.yml, and `validate()` rejects a pipeline that
        has a schedule but declares none of the three. Leaving them unsynced does not
        fail the sync -- it fails every scheduled Task at run time, with a RegistryError
        raised from spec_from_row before the pipeline does any work.
    """
    return (
        f"MERGE INTO {REGISTRY_TABLE} AS t\n"
        "USING (SELECT\n"
        f"    {vals[0]} AS name,\n"
        f"    {vals[1]} AS source,\n"
        f"    {vals[2]} AS schedule,\n"
        f"    {vals[3]} AS target_database,\n"
        f"    {vals[4]} AS dataset_name,\n"
        f"    {vals[5]} AS write_disposition,\n"
        f"    {vals[6]} AS pipeline_group,\n"
        f"    {vals[7]} AS season_rollover_month,\n"
        f"    {vals[8]} AS secret,\n"
        f"    {vals[9]} AS env_var,\n"
        f"    {vals[10]} AS external_access,\n"
        f"    {vals[11]} AS config\n"
    )


# Parameterised MERGE for a single pipeline row. %s order must match _row_params().
MERGE_SQL = (
    _merge_header(
        [
            "%s", "%s", "%s", "%s", "%s", "PARSE_JSON(%s)", "%s", "%s",
            "%s", "%s", "%s", "PARSE_JSON(%s)",
        ]
    )
    + _MERGE_TAIL
)


def _row_params(spec: PipelineSpec) -> tuple[Any, ...]:
    """Return the %s bind values for MERGE_SQL, in order.

    write_disposition is json.dumps'd like config because its column is VARIANT and it
    may legitimately be a string, a dict, or None. json.dumps(None) is the text "null",
    which PARSE_JSON resolves to SQL NULL, so "no override" round-trips correctly.
    """
    return (
        spec.name,
        spec.source,
        spec.schedule,
        spec.database,
        spec.dataset_name,
        json.dumps(spec.write_disposition),
        spec.group,
        spec.season_rollover_month,
        spec.secret,
        spec.env_var,
        spec.external_access,
        json.dumps(spec.config),
    )


# ---------------------------------------------------------------------------
# 2. Literal rendering
#
# The --emit-sql path. Produces a file that `snow sql -f` can apply with no Python
# connector and no connector credentials, which is what lets CD sync the registry
# using OIDC auth alone.
# ---------------------------------------------------------------------------


def _sql_literal(val: Any) -> str:
    """Render a scalar as a Snowflake SQL literal ('...' with quotes doubled, or NULL)."""
    if val is None:
        return "NULL"
    return "'" + str(val).replace("'", "''") + "'"


def merge_sql_literal(spec: PipelineSpec) -> str:
    """Return a self-contained MERGE statement with inlined literals (no binds).

    Both VARIANT columns are dollar-quoted inside PARSE_JSON. `$$...$$` avoids having
    to escape the quotes and backslashes that appear inside any real JSON payload,
    which single-quoted literals would mangle.
    """
    config_json = json.dumps(spec.config)
    disposition_json = json.dumps(spec.write_disposition)
    vals = [
        _sql_literal(spec.name),
        _sql_literal(spec.source),
        _sql_literal(spec.schedule),
        _sql_literal(spec.database),
        _sql_literal(spec.dataset_name),
        f"PARSE_JSON($${disposition_json}$$)",
        _sql_literal(spec.group),
        # Unquoted: the column is NUMBER, and validate() has already proved it is an
        # int 1-12, so there is nothing here for a quote to protect against.
        str(spec.season_rollover_month),
        # NULL for an unscheduled pipeline. _sql_literal renders None as NULL, which is
        # what `sample` needs: validate() only demands these three when a schedule is set.
        _sql_literal(spec.secret),
        _sql_literal(spec.env_var),
        _sql_literal(spec.external_access),
        f"PARSE_JSON($${config_json}$$)",
    ]
    return _merge_header(vals) + _MERGE_TAIL + ";"


# ---------------------------------------------------------------------------
# 3. Prune
#
# Opt-in, because deleting rows the YAML no longer mentions is only correct when the
# YAML is the whole truth. Someone running sync from a branch with a partial registry
# would otherwise delete everyone else's pipelines.
# ---------------------------------------------------------------------------


def _prune_sql(names: list[str]) -> tuple[str, tuple[Any, ...]]:
    """Return (sql, params) that deletes table rows whose name is not in *names*."""
    placeholders = ", ".join(["%s"] * len(names))
    sql = f"DELETE FROM {REGISTRY_TABLE} WHERE name NOT IN ({placeholders})"
    return sql, tuple(names)


def _prune_sql_literal(names: list[str]) -> str:
    """Return a DELETE statement with inlined name literals (for --emit-sql)."""
    name_list = ", ".join(_sql_literal(n) for n in names)
    return f"DELETE FROM {REGISTRY_TABLE} WHERE name NOT IN ({name_list});"


# ---------------------------------------------------------------------------
# 4. Entry points
# ---------------------------------------------------------------------------


def emit_sql(specs: list[PipelineSpec], *, prune: bool = False) -> str:
    """Return a runnable .sql script (MERGE per pipeline, optional prune) as text."""
    parts: list[str] = [
        "-- Generated by `python -m pipelines.batch.registry_sync --emit-sql`.",
        "-- Applies pipelines/batch/registries/*.yml to DLT_DB.OPS.PIPELINE_REGISTRY.",
        "-- Run with: snow sql -f registry_sync.sql",
        "",
    ]
    for spec in specs:
        parts.append(merge_sql_literal(spec))
        parts.append("")
    if prune:
        parts.append(_prune_sql_literal([s.name for s in specs]))
        parts.append("")
    return "\n".join(parts).strip() + "\n"


def sync(
    specs: list[PipelineSpec],
    *,
    prune: bool = False,
    dry_run: bool = False,
) -> None:
    """Upsert every spec into the registry table; optionally prune stray rows."""
    names = [s.name for s in specs]

    if dry_run:
        for spec in specs:
            log.info("MERGE %s params=%s", spec.name, _row_params(spec))
        if prune:
            sql, params = _prune_sql(names)
            log.info("PRUNE %s params=%s", sql, params)
        return

    conn = connect()
    try:
        cur = conn.cursor()
        try:
            for spec in specs:
                cur.execute(MERGE_SQL, _row_params(spec))
                log.info("synced pipeline '%s'", spec.name)
            if prune:
                sql, params = _prune_sql(names)
                cur.execute(sql, params)
                log.info("pruned %s row(s) not present in YAML", cur.rowcount)
            conn.commit()
        finally:
            cur.close()
    finally:
        conn.close()


def _parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="pipelines.batch.registry_sync",
        description="Sync the registries/ directory into DLT_DB.OPS.PIPELINE_REGISTRY.",
    )
    parser.add_argument(
        "--prune",
        action="store_true",
        help="delete table rows whose name is not present in the registries",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="print the SQL and bind params without touching the table",
    )
    parser.add_argument(
        "--emit-sql",
        action="store_true",
        help="print a runnable .sql script (inlined literals) and exit; no connection",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    logging.basicConfig(
        level=os.environ.get("LOG_LEVEL", "INFO").upper(),
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )
    args = _parse_args(sys.argv[1:] if argv is None else argv)
    registry = load_registry()

    if args.emit_sql:
        # Write only the SQL to stdout so `... --emit-sql > sync.sql` is clean.
        print(emit_sql(registry.pipelines, prune=args.prune), end="")
        return 0

    sync(registry.pipelines, prune=args.prune, dry_run=args.dry_run)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
