# AGENTS.md

Notes for agents and developers working in this template. This is a record of what has been
**verified by running it**, not a restatement of the README. Its purpose is to stop the next
person rediscovering the same things, and to push design toward what dlt already offers before
anyone reaches for custom Python.

Each entry is marked:

- **VERIFIED** means someone executed it and observed the result. The observation is quoted.
- **READ** means it comes from source or vendored docs, with a file reference, but was not run.

When you verify something new, add it here with how you verified it.

---

## Guiding principle: declarative before custom

The registry is deliberately declarative, and dlt's REST config covers far more than it first
appears. Before adding Python, check whether the config already expresses it. The list of things
that genuinely require custom code is short (see [What actually needs Python](#what-actually-needs-python)),
and at least one design was nearly written as a custom source before turning out to be four lines
of YAML.

---

## Verified capabilities

### Parent-child fan-out is native

**VERIFIED.** A child resource can take a parameter from a parent resource's rows, so endpoints
that require an id you do not know up front do not need custom iteration.

**There are two syntaxes and they are not interchangeable.**

Query parameter: inline string placeholder.

```yaml
- name: plays
  endpoint:
    path: plays
    params:
      game_id: "{resources.games.id}"
```

Path parameter: the `type: resolve` dict form, or the same placeholder inline in the path.

```yaml
- name: roster
  endpoint:
    path: "teams/{resources.teams.id}/roster"
```

Using the `resolve` dict for a parameter that does not appear in the path raises at config-build
time, before any request is made:

```
ValueError: Resource `plays` defines resolve params `['game_id']` that are not bound in
path `plays`. To reference parent resource in query params use syntax
'resources.<parent_resource>.<field>'
```

`include_from_parent: ["id"]` copies parent fields onto child rows, prefixed `_<parent>_<field>`
(for example `_games_id`). Docs: `.docs/rest-api-basic.md:663-930`.

### An incremental parent scopes the child for free

**VERIFIED**, and this is the most useful finding in this file.

The child fans out over what the parent **yields in that run**, not over everything the parent has
ever seen. So making the parent incremental turns an expensive full fan-out into a cheap delta,
with no custom code.

Test: parent `games` incremental on `date`, child `plays` resolving `game_id`, same config run
twice against a single game.

```
run 1: games=  1  plays= 197
run 2: games=  0  plays=   0
watermark after run 2: 2025-09-07T17:00:00.000Z
```

On the second run the parent's watermark had advanced, it yielded nothing, and the child issued no
requests at all.

The trade-off to be aware of: rows behind the watermark are never re-fetched. If the upstream
revises historical records, pair the incremental run with a periodic wider sweep.

**How this was verified** (repeat this pattern for future claims):

```bash
uv sync --extra dev
uv run --extra dev python your_probe.py   # destination="duckdb", run twice
# read pipeline.last_trace.last_normalize_info.row_counts after each run
```

`.venv/` and `*.duckdb` are already gitignored.

### Keys are optional

**READ**, from [`.docs/dlt-write-dispositions.md`](.docs/dlt-write-dispositions.md).

A common wrong assumption is that `merge` requires `primary_key`. It does not:

| Disposition / strategy | Key required |
|---|---|
| `append` | none |
| `replace` | none |
| `merge` / `delete-insert` | `primary_key` **and/or** `merge_key`, either alone is enough |
| `merge` / `upsert` | `primary_key` required |
| `merge` / `insert-only` | `primary_key` required |
| `merge` / `scd2` | **none.** Hashes row content into `_dlt_id` |

`merge` with no keys does not raise. It degrades to `append`, so rows accumulate. That looks like
duplication downstream but the mechanism and the fix are different.

`scd2` is the answer for a source with no natural key. Note that with `merge_key` unset it assumes
every run is a full extract and **retires any row not present in it**, which will wipe history if
paired with an incremental extract. Set `merge_key` to a partition column.

### Lineage columns you get without declaring anything

**READ**, from [`.docs/dlt-write-dispositions.md`](.docs/dlt-write-dispositions.md).

`_dlt_load_id` on every row, `_dlt_loads` with one row per load and an `inserted_at`,
`_dlt_pipeline_state` for incremental state. Enough to resolve last-write-wins downstream without
declaring a key:

```sql
select s.*, l.inserted_at as loaded_at
from raw.some_table s
join raw._dlt_loads l on s._dlt_load_id = l.load_id
qualify row_number() over (partition by <business cols> order by l.inserted_at desc) = 1
```

**Do not dedupe on `_dlt_id`.** It is a content hash only under `merge` and `scd2`. Under `append`
it is non-deterministic, so the same source row loaded twice gets two different values.

### 429 and retry handling is already there

**READ**, `.docs/rest-api-advanced.md:1006-1016, 1033-1039`.

dlt's request client retries 5xx and 429 with exponential backoff and honours `Retry-After`.
Defaults are 5 attempts, backoff factor 1, 60s timeout. Tune without code:

```toml
[runtime]
request_max_attempts = 10
request_backoff_factor = 1.5
request_max_retry_delay = 30
```

These also work as `RUNTIME__*` env vars, which is the better lever in SPCS since `.dlt/config.toml`
is baked into the image at `deploy/spcs/Dockerfile:45`.

---

## What actually needs Python

The registry `config` is YAML serialized into a Snowflake VARIANT column
(`sql/base/03_registry.sql:37`, serialized at `registry_sync.py:92`). **Callables cannot survive
that round-trip.** So these, and only these, require a custom source type:

- Response hooks, for example capturing rate-limit headers into observability
- `processing_steps` (`map` / `filter`), for computed or anonymized columns
- A custom `requests.Client` session with a bespoke retry predicate

Fan-out, call chaining, incremental scoping, auth, and pagination are all declarative. Do not write
a custom source for those.

Two custom sources exist. Both keep the vendor-vs-content split: source type, secret
and EAI are named for the vendor; pipelines and tables are named for the content and
land in `NFL_PROD_DB.RAW`.

- `firecrawl` (`pipelines/batch/firecrawl_source.py`, registry `news-registry.yml`).
  The items of one call (a curated RSS/Atom list) decide the arguments of the next
  (a Firecrawl batch scrape), and only some pages get the 5x-cost extraction. One
  Firecrawl key serves any sport.
- `openmeteo` (`pipelines/batch/openmeteo_source.py`, registry `weather-registry.yml`).
  Open-Meteo returns columnar hourly arrays (`hourly.time[]` zipped with
  `wind_speed_10m[]`, etc.), which rest_api YAML cannot unzip. There is no API key.
  A scheduled pipeline still needs `external_access`; `secret` / `env_var` are
  required together only when the source authenticates. The prod job spec for that
  case is `dlt_job_nosecret.tmpl.yaml`, selected by `generate_tasks.render_spec`
  when `spec.secret` is empty.

---

## Template constraints worth knowing before you edit

### `write_disposition` is an optional override, applied to every resource when set

The template forced `"merge"` onto every resource. That is gone: `PipelineSpec.write_disposition`
defaults to `None` (`models.py`, see the field's docstring) and `run.py` passes it to
`pipeline.run()` only when the entry sets one. Leave it unset and each resource keeps the
disposition it declares for itself, which is how a mixed-disposition pipeline (scd2 on one table,
merge on another) is expressed. Set it, as a string or as the `{disposition: merge, strategy: scd2}`
dict, and dlt applies it to **every** resource in the source; that is still the right tool for a
small reference table you want replaced wholesale.

### `sources/` is not in the image

`deploy/spcs/Dockerfile` copies only `pyproject.toml`, `pipelines/`, and `.dlt/config.toml`, and
`pyproject.toml` scopes packages to `pipelines*`. A source module placed in a top-level `sources/`
directory would **work locally and disappear in SPCS**. The template originally shipped such a
directory; it was removed precisely because it invites that mistake. Put custom sources under
`pipelines/batch/`.

### Adding a source type is four edits

1. `pipelines/batch/models.py:19`, add the name to `SUPPORTED_SOURCES`
2. New module under `pipelines/batch/`
3. A branch in `build_source`, `run.py:67-97`, with the import **inside** the branch. Imports are
   lazy there on purpose: CI import-checks the module with a minimal dependency set, and
   `generate_tasks.py` imports `models.py` on a runner that has only pyyaml.
4. `tests/test_registry_smoke.py` asserts against `SUPPORTED_SOURCES`, imported rather than
   duplicated, so it needs no change.

If this grows past two or three custom sources, replace the if-chain in `build_source` with a dict
of `{source_name: (module_path, factory_name)}` resolved via `importlib`. Keep `models.py` free of
any `dlt` import at module level: `generate_tasks.py` imports it on a runner that has only pyyaml.

### Registry loading fails quietly

- Unknown keys are filtered out, not rejected (`models.py:144`). A typo takes the default silently.
- The `defaults:` merge is a shallow `dict.update` (`models.py:140-141`), so an entry's `config:`
  replaces the default wholesale.
- Validation covers four things only: non-empty `name`, supported `source`, non-empty `config`
  mapping, legal `write_disposition`. Cron syntax, dataset names, and the shape of `config` are
  never checked.

### The prod path is missing egress and secrets

- `deploy/tasks/generate_tasks.py:50-55` emits `EXECUTE JOB SERVICE` with no
  `EXTERNAL_ACCESS_INTEGRATIONS` clause, so a scheduled REST pipeline has no network egress.
- `deploy/spcs/dlt_job.tmpl.yaml` is the PRODUCTION spec and is no longer staged. `generate_tasks.py` renders it locally and inlines it into each Task, because Snowflake's server-side template renderer fails inside a Task (it resolves a dependency through `snowflake.snowpark.pypi_shared_repository`). It does now carry a `secrets:` block, filled from the registry's `secret` / `env_var` fields.

The Snowflake-side objects now exist: `sql/base/04_external_access.sql` creates the network rule
and integration, `sql/base/05_secrets.sql` creates the secret. They live in `base/`, not `prod/`,
because the network rule and secret sit in the `DLT_DB` control plane, the integration is an
account-level object, and **the dev path needs both before prod exists**. `setup-base` applies
`sql/base/*.sql` as a glob, so new files there need no Makefile edit (`setup-prod`, by contrast,
uses an explicit file list).

What is still missing is the wiring on the deploy side, which is the two bullets above.

The **dev** path is complete today and needs no template changes:

```bash
make run-spcs NAME=<pipeline> SECRET=DLT_DB.OPS.<SECRET> ENVVAR=SOURCES__<NAME>__TOKEN EAI=<eai>
```

### Observability writes a drifting column

`observability.py:112` puts `row_counts`, a dict with table names as keys, straight into the record.
dlt normalizes that into a child table with one column per table name it has ever seen. Serialize it
(`json.dumps`) or emit one row per table instead.

---

## Secrets resolution

Any config string starting `secret:` is replaced at load time by `dlt.secrets[<path>]`
(`run.py:53-64`). The resolver walks the whole config tree, so it works at any depth, not just under
`client.auth`.

`secret:sources.foo.token` resolves from env var `SOURCES__FOO__TOKEN` or from `.dlt/secrets.toml`.
The path is not derived from the pipeline name, so several pipelines can share one namespace.

---

### Dependencies are minimal on purpose

**VERIFIED** against `uv.lock`: dlt and snowflake-connector-python require none of `sqlalchemy`,
`connectorx`, or `pyarrow`. The Snowflake destination defaults to `jsonl` and DuckDB to
`insert_values`, so Arrow is not on the load path. All three were dropped, along with the
`postgres`, `mssql`, `mysql`, and `oracle` extras, cutting roughly 100MB from the SPCS image.

`pyarrow` becomes required again if you set `loader_file_format="parquet"`, use filesystem or
Iceberg staging, or call `pipeline.dataset().arrow()` / `.df()`. Add it back deliberately if so,
and note the Parquet caveat: Snowflake stores `json` columns loaded from Parquet as strings rather
than VARIANT.

---

## Adding to this file

Keep entries short and evidence-first. State what was observed, paste the output, and give the file
reference. If a claim is inferred rather than run, mark it **READ** so the next person knows it is
still open. Correcting an entry that turned out to be wrong is more valuable than adding a new one.
