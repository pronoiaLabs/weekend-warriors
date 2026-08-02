"""Typed model and loader for the pipeline registry.

WHY THIS EXISTS
    A pipeline is data, not code. One image runs every pipeline, and what makes them
    differ is a registry entry. This module is the single definition of what such an
    entry may contain and what makes it valid, so the runner and the task generator
    agree without either owning the rules.

    It has one hard constraint: **no execution dependencies, ever.** It must not
    import dlt or the Snowflake connector. `deploy/tasks/generate_tasks.py` imports it
    to emit DDL in CI, where neither is installed. That constraint is why checks
    needing dlt (resolving secrets, inspecting resource hints) live in `run.py`
    instead.

CONTENTS
    1. Registry shape ......... SUPPORTED_SOURCES, RegistryError, PipelineSpec
    2. Collection ............. Registry
    3. Table rows ............. spec_from_row
    4. YAML loading ........... load_registry
    5. Name resolution ........ ENVIRONMENTS, resolve_database, current_season, CLI

A PIPELINE DECLARES A SPORT, NOT A DATABASE
    `database` holds a stem (`NFL`, `DLT`), and resolve_database() composes the full
    name as `<stem>_<env>_DB`. One entry therefore describes both `NFL_DEV_DB` and
    `NFL_PROD_DB` without the registry having to know which environment is running.

    The alternative, naming the database outright at the call site, works until a
    stale export sends one sport's data into another sport's database. Deriving it
    from the pipeline makes that unrepresentable.

TWO BACKENDS, ONE SHAPE
    The same spec arrives from two places and must mean the same thing in both:
        registries/*.yml              local dev, parsed by load_registry
        DLT_DB.OPS.PIPELINE_REGISTRY  in SPCS, one row per pipeline, via spec_from_row
    Anything accepted by one and rejected by the other is a bug that only shows up in
    a container.

ONE REGISTRY, SEVERAL FILES
    `registries/` holds one file per source (nfl-registry.yml, sample-registry.yml, and
    whatever comes next). They are MERGED, not selected between: every consumer still
    sees a single collection, so --all, --group and the task generator need to know
    nothing about the split. Pipeline names must therefore be unique across the whole
    directory, not just within a file.
"""

from __future__ import annotations

import copy
import json
from dataclasses import dataclass, field
from datetime import date, datetime, timezone
from pathlib import Path
from typing import Any

import yaml

# ---------------------------------------------------------------------------
# 1. Registry shape
# ---------------------------------------------------------------------------

# Sources the runner knows how to build. Extend build_source() in run.py to add more.
SUPPORTED_SOURCES: tuple[str, ...] = ("rest_api", "sample")

# Dispositions dlt accepts as a plain string. `skip` is deliberately absent: a
# pipeline that loads nothing should not be in the registry.
_DISPOSITIONS: tuple[str, ...] = ("append", "replace", "merge")

# Resolved relative to this file so the loader works from any working directory.
REGISTRY_PATH: Path = Path(__file__).with_name("registries")


class RegistryError(ValueError):
    """Raised when a registry entry is missing required fields or is malformed."""


@dataclass
class PipelineSpec:
    """Fully-resolved, validated configuration for a single pipeline.

    On `write_disposition`, which is the field with real semantics:

        None                                        no pipeline-level override. Every
                                                    resource keeps whatever disposition
                                                    it declares for itself.
        "replace"                                   an override applied to EVERY
                                                    resource in the source.
        {"disposition": "merge", "strategy": "scd2"} the same, in dict form. This is how
                                                    merge strategies are selected.

    The override is blunt on purpose: dlt applies a `write_disposition` passed to
    `pipeline.run()` across the whole source. That is genuinely useful (`nfl_reference`
    uses it to replace a small reference table wholesale), but it must be possible to
    decline. Hence the default is None, not a disposition, so mixed-disposition
    pipelines are expressible.
    """

    name: str
    source: str
    config: dict[str, Any]
    schedule: str | None = None
    # Database STEM, not a full name: `NFL` resolves to NFL_DEV_DB / NFL_PROD_DB via
    # resolve_database(). `DLT` is the default so a pipeline that declares no sport
    # lands in the shared DLT_DEV_DB / DLT_PROD_DB, which is where `sample` belongs.
    database: str = "DLT"
    dataset_name: str = "RAW"
    write_disposition: str | dict[str, Any] | None = None
    destination: str = "snowflake"
    load_warehouse: str = "DLT_WH"
    compute_pool: str = "DLT_POOL"
    group: str | None = None

    # Scheduled-run bindings. Unused by a local or dev run, which take them from the
    # command line, but a Snowflake Task has no command line: whatever a container
    # needs at 09:00 UTC has to be recorded here or the Task cannot supply it.
    #
    #   secret          fully-qualified Snowflake SECRET, e.g. DLT_DB.OPS.NFL_API_KEY
    #   env_var         the dlt env var it binds to, e.g. SOURCES__NFL__API_KEY
    #   external_access  the EAI granting egress, e.g. NFL_API_EAI
    #
    # They are optional because `sample` needs none of them. validate() requires them
    # once a `schedule` is present, since that is exactly when nobody is watching.
    secret: str | None = None
    env_var: str | None = None
    external_access: str | None = None

    def validate(self) -> None:
        """Raise RegistryError on anything structurally wrong.

        Structure only. Whether a merge has a key, or a secret resolves, cannot be
        answered here: both need dlt, and this module stays import-free. `run.py`
        checks those before a load starts.
        """
        if not self.name:
            raise RegistryError("a pipeline entry is missing `name`")
        if self.source not in SUPPORTED_SOURCES:
            raise RegistryError(
                f"pipeline '{self.name}': source '{self.source}' is not supported "
                f"(expected one of {', '.join(SUPPORTED_SOURCES)})"
            )
        if not isinstance(self.config, dict) or not self.config:
            raise RegistryError(
                f"pipeline '{self.name}': `config` must be a non-empty mapping"
            )
        self._validate_database()
        self._validate_schedule_bindings()
        self._validate_write_disposition()

    def _validate_schedule_bindings(self) -> None:
        """A scheduled pipeline must carry everything a Task cannot supply.

        A Task passes no arguments and nobody is watching when it fires. A missing
        `secret` means the container raises KeyError from dlt.secrets; a missing
        `external_access` means it has no network at all. Both surface as a red Task
        at 09:00 UTC rather than as an error anyone reads.

        Only enforced when `schedule` is set, because an unscheduled pipeline gets its
        bindings from the command line and `sample` needs none of them at all.
        """
        if not self.schedule:
            return

        missing = [
            field_name
            for field_name in ("secret", "env_var", "external_access")
            if not getattr(self, field_name)
        ]
        if missing:
            raise RegistryError(
                f"pipeline '{self.name}': has a schedule but does not declare "
                f"{', '.join(missing)}. A Snowflake Task passes no arguments, so a "
                "scheduled pipeline must record its secret, the env var that secret "
                "binds to, and its external access integration in the registry."
            )

    def _validate_database(self) -> None:
        """The stem must be a bare identifier, since it is interpolated into DDL.

        Checked here rather than trusted because the value reaches Snowflake through
        string interpolation in the Task DDL and the job spec's USING clause, neither
        of which is parameterised.
        """
        stem = self.database
        if not stem or not stem.replace("_", "").isalnum() or stem[0].isdigit():
            raise RegistryError(
                f"pipeline '{self.name}': `database` must be a bare identifier stem "
                f"like 'NFL' (letters, digits and underscores, not starting with a "
                f"digit), got {stem!r}"
            )

    def _validate_write_disposition(self) -> None:
        """Accept None, a known disposition string, or the {disposition, strategy} dict."""
        wd = self.write_disposition

        # None is the default and means "no override"; nothing to check.
        if wd is None:
            return

        if isinstance(wd, str):
            if wd not in _DISPOSITIONS:
                raise RegistryError(
                    f"pipeline '{self.name}': write_disposition must be "
                    f"{'|'.join(_DISPOSITIONS)}, got '{wd}'"
                )
            return

        if isinstance(wd, dict):
            disposition = wd.get("disposition")
            if disposition not in _DISPOSITIONS:
                raise RegistryError(
                    f"pipeline '{self.name}': write_disposition dict needs a `disposition` "
                    f"of {'|'.join(_DISPOSITIONS)}, got {disposition!r}"
                )
            # `strategy` is passed through to dlt rather than enumerated here. dlt owns
            # that list (delete-insert, upsert, scd2, ...) and it grows between
            # versions; duplicating it would mean rejecting valid configs after an
            # upgrade.
            return

        raise RegistryError(
            f"pipeline '{self.name}': write_disposition must be a string, a mapping, "
            f"or absent, got {type(wd).__name__}"
        )


# ---------------------------------------------------------------------------
# 2. Collection
# ---------------------------------------------------------------------------


@dataclass
class Registry:
    """In-memory view of the entire pipeline registry."""

    pipelines: list[PipelineSpec] = field(default_factory=list)

    def get(self, name: str) -> PipelineSpec:
        """Return the spec for *name*; raise RegistryError if not found."""
        for p in self.pipelines:
            if p.name == name:
                return p
        raise RegistryError(f"no pipeline named '{name}' in the registry")

    def by_group(self, group: str) -> list[PipelineSpec]:
        """Return all pipelines belonging to *group* (empty list if none)."""
        return [p for p in self.pipelines if p.group == group]


# ---------------------------------------------------------------------------
# 3. Table rows
#
# The in-Snowflake path. Kept Snowflake-free on purpose: registry_store does the
# querying and hands over a plain dict, so this stays testable without a connection.
# ---------------------------------------------------------------------------


def _maybe_json(value: Any) -> Any:
    """Decode a VARIANT that arrived as a JSON string.

    The connector returns VARIANT columns as their JSON text, so `"replace"` comes
    back as the six-character string `"replace"` (quotes included) and an object comes
    back as `{"disposition": ...}`. Both need decoding before use, or a quoted string
    reaches validation and is rejected for no visible reason.

    Values that are already native (dicts from a parsed VARIANT, plain strings from a
    STRING column) pass through untouched, which keeps this safe against an account
    whose table predates the VARIANT column.
    """
    if not isinstance(value, str):
        return value
    text = value.strip()
    if not text:
        return None
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        # Not JSON, so it is a bare STRING column value from an unmigrated table.
        return value


def spec_from_row(row: dict[str, Any]) -> PipelineSpec:
    """Build a validated PipelineSpec from an OPS.PIPELINE_REGISTRY row.

    Callers (registry_store) hand in a plain dict of column name -> value. Two columns
    are renamed because their natural names collide with SQL keywords:
    `pipeline_group` maps to `group` and `target_database` maps to `database`. Every
    other name matches.
    """
    config: Any = _maybe_json(row.get("config")) or {}

    defaults = PipelineSpec.__dataclass_fields__

    def pick(col: str, field_name: str) -> Any:
        # Use the row value when present and non-null, else the dataclass default.
        val = row.get(col)
        return val if val is not None else defaults[field_name].default

    spec = PipelineSpec(
        name=row.get("name") or "",
        source=row.get("source") or "",
        config=config,
        schedule=row.get("schedule"),
        database=pick("target_database", "database"),
        dataset_name=pick("dataset_name", "dataset_name"),
        # NULL here is meaningful (no override), so it must survive as None rather
        # than being replaced by a default.
        write_disposition=_maybe_json(row.get("write_disposition")),
        destination=pick("destination", "destination"),
        load_warehouse=pick("load_warehouse", "load_warehouse"),
        compute_pool=pick("compute_pool", "compute_pool"),
        group=row.get("pipeline_group"),
        secret=row.get("secret"),
        env_var=row.get("env_var"),
        external_access=row.get("external_access"),
    )
    spec.validate()
    return spec


# ---------------------------------------------------------------------------
# 4. YAML loading
#
# The local-dev path. `defaults:` is merged into every entry before validation, so a
# value set there behaves exactly as if it had been typed into each pipeline. It is
# per file, which is what lets a source's registry stand alone.
#
# Files are read in sorted filename order. That ordering is load-bearing rather than
# cosmetic: registry_sync.emit_sql writes a SQL script from this collection, and an
# unstable order means a meaningless diff on every regeneration.
#
# `seen` maps a pipeline name to the file that defined it, so a duplicate can name
# BOTH files. A collision is now cross-file, and an error naming only one of them sends
# you looking through the wrong place.
# ---------------------------------------------------------------------------


def _load_file(path: Path, seen: dict[str, Path]) -> list[PipelineSpec]:
    """Parse one registry file into validated specs, tracking names in *seen*."""
    raw: dict[str, Any] = yaml.safe_load(path.read_text()) or {}
    defaults: dict[str, Any] = raw.get("defaults") or {}
    entries: list[dict[str, Any]] = raw.get("pipelines") or []

    if not entries:
        raise RegistryError(f"{path.name} has no `pipelines` entries")

    # Field names the dataclass accepts (excluding `config` which is handled separately)
    known: set[str] = {f for f in PipelineSpec.__dataclass_fields__ if f != "config"}

    specs: list[PipelineSpec] = []

    for entry in entries:
        # deepcopy so a nested default is not shared (and later mutated) across entries.
        merged: dict[str, Any] = copy.deepcopy(defaults)
        merged.update(entry)

        # Only pass known scalar fields to the constructor; keep `config` aside.
        kwargs: dict[str, Any] = {k: v for k, v in merged.items() if k in known}
        spec = PipelineSpec(config=merged.get("config") or {}, **kwargs)
        spec.validate()

        if spec.name in seen:
            raise RegistryError(
                f"duplicate pipeline name '{spec.name}': defined in "
                f"{seen[spec.name].name} and again in {path.name}"
            )
        seen[spec.name] = path
        specs.append(spec)

    return specs


def load_registry(path: Path | str = REGISTRY_PATH) -> Registry:
    """Load the registry from a directory of YAML files, or from a single file.

    A directory reads every `*.yml` inside it in sorted filename order and merges the
    result into one Registry. A file reads just that file, which is what tests and
    one-off tooling use.

    Raises RegistryError on any structural or validation problem so callers get a
    clear message rather than a raw KeyError / AttributeError.
    """
    path = Path(path)
    if not path.exists():
        raise RegistryError(f"registry path not found: {path}")

    files: list[Path] = sorted(path.glob("*.yml")) if path.is_dir() else [path]
    if not files:
        raise RegistryError(f"no *.yml registry files in {path}")

    specs: list[PipelineSpec] = []
    seen: dict[str, Path] = {}
    for file in files:
        specs.extend(_load_file(file, seen))

    return Registry(pipelines=specs)


# ---------------------------------------------------------------------------
# 5. Name resolution
#
# One function and a one-line CLI, so that "which database does this pipeline load
# into" has exactly one answer no matter who is asking. Three callers need it and
# none of them can share code any other way:
#
#     Makefile run-spcs        builds the USING clause at submission time
#     Makefile run-snowflake   sets the destination env var for a laptop run
#     generate_tasks.py        emits the prod Task DDL, in CI, with no dlt installed
#
# That last one is why this lives here rather than in run.py: this module is
# import-free by design, and the task generator depends on that.
# ---------------------------------------------------------------------------

# Environments a database name can be composed for. Deliberately closed: an unknown
# value would compose a plausible-looking database that does not exist, and the load
# would fail somewhere much further along than the typo.
ENVIRONMENTS: tuple[str, ...] = ("DEV", "PROD")


def resolve_database(spec: PipelineSpec, env: str) -> str:
    """Return the full database name for *spec* in *env*, e.g. NFL + DEV -> NFL_DEV_DB."""
    key = (env or "").strip().upper()
    if key not in ENVIRONMENTS:
        raise RegistryError(
            f"unknown environment {env!r}: expected one of {', '.join(ENVIRONMENTS)}"
        )
    return f"{spec.database}_{key}_DB"


# The month an NFL season starts owning the calendar. Preseason opens in early August,
# so from 1 August the current season is that year's.
_SEASON_ROLLOVER_MONTH = 8


def current_season(today: date | None = None) -> int:
    """Return the NFL season year in progress on *today* (defaults to now, UTC).

    A season is named for the year it kicks off in, and it runs into February. So the
    rule is not "this calendar year": January 2027 is still the 2026 season, and so is
    the whole 2027 offseason until preseason opens again.

        31 Jul 2026 -> 2025      1 Aug 2026 -> 2026
        10 Jan 2027 -> 2026      1 Aug 2027 -> 2027

    Rolling over on 1 August rather than at the Super Bowl means the offseason keeps
    pointing at the last COMPLETED season, which is the one that still has data. A
    rollover in February would make every scheduled load ask for a season that has not
    been played, and the API answers that with an empty list rather than an error.

    *today* is injectable so tests do not depend on the clock.
    """
    day = today or datetime.now(timezone.utc).date()
    return day.year if day.month >= _SEASON_ROLLOVER_MONTH else day.year - 1


def _main(argv: list[str] | None = None) -> int:
    """Print one resolved value for one pipeline. Used by the Makefile.

    Exactly one value on stdout and nothing else, because the Makefile captures it
    into a shell variable and interpolates it straight into SQL. Any decoration, even
    a label, would end up inside the query.
    """
    import argparse  # noqa: PLC0415 -- CLI-only, keeps the import path clean

    parser = argparse.ArgumentParser(
        prog="python -m pipelines.batch.models",
        description=(
            "Resolve one registry-derived value for a pipeline: its database, its "
            "Snowflake SECRET, the env var that secret binds to, or its external "
            "access integration."
        ),
    )
    what = parser.add_mutually_exclusive_group(required=True)
    what.add_argument(
        "--database",
        metavar="PIPELINE",
        help="print the database the pipeline loads into (needs --env)",
    )
    what.add_argument(
        "--secret",
        metavar="PIPELINE",
        help="print the fully-qualified Snowflake SECRET the pipeline binds",
    )
    what.add_argument(
        "--env-var",
        metavar="PIPELINE",
        help="print the dlt env var that secret binds to",
    )
    what.add_argument(
        "--external-access",
        metavar="PIPELINE",
        help="print the external access integration granting egress",
    )
    what.add_argument(
        "--current-season",
        action="store_true",
        help="print the NFL season year in progress today",
    )
    parser.add_argument(
        "--env",
        choices=ENVIRONMENTS,
        help="environment, required with --database",
    )
    args = parser.parse_args(argv)

    if args.current_season:
        print(current_season())
        return 0

    if args.database:
        if not args.env:
            parser.error("--database requires --env")
        print(resolve_database(load_registry().get(args.database), args.env))
        return 0

    name = args.secret or args.env_var or args.external_access
    if args.secret:
        field_name = "secret"
    elif args.env_var:
        field_name = "env_var"
    else:
        field_name = "external_access"
    value = getattr(load_registry().get(name), field_name)
    if not value:
        # Empty stdout would be interpolated as a blank into SQL. Fail instead.
        raise RegistryError(f"pipeline '{name}' declares no `{field_name}`")
    print(value)
    return 0


if __name__ == "__main__":
    raise SystemExit(_main())
