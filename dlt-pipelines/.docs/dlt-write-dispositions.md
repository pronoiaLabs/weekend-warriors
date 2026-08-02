# dlt write dispositions, merge strategies, and schema mapping

Extracted from the `development-gameplan` docs site before it was removed. This is the reference
`AGENTS.md` cites for how rows land in Snowflake. It covers ground the upstream dlt docs vendored
alongside it (`rest-api-basic.md`, `rest-api-advanced.md`, `dlt-snow.md`) do not.

---

## Write dispositions

| Value | Behavior | Use for |
|---|---|---|
| `append` | INSERT new rows after existing; no dedup | Immutable events and logs (the safe default) |
| `replace` | Remove all existing rows, load new; strategy sets atomicity | Full refresh, snapshots |
| `merge` | Stage + dedup/upsert/retire by keys; **falls back to append if no keys** | Mutable data, CDC, SCD |
| `skip` | Never write to the table | Schema-only declarations |

The dict form extends the string:

```python
write_disposition="merge"                                              # shorthand
write_disposition={"disposition": "merge", "strategy": "delete-insert"}
# skip the staging dedup pass when the source is already unique per key
write_disposition={"disposition": "merge", "strategy": "delete-insert", "deduplicated": True}
```

Note the fallback in the `merge` row. Merge with no keys does not raise. It quietly degrades to
`append`, so rows accumulate on every run. That looks like duplication downstream, but the
mechanism and the fix are different from a real duplicate-key problem.

## Merge strategies

| Strategy | Keys needed | Behavior |
|---|---|---|
| `delete-insert` (default) | `primary_key` (dedup) **and/or** `merge_key` (delete scope) | Stage, dedup by PK, DELETE matching keys, INSERT staging, atomically |
| `upsert` | `primary_key` (unique, required); no `merge_key` | Native SQL MERGE/UPDATE; no dedup, caller guarantees uniqueness |
| `insert-only` | `primary_key` (unique, required) | INSERT if PK absent, SKIP if present; idempotent re-runs |
| `scd2` | **none required**; `merge_key` optional | Full history via validity columns; retires changed and removed rows |

Only `upsert` and `insert-only` hard-require a primary key. `delete-insert` accepts either key
alone, and `scd2` needs neither.

### scd2 specifics

- Adds `_dlt_valid_from` and `_dlt_valid_to` validity columns. A NULL `valid_to` means active.
- Stores a surrogate **row content hash** in `_dlt_id`, overridable via `row_version_column_name`.
  Change detection is hash against hash, which is why no business key is needed.
- Validity columns live on the ROOT table only. Join nested tables through `_dlt_root_id`.
- **`merge_key` modes**, and this is the one that bites:
  - unset means full-extract, so **any row absent from the extract is retired**
  - a natural key means incremental, so absent rows are NOT retired
  - a partition column means only partitions present in the extract are retired

Pairing scd2 with an incremental extract while leaving `merge_key` unset will retire all prior
history on the first incremental run.

### primary_key vs merge_key

`primary_key` defines row identity, deduplicates staging, and DELETEs by exact match. `merge_key`
defines the DELETE **scope** (a partition or batch) and does not deduplicate. Both accept compound
values as a list or tuple. `upsert` and `insert-only` do not support `merge_key`.

Setting either **forces `nullable=False`** on those columns, which will fail a load if the source
ever emits a null there.

- `dedup_sort: "desc"` keeps the latest row per key during staging dedup.
- A `hard_delete` column propagates physical deletes. Boolean `True` deletes; any non-boolean
  non-NULL value also deletes.

> **Snowflake does not enforce `primary_key` or `unique`**, and does not `RELY` on them for query
> planning. dlt uses these keys for its own merge logic only, so uniqueness is guaranteed by dlt,
> never by the database. `create_indexes=true` adds the hints to the DDL but changes nothing about
> enforcement.

## Replace strategies

| Strategy | Atomic | Downtime | Snowflake behavior |
|---|---|---|---|
| `truncate-and-insert` (default) | No | Yes | TRUNCATE then INSERT; fastest |
| `insert-from-staging` | Yes | Zero | Truncate and insert in one transaction |
| `staging-optimized` | Yes | Zero | Drop and recreate via `CREATE TABLE ... CLONE` from staging |

`staging-optimized` drops and recreates the table, which destroys its GRANTs. `enable_atomic_swap`
fixes that by using `ALTER TABLE ... SWAP WITH` instead of a clone, so each table keeps its own
permissions through the swap.

```toml
[destination.snowflake]
replace_strategy = "staging-optimized"
enable_atomic_swap = true
```

Cost to know about: dlt does not drop staging tables, so the previous production table (with its
grants) becomes the next load's staging table. You carry a full duplicate copy of every
replace-loaded table.

## Metadata columns dlt adds

| Column | Table | Purpose |
|---|---|---|
| `_dlt_id` | all | Unique row id, **and a content hash only under merge and scd2** |
| `_dlt_load_id` | all | References `_dlt_loads.load_id` |
| `_dlt_parent_id` | child | FK to the parent row's `_dlt_id` |
| `_dlt_list_idx` | child | Position in the source list |
| `_dlt_root_id` | child | FK to root `_dlt_id`; added only under merge via `root_key`, required for nested-table merge |

The `_dlt_id` caveat matters. Under plain `append` it is not deterministic, so loading the same
source row twice produces two different values. Deduplicating an append-only table on `_dlt_id` is
a no-op. Join to `_dlt_loads` instead:

```sql
select s.*, l.inserted_at as loaded_at
from raw.some_table s
join raw._dlt_loads l on s._dlt_load_id = l.load_id
qualify row_number() over (partition by <business cols> order by l.inserted_at desc) = 1
```

`_dlt_loads` carries one row per completed load with `load_id`, `status` (0 means success),
`inserted_at`, `schema_name`, and `schema_version_hash`.

## Naming and nesting

Nested paths flatten with a **double underscore**: `a.b.c` becomes `a__b__c`. Identifiers over 255
characters are shortened.

Snowflake casefolds with `str.upper`, so case-insensitive identifiers are stored and sent
UPPERCASE, while dlt keeps names lowercase in its own schema (matching dbt's convention).

| Convention | Case | Snowflake identifiers |
|---|---|---|
| `snake_case` (default) | Case-insensitive | UPPERCASE unquoted |
| `sql_ci_v1` | Case-insensitive | UPPERCASE unquoted |
| `sql_cs_v1` | Case-sensitive | Quoted, must be quoted in queries |
| `duck_case` / `direct` | Case-sensitive | Quoted |

## Type mapping to Snowflake

| dlt type | Snowflake type | Notes |
|---|---|---|
| `text` | `VARCHAR` | up to 16 MB |
| `double` | `FLOAT` | |
| `bool` | `BOOLEAN` | |
| `timestamp` | `TIMESTAMP_TZ` | `timezone=false` gives `TIMESTAMP_NTZ`; precision 0-9, default 6 |
| `date` | `DATE` | |
| `time` | `TIME` | |
| `bigint` | `NUMBER(19,0)` | Snowflake has no native integer |
| `binary` | `BINARY` | |
| `json` | `VARIANT` | **From Parquet it lands as a string.** Use JSONL, or `PARSE_JSON` after loading |
| `decimal` | `NUMBER(p,s)` | default precision and scale if unbound |
| `wei` | `NUMBER(38,0)` | 256-bit integers |

For JSON-heavy API payloads, stage as JSONL rather than Parquet so `json` columns land as real
`VARIANT` instead of strings. JSONL is the Snowflake destination's default preferred format, so
this only becomes a problem if something explicitly switches to Parquet.

## Useful column hints

| Hint | Meaning |
|---|---|
| `data_type` | Explicit type, bypasses inference |
| `nullable` | Defaults true; `primary_key`/`merge_key` force false |
| `precision` / `scale` | Digits and decimal places |
| `timezone` | true (default) gives `TIMESTAMP_TZ`; false gives `TIMESTAMP_NTZ` |
| `cluster` | Adds the column to a Snowflake CLUSTER KEY; multiple compose an ordered key |
| `dedup_sort` | `asc` or `desc`, which duplicate wins during merge staging dedup |
| `hard_delete` | Marks a column that signals physical deletes |

A direct `primary_key=` or `merge_key=` argument overrides the same hint inside `columns={}`.
