"""Generic dlt pipeline runner driven by pipelines/batch/registries/.

WHY THIS EXISTS
    One container image, N pipelines. Nothing here is specific to any source: the
    source object is built at runtime from a registry entry, so adding a pipeline is a
    config change rather than new code and a rebuilt image.

CONTENTS
    1. Secret resolution ....... SECRET_PREFIX, _iter_secret_refs, _resolve_secrets
    2. Source construction ..... _constant_stamper, _apply_constants,
                               _resolve_tokens, build_source
    2b. Run-time parameters .... _parse_params, _apply_params
    3. Preflight ............... _check_secrets, _check_merge_keys
    4. Execution ............... run_pipeline
    5. Registry selection ...... _registry_mode, resolve_specs
    6. CLI ..................... _parse_args, main

USAGE
    python -m pipelines.batch.run <name>        # run one pipeline by name
    python -m pipelines.batch.run <name> --resource teams --resource players
                                               # run only those resources of <name>
    python -m pipelines.batch.run <name> --resource games_post --param 'seasons[]=2023'
                                               # override that resource's query params
    python -m pipelines.batch.run --group G     # run every pipeline in group G
    python -m pipelines.batch.run --all         # run every pipeline sequentially
    python -m pipelines.batch.run --list        # print the registry and exit

AUTH
  * In-Snowflake (SPCS): the Snowflake destination uses the ambient OAuth session
    token, set via env in the SPCS spec. No secrets are baked into the image.
  * External (laptop / CI): credentials come from your `snow` CLI connection through
    deploy/snow_env.py, or from .dlt/secrets.toml.

RUNTIME OVERRIDES
    DLT_DESTINATION  replaces each spec's `destination` (the smoke test sets duckdb)
    DLT_DATASET      replaces the target schema for one run, used by the dev-in-
                     Snowflake path to redirect into a per-developer schema

CONFIG SOURCE (control plane)
    Specs come from DLT_DB.OPS.PIPELINE_REGISTRY inside Snowflake and from
    pipelines/batch/registries/*.yml locally, where every file in that directory is
    merged into one registry. DLT_REGISTRY_SOURCE selects:
        "auto"  (default) -> table when an SPCS session token is mounted, else YAML
        "table" -> always the registry table
        "yaml"  -> always the registries/ directory
    This is what keeps the image config-agnostic: adding a pipeline is an INSERT, not
    an image rebuild.
"""

from __future__ import annotations

import argparse
import copy
import importlib
import logging
import os
import sys
from dataclasses import replace
from typing import Any, Iterator

import dlt

from pipelines.batch.models import (
    PipelineSpec,
    current_season,
    load_registry,
    resolve_database,
)
from pipelines.common import alerts
from pipelines.common.observability import configure_logging, record_run

# Module-level logger used before a per-pipeline adapter is available (e.g. in main).
log = logging.getLogger("dlt_pipeline")


# ---------------------------------------------------------------------------
# 1. Secret resolution
#
# Registry entries never contain credentials. A string value may instead point at a
# key in dlt's secret store, and is swapped for the real value at build time:
#
#     registry : api_key: "secret:sources.nfl.api_key"
#     local    : .dlt/secrets.toml  ->  [sources.nfl] api_key = "..."
#     SPCS     : env var SOURCES__NFL__API_KEY, bound from a Snowflake SECRET
#
# The dotted path maps to the env var by uppercasing and doubling the separators.
# ---------------------------------------------------------------------------

SECRET_PREFIX: str = "secret:"


def _iter_secret_refs(obj: Any) -> Iterator[str]:
    """Yield every 'secret:<path>' reference in a config tree, as bare dotted paths."""
    if isinstance(obj, dict):
        for v in obj.values():
            yield from _iter_secret_refs(v)
    elif isinstance(obj, list):
        for v in obj:
            yield from _iter_secret_refs(v)
    elif isinstance(obj, str) and obj.startswith(SECRET_PREFIX):
        yield obj[len(SECRET_PREFIX):]


def _resolve_secrets(obj: Any) -> Any:
    """Walk a config tree; replace 'secret:<path>' strings with dlt.secrets values."""
    if isinstance(obj, dict):
        return {k: _resolve_secrets(v) for k, v in obj.items()}
    if isinstance(obj, list):
        return [_resolve_secrets(v) for v in obj]
    if isinstance(obj, str) and obj.startswith(SECRET_PREFIX):
        return dlt.secrets[obj[len(SECRET_PREFIX):]]
    return obj


# ---------------------------------------------------------------------------
# 2. Source construction
#
# Dispatch on spec.source. Two shapes exist and they differ in where table hints
# such as primary_key live, which matters to the preflight below:
#
#   rest_api : fully declarative, hints come from the registry config
#   sample   : an in-code dlt source, hints come from its @dlt.resource decorators
#
# Never inspect the registry config to answer "does this resource have a key?".
# Ask the built source instead, which is the only view that sees both.
#
# A resource may also declare `constants`, a mapping stamped onto every row it yields.
# That covers the case where an API filters on a field it does not return, which would
# otherwise leave several resources sharing one table with no way to tell their rows
# apart. See _apply_constants.
#
# EVERY SOURCE MUST HAVE ITS OWN SCHEMA NAME, which is why `name` is passed explicitly
# below. A dlt source is named after the function that declares it, so every rest_api
# pipeline in this repo would otherwise produce a schema called `rest_api`.
#
# Two pipelines sharing a schema name in one dataset is not a SQL-level conflict, but
# the destination looks a stored schema up BY NAME with no notion of which pipeline
# wrote it, and takes the most recent. A pipeline whose local working directory does
# not hold its schema restores it from the destination, so it can adopt another
# pipeline's table definitions and then keep evolving them. A fresh working directory
# is every SPCS run, so this is a live hazard rather than a theoretical one. dlt guards
# pipeline identity for state; it does not do so for schemas.
#
# Registry names are unique across the whole registries/ directory, which makes
# spec.name the natural schema name. This does NOT change the target dataset: a
# schema-name suffix is only appended to non-default schemas within one pipeline, and
# each pipeline here has exactly one source.
# ---------------------------------------------------------------------------


def _constant_stamper(constants: dict[str, Any]):
    """Return a row mapper that adds *constants* to every row.

    A factory rather than an inline lambda, and that is the whole point of it. A lambda
    written inside the loop below would close over the loop variable, so all three
    games resources would stamp the LAST season_type. Nothing raises; the rows are
    simply wrong. Binding here gives each resource its own captured value.
    """

    def stamp(row: dict[str, Any]) -> dict[str, Any]:
        return {**row, **constants}

    return stamp


def _apply_constants(cfg: dict[str, Any]) -> None:
    """Convert each resource's `constants` mapping into a dlt processing step, in place.

    `constants` is this repo's key, not dlt's. It exists because an API can filter on a
    field it does not return: the games endpoint takes `season_type` as a query
    parameter and omits it from every row, so three resources sharing one table would
    otherwise be indistinguishable once loaded.

    It MUST be removed before the config reaches dlt. dlt validates a resource against
    a TypedDict and rejects anything it does not declare, so leaving the key in place
    fails the whole source with a message about unexpected fields.

    Mutates *cfg* deliberately: the caller passes the tree returned by
    _resolve_secrets, which is already a fresh copy, so the registry is never touched.
    """
    for entry in cfg.get("resources") or []:
        if not isinstance(entry, dict):
            continue
        constants = entry.pop("constants", None)
        if not constants:
            continue

        steps = list(entry.get("processing_steps") or [])
        steps.append({"map": _constant_stamper(constants)})
        entry["processing_steps"] = steps


# Runtime tokens a registry value may contain. Substituted before dlt ever sees the
# config, so a resource reads as declarative YAML but still knows what year it is.
#
# WHY THIS EXISTS
#     A Snowflake Task passes no arguments. Every season-scoped endpoint here either
#     needs a season or fails: /standings and /advanced_stats return HTTP 400 without
#     one, and /games silently returns EVERY season instead. So a scheduled run has to
#     get the year from somewhere, and the only place left is the config itself.
#
#     The alternative, a literal year in the registry, works until nobody remembers to
#     change it in August. Then every nightly load reports success while re-fetching a
#     season that finished months ago, which is the exact failure this repo is built to
#     make impossible.
#
#     A backfill still wins: --param merges into endpoint.params after this runs, so
#     `--param season=2023` overwrites the resolved value the same way it overwrites a
#     literal.
def _token_values(spec: PipelineSpec) -> dict[str, Any]:
    """Resolve the token table once per call, so the date is read at run time.

    Takes the spec because the season boundary is per sport: `season_rollover_month` is
    8 for the NFL and 5 for the WNBA. One `{current_season}` token serves every league,
    which keeps the registries uniform and means a new sport adds a line of YAML rather
    than a token and a function.
    """
    return {"{current_season}": current_season(spec.season_rollover_month)}


def _resolve_tokens(obj: Any, tokens: dict[str, Any]) -> Any:
    """Return *obj* with any string equal to a known token replaced by its value.

    Exact matches only, not substrings. A season is a whole parameter value, and
    partial substitution would turn an unrelated string containing braces into
    something silently different.
    """
    if isinstance(obj, dict):
        return {k: _resolve_tokens(v, tokens) for k, v in obj.items()}
    if isinstance(obj, list):
        return [_resolve_tokens(v, tokens) for v in obj]
    if isinstance(obj, str) and obj in tokens:
        return tokens[obj]
    return obj


# Vendor sources with no arguments beyond (name, config). Each entry is the one-line
# reason it could not be a rest_api entry; the module docstring has the long form.
#   firecrawl   search -> scrape -> extract, with control flow between the calls;
#               news is dated by the search window, so no season token
#   openmeteo   columnar hourly arrays that no data_selector can zip; the window is
#               start_date/end_date or forecast_days, so no season token
#   nflverse    parquet files behind a GitHub release redirect, read through
#               nflreadpy; it keeps its own season clock, so no season token
#   sleeper     a dict-of-dicts player dump, and every other call takes the
#               season/week that only /state/nfl knows; no season token
CUSTOM_SOURCES: dict[str, tuple[str, str]] = {
    "firecrawl": ("pipelines.batch.firecrawl_source", "firecrawl_news"),
    "openmeteo": ("pipelines.batch.openmeteo_source", "openmeteo_weather"),
    "nflverse": ("pipelines.batch.nflverse_source", "nflverse_source"),
    "sleeper": ("pipelines.batch.sleeper_source", "sleeper_source"),
}


def build_source(spec: PipelineSpec):
    """Construct a dlt source object from a registry entry, dispatching on `source`."""
    cfg: dict[str, Any] = _resolve_secrets(spec.config)

    if spec.source == "rest_api":
        from dlt.sources.rest_api import rest_api_source  # noqa: PLC0415

        tokens = _token_values(spec)
        cfg = _resolve_tokens(cfg, tokens)
        # Logged because a wrong year is invisible afterwards: the run succeeds, the
        # row counts look ordinary, and only a COUNT(DISTINCT season) would show it.
        # The rollover month rides along because it is what makes the year right or
        # wrong, and it is the thing you will want to check when the year looks off.
        log.info(
            "resolved runtime tokens: %s (season rollover month %s)",
            tokens,
            spec.season_rollover_month,
        )
        _apply_constants(cfg)
        return rest_api_source(cfg, name=spec.name)

    if spec.source == "sample":
        # Zero-dependency in-code generator; works locally and inside SPCS (no
        # external source, no secret). See pipelines/batch/sample_source.py.
        from pipelines.batch.sample_source import sample_source  # noqa: PLC0415

        return sample_source(
            n_customers=cfg.get("n_customers", 5),
            n_orders=cfg.get("n_orders", 5),
        )

    if spec.source in CUSTOM_SOURCES:
        # Every vendor source shares one signature, (name, config), and is imported
        # here rather than at module level: CI import-checks run.py with a minimal
        # dependency set, and each vendor SDK is only installed for its own run.
        module_path, factory_name = CUSTOM_SOURCES[spec.source]
        factory = getattr(importlib.import_module(module_path), factory_name)
        return factory(name=spec.name, config=cfg)

    if spec.source == "snowflake_app":
        # SELECT * from listed APP tables through the ambient Snowflake session.
        # sql_database is not a supported source. See snowflake_app_source.py.
        from pipelines.batch.snowflake_app_source import snowflake_app  # noqa: PLC0415

        database = (
            cfg.get("database")
            or os.environ.get("SNOWFLAKE_APP_DATABASE")
            or resolve_database(spec, "PROD")
        )
        return snowflake_app(
            name=spec.name,
            tables=list(cfg.get("tables") or []),
            database=database,
            schema=cfg.get("schema") or "APP",
        )

    # models.validate() guards this; this branch is a defensive fallback.
    raise ValueError(f"unhandled source type: {spec.source!r}")


# ---------------------------------------------------------------------------
# 2b. Run-time endpoint parameters
#
# A registry entry pins the params an endpoint is normally called with. Backfills want
# to vary one of them (a season, a date window) for a single run, and editing YAML to
# do that means a commit per backfill and a registry that no longer describes the
# steady state.
#
# Two rules that are easy to get wrong:
#
#   Values stay STRINGS. Query parameters are strings on the wire whatever type they
#   started as, so there is nothing to coerce and therefore no coercion bug to have.
#
#   A REPEATED KEY ACCUMULATES rather than overwriting. `seasons[]=2023 seasons[]=2022`
#   is one filter with two values, which is what the trailing-bracket convention means.
#   A plain dict would keep only the last and silently narrow the backfill.
#
# Note the brackets belong in the key, exactly as the API spells it. `season=2023` is a
# parameter these endpoints do not have, and this API IGNORES an unknown parameter name
# rather than rejecting it, so the filter appears to work and every season comes back.
# (A known name with the wrong type does get a 400, so mistyping is loud; misnaming is
# not.)
#
# WHICH RESOURCE A PARAMETER LANDS ON
#     Plain      KEY=VALUE   -> the single selected resource
#     Qualified  RES:KEY=VAL -> that named resource, whatever is selected
#
# The qualified form exists for parent-child pipelines. `plays` is fetched one game at a
# time, with the game id resolved from a parent `games` resource, so narrowing a run to
# one season means filtering the PARENT. Put the season on the child and nothing
# happens: by then the request is already about one specific game.
# ---------------------------------------------------------------------------


def _parse_params(raw: list[str]) -> dict[str | None, dict[str, Any]]:
    """Group 'KEY=VALUE' and 'RESOURCE:KEY=VALUE' items by their target resource.

    Returns {resource_name_or_None: {param: value}}. The None key holds unqualified
    parameters, which the caller binds to whichever single resource was selected.
    """
    targets: dict[str | None, dict[str, Any]] = {}

    for item in raw:
        key, sep, value = item.partition("=")  # first '=' only, so values may contain '='
        if not sep or not key:
            raise ValueError(
                f"--param must be KEY=VALUE, got '{item}'. For an array parameter keep "
                "the brackets, e.g. --param 'seasons[]=2023'."
            )

        # A colon before the '=' names the resource. Split on the FIRST colon only:
        # parameter values routinely contain them, but by here the value is already
        # separated off, and a parameter NAME containing a colon is not a thing.
        resource, sep_colon, param = key.partition(":")
        if not sep_colon:
            resource, param = None, key
        elif not resource or not param:
            raise ValueError(
                f"--param '{item}' has an empty resource or parameter name. The "
                "qualified form is RESOURCE:KEY=VALUE, e.g. "
                "--param 'games_post_ref:seasons[]=2025'."
            )

        params = targets.setdefault(resource, {})
        if param not in params:
            params[param] = value
        elif isinstance(params[param], list):
            params[param].append(value)
        else:
            params[param] = [params[param], value]

    return targets


def _apply_params(config: dict[str, Any], targets: dict[str, dict[str, Any]]) -> dict[str, Any]:
    """Return a copy of *config* with each target's params merged into its endpoint.

    *targets* maps a resource name to the parameters to set on it; every name must
    already be resolved (no None keys).

    Deep-copied rather than edited in place. Registry files share nested structures
    through YAML anchors, so two pipelines can hold the *same* dict object; mutating one
    would change the other. Nothing else in this module writes to a spec's config, and
    this must not be the first thing that does.

    Merged at the resource level, which wins over `resource_defaults`, so an override
    beats the registry value while leaving the rest of the endpoint intact.
    """
    updated: dict[str, Any] = copy.deepcopy(config)
    remaining = dict(targets)

    for entry in updated.get("resources") or []:
        if not isinstance(entry, dict):
            continue
        params = remaining.pop(entry.get("name"), None)
        if params is None:
            continue

        # `endpoint` may be written as a bare path string; promote it before merging.
        endpoint = entry.get("endpoint")
        if isinstance(endpoint, str):
            endpoint = {"path": endpoint}
        elif not isinstance(endpoint, dict):
            endpoint = {}
        entry["endpoint"] = endpoint

        endpoint["params"] = {**(endpoint.get("params") or {}), **params}

    if remaining:
        raise ValueError(
            f"--param targets resource(s) {', '.join(sorted(remaining))}, which this "
            "pipeline's config does not declare. Check the names against the registry."
        )

    return updated


# ---------------------------------------------------------------------------
# 3. Preflight
#
# Fail before moving data, not twenty lines deep inside dlt. Both checks below exist
# because their failure mode is silent or misattributed, which costs far more time
# than an outright error.
#
# They run at two different moments, and the order is forced: secrets are resolved
# *inside* build_source, so a missing one raises there before any later check could
# run. Hence secrets first, then build, then hints.
# ---------------------------------------------------------------------------


def _check_secrets(spec: PipelineSpec) -> None:
    """Verify every `secret:` reference in the config resolves.

    Without this the first missing key raises mid-build, and only that one is
    reported. Collecting them all means one round trip instead of one per credential.
    """
    missing: list[str] = []
    for path in _iter_secret_refs(spec.config):
        try:
            dlt.secrets[path]
        except Exception:  # noqa: BLE001, any lookup failure means "not usable"
            missing.append(path)

    if missing:
        raise RuntimeError(
            f"pipeline '{spec.name}': missing secret(s): {', '.join(sorted(set(missing)))}. "
            "Set them locally in .dlt/secrets.toml, or in SPCS bind a Snowflake SECRET to "
            "the matching env var (dots uppercased to double underscores, e.g. "
            "sources.nfl.api_key -> SOURCES__NFL__API_KEY)."
        )


def _check_merge_keys(spec: PipelineSpec, source: Any) -> None:
    """Refuse to run a `merge` resource that has nothing to merge on.

    dlt does not raise in this situation. It falls back to a staged append, so the
    load succeeds, the logs stay green, raise_on_failed_jobs() passes, and rows
    silently accumulate on every run. The duplicates surface downstream, far from the
    cause.

    Effective disposition is `spec.write_disposition or the resource's own`. A spec
    that sets one wins, because that is what pipeline.run() does with it; a spec that
    leaves it unset lets each resource keep its own.

    scd2 is exempt: it tracks history by row hash and needs no declared key.

    Reads `.resources.selected`, never `.resources`. On a source narrowed by
    with_resources() the full `.resources` mapping still lists every resource the
    source declares, so iterating it would validate resources that are not going to
    load. `.selected` is the only view that answers "what will actually run".
    """
    offenders: list[str] = []

    for res_name, res in source.resources.selected.items():
        schema = res.compute_table_schema()
        disposition: Any = spec.write_disposition or schema.get("write_disposition")

        # A disposition may be a plain string or {"disposition": ..., "strategy": ...}.
        # The two forms put the strategy in different places, and reading only the dict
        # would report a resource that HAS a strategy as having none:
        #   pipeline-level dict  -> still nested, because the spec is passed through raw
        #   resource-level       -> dlt has already resolved it onto the table schema as
        #                           `x-merge-strategy`, leaving write_disposition a bare
        #                           string
        if isinstance(disposition, dict):
            strategy = disposition.get("strategy")
            disposition = disposition.get("disposition")
        else:
            strategy = schema.get("x-merge-strategy")

        if disposition != "merge" or strategy == "scd2":
            continue

        columns: dict[str, Any] = schema.get("columns") or {}
        has_key = any(c.get("primary_key") or c.get("merge_key") for c in columns.values())
        if not has_key:
            offenders.append(res_name)

    if offenders:
        raise RuntimeError(
            f"pipeline '{spec.name}': write_disposition is 'merge' but resource(s) "
            f"{', '.join(sorted(offenders))} declare no primary_key or merge_key. "
            "dlt would silently append instead of merging, duplicating rows on every "
            "run. Declare a key, use the scd2 strategy, or set write_disposition to "
            "'append' or 'replace' if that is what you actually want."
        )


# ---------------------------------------------------------------------------
# 4. Execution
#
# A pipeline is the unit of scheduling, but not necessarily the unit of work. One
# registry entry can hold several resources (nfl_reference holds `teams` and
# `players`), and `resources` narrows a run to a subset of them: backfilling one
# endpoint should not re-run its neighbours, and debugging one should not mean
# waiting through the others.
#
# The filter is recorded alongside the run, because a partial run that reports itself
# as a whole-pipeline run is exactly the kind of quiet misreporting the preflight
# checks above exist to prevent.
# ---------------------------------------------------------------------------


def run_pipeline(
    spec: PipelineSpec,
    resources: list[str] | None = None,
    params: dict[str, Any] | None = None,
) -> None:
    """Execute a single pipeline end-to-end and record the outcome in OPS._DLT_RUNS.

    *resources* limits the run to those resource names. Omitted (the default) runs
    every resource the source declares. An unknown name is dlt's error to raise, and
    it names the available resources, so it is not re-validated here.

    *params* maps a resource name to the query parameters to override on it, for a
    backfill that should not become a registry edit. Names are already resolved by the
    CLI, so a parent resource can be targeted while a child is the one selected.
    """
    pipeline_log = configure_logging(spec.name)

    destination: str = os.environ.get("DLT_DESTINATION") or spec.destination

    # DLT_DATASET overrides the target schema for a single run without touching
    # the registry. Dev-in-Snowflake runs set it to an isolated per-developer
    # schema (e.g. DEV_TONY); prod runs leave it unset and use spec.dataset_name.
    dataset: str = os.environ.get("DLT_DATASET") or spec.dataset_name

    pipeline_log.info(
        "starting pipeline (source=%s, destination=%s, dataset=%s, disposition=%s, "
        "resources=%s, params=%s)",
        spec.source,
        destination,
        dataset,
        spec.write_disposition,
        ",".join(resources) if resources else "all",
        params or "none",
    )

    pipeline = dlt.pipeline(
        pipeline_name=spec.name,
        destination=destination,
        dataset_name=dataset,
    )

    try:
        # Preflight before any data moves. See section 3 for why the order is fixed.
        _check_secrets(spec)

        # Overrides go in before the source is built, since the params live in the
        # config the builder reads. `replace` yields a new spec, so the registry copy
        # this run was handed stays untouched for anything that reads it afterwards.
        if params:
            spec = replace(spec, config=_apply_params(spec.config, params))

        source = build_source(spec)

        # Narrow BEFORE the hint check, so the check only judges resources that are
        # going to load. with_resources() returns a new source and leaves this one
        # alone; unknown names raise here, naming what is available.
        if resources:
            source = source.with_resources(*resources)

        _check_merge_keys(spec, source)

        # Pass write_disposition only when the spec actually sets one. dlt applies it
        # to EVERY resource in the source, so sending a value unconditionally would
        # overwrite per-resource dispositions and make mixed pipelines impossible.
        # Absent means "let each resource keep its own".
        run_kwargs: dict[str, Any] = {}
        if spec.write_disposition:
            run_kwargs["write_disposition"] = spec.write_disposition

        info = pipeline.run(source, **run_kwargs)
        info.raise_on_failed_jobs()

        row_counts: dict[str, Any] = (
            dict(pipeline.last_trace.last_normalize_info.row_counts)
            if pipeline.last_trace
            else {}
        )

        if spec.source == "snowflake_app":
            from pipelines.batch.obs_copy_watermark import (  # noqa: PLC0415
                is_obs_copy,
                write_obs_copy_watermark,
            )

            if is_obs_copy(spec):
                write_obs_copy_watermark(spec, row_counts)
            else:
                from pipelines.batch.app_copy_watermark import (  # noqa: PLC0415
                    write_app_copy_watermark,
                )

                write_app_copy_watermark(spec, row_counts)

        pipeline_log.info("load complete: %s", info)
        if row_counts:
            pipeline_log.info("row counts: %s", row_counts)

        load_id: str | None = info.loads_ids[0] if info.loads_ids else None
        record_run(
            spec,
            status="ok",
            load_id=load_id,
            row_counts=row_counts,
            resources=resources,
            params=params,
        )

    except Exception as exc:
        # A preflight failure is recorded like any other, so a run that never started
        # is still visible in _DLT_RUNS rather than leaving a silent gap.
        record_run(
            spec,
            status="failed",
            load_id=None,
            row_counts=None,
            error=str(exc),
            resources=resources,
            params=params,
        )
        raise


# ---------------------------------------------------------------------------
# 5. Registry selection
#
# The same selection semantics over two different backends, so a pipeline behaves
# identically whether its spec came from YAML on a laptop or the registry table in
# a container.
# ---------------------------------------------------------------------------


def _registry_mode() -> str:
    """Return 'table' or 'yaml' based on DLT_REGISTRY_SOURCE (default: auto).

    In 'auto' mode the table wins when running inside SPCS (session token
    mounted) and YAML is used everywhere else.
    """
    mode = os.environ.get("DLT_REGISTRY_SOURCE", "auto").lower()
    if mode == "auto":
        from pipelines.common.snowflake_session import in_spcs  # noqa: PLC0415

        return "table" if in_spcs() else "yaml"
    if mode not in ("table", "yaml"):
        raise ValueError(
            f"DLT_REGISTRY_SOURCE must be auto|table|yaml, got '{mode}'"
        )
    return mode


def resolve_specs(args: argparse.Namespace) -> list[PipelineSpec]:
    """Return the specs selected by *args*, reading from the table or YAML.

    Selection semantics are identical across both backends:
      --all / --list -> every (enabled) pipeline
      --group G      -> every (enabled) pipeline in group G
      <name>         -> the single pipeline named <name>
    """
    mode = _registry_mode()
    log.info("resolving pipeline specs from %s", mode)

    if mode == "table":
        from pipelines.batch import registry_store  # noqa: PLC0415

        if args.all or args.list:
            return registry_store.get_all()
        if args.group:
            return registry_store.get_by_group(args.group)
        return [registry_store.get_spec(args.name)]

    registry = load_registry()
    if args.all or args.list:
        return registry.pipelines
    if args.group:
        return registry.by_group(args.group)
    return [registry.get(args.name)]


# ---------------------------------------------------------------------------
# 6. CLI
#
# Exit code 0 only when every selected pipeline succeeded.
# ---------------------------------------------------------------------------


def _parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="pipelines.batch.run",
        description="Run dlt pipelines registered in pipelines/batch/registries/.",
    )
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("name", nargs="?", help="name of the pipeline to run")
    group.add_argument("--group", metavar="G", help="run every pipeline in group G")
    group.add_argument("--all", action="store_true", help="run every pipeline sequentially")
    group.add_argument("--list", action="store_true", help="print the registry and exit")
    parser.add_argument(
        "--resource",
        action="append",
        metavar="R",
        help="run only this resource of the named pipeline (repeat for several)",
    )
    parser.add_argument(
        "--param",
        action="append",
        metavar="[RES:]K=V",
        help=(
            "override a query parameter. Unqualified it applies to the selected "
            "resource; RESOURCE:KEY=VALUE names its target (repeat for several)"
        ),
    )
    args = parser.parse_args(argv)

    # A resource filter only means something against one known source. Applied across
    # --group or --all it would demand that every pipeline declare that resource, and
    # fail on the first that does not.
    if args.resource and not args.name:
        parser.error("--resource applies to a single pipeline: pass a pipeline name with it")

    if args.param and not args.name:
        parser.error("--param applies to a single pipeline: pass a pipeline name with it")

    # An UNQUALIFIED param has to be bound to something, and the only unambiguous
    # something is a single selected resource. With several selected there is no way to
    # say which one it belongs to, and applying it to all of them would be a guess that
    # silently changes what the others fetch. A qualified param names its own target and
    # so needs none of this.
    unqualified = [p for p in (args.param or []) if ":" not in p.partition("=")[0]]
    if unqualified and len(args.resource or []) != 1:
        parser.error(
            "an unqualified --param needs exactly one --resource so its target is clear; "
            "otherwise name it, as in --param 'games_post_ref:seasons[]=2025'"
        )

    return args


def main(argv: list[str] | None = None) -> int:
    """CLI entry point.  Returns 0 on full success, 1 if any pipeline failed."""
    logging.basicConfig(
        level=os.environ.get("LOG_LEVEL", "INFO").upper(),
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )

    args = _parse_args(sys.argv[1:] if argv is None else argv)

    # A spec the registry rejects (or a registry that cannot be read) raises HERE,
    # before any pipeline exists to be recorded: _DLT_RUNS never sees this class of
    # death, which is exactly why it gets its own alert scope. Only the resolution
    # is wrapped -- everything after either handles its own failures per spec or
    # returns a usage error that no Task can produce.
    try:
        specs = resolve_specs(args)
    except Exception as exc:
        alerts.report("runner", ok=False, error=str(exc))
        raise

    if args.list:
        for p in specs:
            print(
                f"{p.name:<24} source={p.source:<14} "
                f"schedule={str(p.schedule):<18} group={p.group}"
            )
        return 0

    if args.group and not specs:
        log.error("no pipelines in group '%s'", args.group)
        return 1

    # Parsed once, up front: a malformed --param should be a usage error before any
    # pipeline starts, not a failure recorded halfway through a batch. Unqualified
    # params are bound here to the one selected resource, so run_pipeline only ever
    # sees real resource names.
    params: dict[str, Any] | None = None
    if args.param:
        if specs and specs[0].source != "rest_api":
            log.error(
                "--param applies to rest_api pipelines; '%s' is a '%s' source",
                specs[0].name,
                specs[0].source,
            )
            return 1
        try:
            parsed = _parse_params(args.param)
        except ValueError as exc:
            log.error("%s", exc)
            return 1
        default = (args.resource or [None])[0]
        params = {(name or default): values for name, values in parsed.items()}

    failures = 0
    for spec in specs:
        try:
            run_pipeline(spec, resources=args.resource, params=params)
        except Exception as exc:  # noqa: BLE001, one bad pipeline must not kill the batch
            log.exception("pipeline '%s' failed", spec.name)
            failures += 1
            alerts.report(spec.name, ok=False, error=str(exc))
        else:
            # The success side is what turns a red scope green again: without it
            # a recovered pipeline would stay 'failing' in ALERT_STATE forever
            # and the recovery ping would never fire.
            alerts.report(spec.name, ok=True)

    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
