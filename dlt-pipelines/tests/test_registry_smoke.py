"""Smoke tests for the pipeline registry. No Snowflake, no network required.

Covers registry parsing and validation, plus one end-to-end run of the credential-free
`sample` source into DuckDB. That last test is the only one that executes a pipeline,
so it is what proves the runner actually works rather than merely parses.
"""
from __future__ import annotations

import sys
from copy import deepcopy
from pathlib import Path
from textwrap import dedent

import pytest

# Ensure `import pipelines.*` works when pytest is run from the repo root
# without the package installed in the active environment.
_ROOT = Path(__file__).parent.parent.resolve()
if str(_ROOT) not in sys.path:
    sys.path.insert(0, str(_ROOT))

# Guard: skip the entire module when the core runtime deps are absent.
pytest.importorskip("dlt")
pytest.importorskip("duckdb")

import dlt  # noqa: E402  (must follow importorskip)

from pipelines.batch.models import (  # noqa: E402
    SUPPORTED_SOURCES,
    PipelineSpec,
    RegistryError,
    load_registry,
)


# ---------------------------------------------------------------------------
# Registry unit tests (pure Python, no I/O beyond reading registries/*.yml)
# ---------------------------------------------------------------------------


def test_registry_loads_and_validates() -> None:
    registry = load_registry()
    assert len(registry.pipelines) >= 1, "registry must contain at least one pipeline"

    for spec in registry.pipelines:
        # Import the tuple rather than duplicating it, so adding a source type
        # is a one-place change.
        assert spec.source in SUPPORTED_SOURCES, (
            f"unsupported source '{spec.source}' in pipeline '{spec.name}'"
        )
        assert isinstance(spec.config, dict) and spec.config, (
            f"pipeline '{spec.name}' has an empty config"
        )

    names = [spec.name for spec in registry.pipelines]
    assert len(names) == len(set(names)), "pipeline names must be unique"

    sample = registry.get("sample")
    assert sample.dataset_name and isinstance(sample.dataset_name, str), (
        "sample.dataset_name must be a non-empty string"
    )


def _registry_text(*names: str) -> str:
    """A minimal valid registry file declaring one rest_api pipeline per name."""
    entries = "".join(
        dedent(f"""\
              - name: {name}
                source: rest_api
                config:
                  client:
                    base_url: "https://example.com/"
                  resources:
                    - name: things
        """)
        for name in names
    )
    return dedent("""\
        defaults:
          destination: snowflake
          dataset_name: RAW
          write_disposition: merge
          load_warehouse: DLT_WH
          compute_pool: DLT_POOL

        pipelines:
    """) + entries


def test_duplicate_names_rejected(tmp_path: Path) -> None:
    registry_file = tmp_path / "one-registry.yml"
    registry_file.write_text(_registry_text("duplicate", "duplicate"))

    with pytest.raises(RegistryError, match="duplicate"):
        load_registry(registry_file)


def test_directory_merges_every_file(tmp_path: Path) -> None:
    # Deliberately written out of alphabetical order: files load sorted by name, so
    # `a-registry.yml` must come first regardless of creation order.
    (tmp_path / "z-registry.yml").write_text(_registry_text("zulu"))
    (tmp_path / "a-registry.yml").write_text(_registry_text("alpha", "bravo"))

    registry = load_registry(tmp_path)

    assert [p.name for p in registry.pipelines] == ["alpha", "bravo", "zulu"]


def test_duplicate_names_across_files_name_both_files(tmp_path: Path) -> None:
    # The whole point of splitting the registry: a collision is now between two files,
    # and an error naming only one of them sends you searching the wrong place.
    (tmp_path / "a-registry.yml").write_text(_registry_text("clash"))
    (tmp_path / "b-registry.yml").write_text(_registry_text("clash"))

    with pytest.raises(RegistryError) as excinfo:
        load_registry(tmp_path)

    message = str(excinfo.value)
    assert "a-registry.yml" in message and "b-registry.yml" in message


def test_empty_directory_rejected(tmp_path: Path) -> None:
    with pytest.raises(RegistryError, match="no \\*.yml registry files"):
        load_registry(tmp_path)


def test_missing_pipelines_key_names_the_file(tmp_path: Path) -> None:
    # With several files, "the registry is empty" is useless without a filename.
    (tmp_path / "broken-registry.yml").write_text("defaults:\n  destination: snowflake\n")

    with pytest.raises(RegistryError, match="broken-registry.yml"):
        load_registry(tmp_path)


def test_multi_resource_pipelines_declare_their_own_path() -> None:
    """Any resource whose name differs from its endpoint path must set `path`.

    dlt fills a missing `path` with the RESOURCE NAME before merging with
    resource_defaults, so a path set in resource_defaults is unreachable and the
    request silently goes to /<resource name>. That is a 404 at run time and nothing
    catches it earlier, which is why it is asserted here against the real registry.
    """
    from dlt.sources.rest_api.config_setup import (  # noqa: PLC0415
        expand_and_index_resources,
    )

    for spec in load_registry().pipelines:
        if spec.source != "rest_api":
            continue
        config = deepcopy(spec.config)
        resolved = expand_and_index_resources(
            config["resources"], config.get("resource_defaults") or {}
        )
        for name, resource in resolved.items():
            declared = resource["endpoint"].get("path")
            assert declared, f"{spec.name}.{name} resolved to no endpoint path"
            # Resources sharing a table (games_pre / games_regular / games_post) have
            # names that are deliberately not the path, so the path must be explicit.
            if resource.get("table_name") and resource["table_name"] != name:
                assert declared != name, (
                    f"{spec.name}.{name} inherited its path from its own name; "
                    "set `path` on the resource"
                )


def test_scd2_resources_are_not_flagged_for_missing_keys() -> None:
    """scd2 needs no key, and the preflight must recognise that.

    dlt resolves a resource-level strategy onto the table schema as `x-merge-strategy`
    and leaves `write_disposition` a bare "merge". Reading only the dict form makes an
    scd2 resource look like a keyless merge, and the run is refused for a problem it
    does not have.
    """
    from pipelines.batch.run import _check_merge_keys, build_source  # noqa: PLC0415

    registry = load_registry()
    scd2 = [
        spec
        for spec in registry.pipelines
        if spec.source == "rest_api"
        and any(
            isinstance(r, dict)
            and isinstance(r.get("write_disposition"), dict)
            and r["write_disposition"].get("strategy") == "scd2"
            for r in (spec.config.get("resources") or [])
        )
    ]
    assert scd2, "expected at least one scd2 pipeline in the registry"

    for spec in scd2:
        source = build_source(spec)
        _check_merge_keys(spec, source)  # must not raise


def test_keyless_merge_is_still_rejected() -> None:
    # The other half: relaxing the check for scd2 must not relax it for everything.
    from pipelines.batch.run import _check_merge_keys, build_source  # noqa: PLC0415

    spec = PipelineSpec(
        name="keyless",
        source="rest_api",
        config={
            "client": {"base_url": "https://example.test/"},
            "resources": [
                {
                    "name": "thing",
                    "write_disposition": "merge",
                    "endpoint": {"path": "thing", "data_selector": "data"},
                }
            ],
        },
    )
    with pytest.raises(RuntimeError, match="no primary_key or merge_key"):
        _check_merge_keys(spec, build_source(spec))


# ---------------------------------------------------------------------------
# End-to-end smoke: in-code sample source -> duckdb destination
#
# The `sample` source needs no credentials and no network, so this exercises
# run_pipeline() (destination override, load, row-count extraction, record_run)
# on any machine with the dev extra installed.
# ---------------------------------------------------------------------------


def test_sample_smoke_to_duckdb(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    # Redirect all dlt pipeline state + duckdb output into tmp_path so tests
    # are fully isolated even when run in parallel.
    monkeypatch.chdir(tmp_path)
    monkeypatch.setenv("DLT_DATA_DIR", str(tmp_path))
    # Ensure run_pipeline() (and any dlt-internal collector) targets duckdb, not Snowflake.
    monkeypatch.setenv("DLT_DESTINATION", "duckdb")
    monkeypatch.delenv("DLT_DATASET", raising=False)

    # ── Build the spec directly (bypasses registry.yml for isolation) ─────────
    spec = PipelineSpec(
        name="smoke_sample",
        source="sample",
        config={"n_customers": 5, "n_orders": 5},
        dataset_name="raw_smoke",
        write_disposition="append",
    )

    # ── Run the pipeline ──────────────────────────────────────────────────────
    from pipelines.batch.run import run_pipeline  # noqa: PLC0415

    run_pipeline(spec)

    # ── Assert both resources landed in duckdb ───────────────────────────────
    # Re-attach to the same pipeline; DLT_DATA_DIR is still set to tmp_path so
    # dlt restores state from disk and opens the same .duckdb file.
    pipeline = dlt.pipeline(
        pipeline_name=spec.name,
        destination="duckdb",
        dataset_name=spec.dataset_name,
    )
    with pipeline.sql_client() as c:
        customers = c.execute_sql("SELECT COUNT(*) FROM customers")
        orders = c.execute_sql("SELECT COUNT(*) FROM orders")
    assert customers[0][0] == 5, f"expected 5 customers, got {customers[0][0]}"
    assert orders[0][0] == 5, f"expected 5 orders, got {orders[0][0]}"
