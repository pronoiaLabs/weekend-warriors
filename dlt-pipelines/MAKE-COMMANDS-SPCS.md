# Running the NFL pipelines in SPCS

The container version of [MAKE-COMMANDS.md](MAKE-COMMANDS.md). Same pipelines, same parameters, same
destination schema, but the work happens inside Snowflake instead of on your laptop.

Read the local runbook first for what the data means. This file covers only what is different when
the runner is a container: the extra arguments, the things that must be redeployed before a change
takes effect, and how to see a failure you cannot watch in your terminal.

---

## What changes, and what does not

**Does not change.** The pipeline names, the resource names, the season parameter and its three
spellings, the merge keys, the destination (`NFL_DEV_DB.DEV_<your user>`), and `_DLT_RUNS`. A season
loaded through SPCS is indistinguishable from one loaded locally.

**Does change.**

| | Local | SPCS |
|---|---|---|
| Target | `run-snowflake` | `run-spcs` |
| Credentials | your `snow` connection + `.dlt/secrets.toml` | Snowflake `SECRET` mounted into the container |
| Network | your laptop | External Access Integration |
| Config source | `registries/*.yml` | `DLT_DB.OPS.PIPELINE_REGISTRY` |
| Destination DB | resolved from the registry | resolved from the registry, passed in `USING` |
| `GROUP=` | supported | **not supported**, one `NAME=` per run |
| Failure output | your terminal | `SYSTEM$GET_SERVICE_LOGS` |

That third row is the one people forget. **The container never reads your YAML.** Editing a registry
file changes nothing about an SPCS run until you sync it.

### Which database a run lands in

One database per source system per environment. NFL pipelines load into `NFL_DEV_DB`, and `sample`
loads into `DLT_DEV_DB` because it belongs to no sport.

You never type the database. The registry holds a stem (`database: NFL`), `make run-spcs` resolves
it to `NFL_DEV_DB` and passes it in the `USING` clause, so the submitted statement states its own
destination and you can read it before it runs:

```
args=["nfl_games","--resource","games_regular"] target=NFL_DEV_DB.DEV_JSMITH template=dlt_dev_job.tmpl.yaml
```

Check that line. It is the only place the destination appears before the load happens.

To see where a pipeline would go without running it:

```bash
python -m pipelines.batch.models --database nfl_games --env DEV     # -> NFL_DEV_DB
python -m pipelines.batch.models --database nfl_games --env PROD    # -> NFL_PROD_DB
```

**A pipeline cannot be pointed at another sport's database from the command line, deliberately.** An
exported `DB=` variable left over from an NFL run would otherwise send an NBA load into the NFL
database with nothing to notice it. Change the registry entry and re-sync instead.

---

## The three arguments you will get tired of typing

Every NFL pipeline needs a credential and network egress, so every command needs the same three
arguments. **Export them once per shell session** and then leave them off the commands entirely:

```bash
export SECRET=DLT_DB.OPS.NFL_API_KEY
export ENVVAR=SOURCES__NFL__API_KEY
export EAI=NFL_API_EAI
```

Then `make run-spcs NAME=nfl_reference` on its own. Make reads all three from the environment,
because the Makefile declares them with `?=`, which defers to anything already set.

**Do not collapse them into one shell variable.** The obvious shortcut,
`SEC='SECRET=... ENVVAR=... EAI=...'` followed by `make run-spcs NAME=x $SEC`, is a bash idiom that
silently does the wrong thing in zsh: zsh does not word-split unquoted parameter expansions, so
`$SEC` reaches make as a single argument and the whole string becomes the value of `SECRET`. Every
command then fails with `SECRET set but ENVVAR missing`, which does not obviously point at quoting.

Clear them when you are done, since `SECRET` is a generic name to leave exported:

```bash
unset SECRET ENVVAR EAI
```

The `sample` pipeline is the exception and needs none of them, which is what makes it the right smoke
test when something is broken and you need to know whether the problem is the container path or the
source.

**`ENVVAR` is not arbitrary.** It has to match the `secret:` path in the registry, uppercased with
dots replaced by double underscores. `api_key: "secret:sources.nfl.api_key"` becomes
`SOURCES__NFL__API_KEY`. Get it wrong and the container starts, runs, and fails inside dlt with a
`KeyError`, not at submission time.

---

## Before you run anything: what needs redeploying

Three artefacts live in Snowflake, and each has its own trigger. Skipping one is the most common
reason an SPCS run behaves like an older version of the repo.

| You changed | Redeploy with | Why |
|---|---|---|
| `registries/*.yml` | `make sync-apply` | the container reads the table, not the file |
| a new source | `make setup-source SOURCE=<x> CONFIRM=1` | its two databases must exist first |
| `pipelines/**/*.py` | `make image-push` | the image ships the code |
| `deploy/spcs/*.tmpl.yaml` | `make dev-spec-upload` | the spec is read from the stage |

Nothing warns you. A registry edit without `sync-apply` runs the previous config and reports success.

**Verify a sync landed:**

```sql
SELECT name, pipeline_group, ARRAY_SIZE(config:resources) AS n_resources
FROM DLT_DB.OPS.PIPELINE_REGISTRY ORDER BY name;
```

Expect 8 rows. `n_resources` should read 6 for `nfl_advanced_stats`, `nfl_plays` and `nfl_stats`,
3 for `nfl_games`, 2 for `nfl_reference`, 1 for `nfl_injuries` and `nfl_standings`.

**Verify a spec upload landed.** Do not compare checksums. Internal stages encrypt at rest, so `LIST`
reports the md5 and size of the ciphertext. Compare the size against your local file rounded up to
the next 16-byte block.

---

## Full backfill of one season

Set the year once and paste the block. Expect noticeably longer than the local equivalent: each
command starts a fresh container, and the pool re-suspends after 120 idle seconds, so a pause between
commands costs a restart.

**Paste this in two steps.** First the setup, on its own:

```bash
export SECRET=DLT_DB.OPS.NFL_API_KEY
export ENVVAR=SOURCES__NFL__API_KEY
export EAI=NFL_API_EAI
export SEASON=2023
```

Then the commands. There are no comments in this block on purpose: an interactive zsh does not treat
a leading `#` as a comment unless `interactive_comments` is set, so pasted comment lines run as
commands, and any backticks inside them execute. The grouping is by blank line instead.

```bash
make run-spcs NAME=nfl_games RESOURCE=games_pre     PARAM="seasons[]=$SEASON"
make run-spcs NAME=nfl_games RESOURCE=games_regular PARAM="seasons[]=$SEASON"
make run-spcs NAME=nfl_games RESOURCE=games_post    PARAM="seasons[]=$SEASON"

make run-spcs NAME=nfl_stats RESOURCE=stats_pre          PARAM="seasons[]=$SEASON"
make run-spcs NAME=nfl_stats RESOURCE=stats_regular      PARAM="seasons[]=$SEASON"
make run-spcs NAME=nfl_stats RESOURCE=stats_post         PARAM="seasons[]=$SEASON"
make run-spcs NAME=nfl_stats RESOURCE=team_stats_pre     PARAM="seasons[]=$SEASON"
make run-spcs NAME=nfl_stats RESOURCE=team_stats_regular PARAM="seasons[]=$SEASON"
make run-spcs NAME=nfl_stats RESOURCE=team_stats_post    PARAM="seasons[]=$SEASON"

make run-spcs NAME=nfl_standings RESOURCE=standings PARAM="season=$SEASON"

make run-spcs NAME=nfl_advanced_stats RESOURCE=adv_passing_regular   PARAM="season=$SEASON"
make run-spcs NAME=nfl_advanced_stats RESOURCE=adv_rushing_regular   PARAM="season=$SEASON"
make run-spcs NAME=nfl_advanced_stats RESOURCE=adv_receiving_regular PARAM="season=$SEASON"
make run-spcs NAME=nfl_advanced_stats RESOURCE=adv_passing_post      PARAM="season=$SEASON"
make run-spcs NAME=nfl_advanced_stats RESOURCE=adv_rushing_post      PARAM="season=$SEASON"
make run-spcs NAME=nfl_advanced_stats RESOURCE=adv_receiving_post    PARAM="season=$SEASON"

make run-spcs NAME=nfl_plays RESOURCE=plays_post    PARAM="games_post_ref:seasons[]=$SEASON"
make run-spcs NAME=nfl_plays RESOURCE=plays_pre     PARAM="games_pre_ref:seasons[]=$SEASON"
make run-spcs NAME=nfl_plays RESOURCE=plays_regular PARAM="games_regular_ref:seasons[]=$SEASON"
```

The five groups are, in order: schedule, box scores at both grains, standings, advanced stats, and
play by play. Load them in that order so each is checkable against the one before it.

**Not in the block, deliberately.** `nfl_reference` and `nfl_injuries` are current state, not
seasonal. Running them during a backfill overwrites with today's data rather than producing that
season's. Same reasoning as the local runbook.

**Everything is safe to re-run.** Every resource merges on a key, so an interrupted command is fixed
by running it again.

---

## The season parameter, spelled three ways

Unchanged from the local runbook, and still the most dangerous part.

| Pipeline | How to pass a season |
|---|---|
| `nfl_games`, `nfl_stats` | `PARAM="seasons[]=2023"` |
| `nfl_plays` | `PARAM="games_regular_ref:seasons[]=2023"` (goes on the **parent**) |
| `nfl_standings`, `nfl_advanced_stats` | `PARAM="season=2023"` |
| `nfl_reference`, `nfl_injuries` | none, not season-scoped |

The API ignores a parameter name it does not recognise and returns 200, so a wrong name pulls every
season and looks like a clean run. A wrong *type* returns 400 and is loud. Misnaming is the silent
one.

**In SPCS there is one extra way to get this wrong.** `PARAM` has to survive the shell, the Makefile,
a JSON array, a Jinja render and argparse before it reaches the API. It does, but that is a longer
chain than the local path, so confirm it arrived rather than assuming:

```sql
SELECT pipeline, resources, params, row_counts::string AS counts, finished_at
FROM NFL_DEV_DB.OPS._DLT_RUNS ORDER BY finished_at DESC LIMIT 1;
```

`params` reading `(none)` when you passed one means the override never arrived.

**A bare `run-spcs NAME=nfl_games` with no `RESOURCE` or `PARAM`** runs all three resources with no
season filter and pulls every season the API has. That is legal and occasionally what you want, but
it is never what you want during a backfill.

---

## Reading the output

The submitting command prints the argument array before it runs, which is the cheapest check that
your `RESOURCE` and `PARAM` were parsed the way you meant:

```
args=["nfl_games","--resource","games_regular","--param","seasons[]=2023"] dataset=DEV_JSMITH
```

Then the run itself:

```sql
-- Everything from the last few hours.
SELECT pipeline, status, resources, params, row_counts::string AS counts, error, finished_at
FROM NFL_DEV_DB.OPS._DLT_RUNS
WHERE finished_at > DATEADD(hour, -6, CURRENT_TIMESTAMP())
ORDER BY finished_at;
```

The column is `finished_at`. There is no `started_at`.

After a full backfill block, count the rows. Nineteen commands should produce nineteen records. This
is worth doing every time: a command silently skipped when pasting a block is a real failure mode
that has already happened once on this project.

### Container logs

```sql
SELECT SYSTEM$GET_SERVICE_LOGS('DLT_DB.DEPLOY.dlt_dev_<pipeline>', 0, 'dlt');
```

The service name is `dlt_dev_` plus the pipeline name, and `dlt` is the container name. A successful
`nfl_reference` run is around 400 lines, mostly one line per HTTP request.

Two lines worth finding:

- `resolving pipeline specs from table` confirms the container read `PIPELINE_REGISTRY`.
- `starting pipeline (source=..., dataset=..., resources=..., params=...)` is the run's own account
  of what it was told to do. Compare it against what you typed.

**Read logs before re-running a failure.** `run-spcs` drops the previous job service on each
invocation, so re-running destroys the evidence of why the last one failed.

---

## When something fails

Failures land in one of two places, and which one tells you a lot before you read anything else.

**Failed at submission**, with a SQL error and no service created. The statement was wrong or a grant
is missing. Nothing ran, nothing was billed.

**Failed inside the container**, with a job that was created and then errored. The statement was
fine; the pipeline or its environment is the problem. Logs exist.

| Message | Cause | Fix |
|---|---|---|
| `syntax error ... unexpected 'EXTERNAL_ACCESS_INTEGRATIONS'` | clause order in the recipe | it belongs before `FROM`, not after the template file |
| `Unable to render service spec ... TemplateSyntaxError` | a Jinja delimiter in a template comment | braces belong only in the spec body, never in the header prose |
| `SECRET ... does not exist or not authorized` | missing `READ` on the secret | `GRANT READ ON SECRET ... TO ROLE DLT_DEV_ROLE` |
| `no enabled pipeline named ...` | table out of date | `make sync-apply` |
| `KeyError` from `dlt.secrets` | `ENVVAR` does not match the registry `secret:` path | fix `ENVVAR=` |
| connection timeout to the API | EAI not attached or host missing | pass `EAI=`, check the network rule host list |
| job pending a long time | pool resuming, or no image | normal for a minute or two after idle |
| ran fine, wrong row counts | parameter silently ignored | check `_DLT_RUNS.params` |

`does not exist or not authorized` is one message for two different problems. Do not go hunting for a
typo in the object name first; `SHOW GRANTS ON SECRET <name>` answers it in one query.

---

## Verifying a backfilled season

Same checks as the local runbook, and they matter more here because the execution path is new.

```sql
-- Shape. Compare against a season you already trust.
SELECT season, season_type, COUNT(*) AS games
FROM NFL_DEV_DB.DEV_JSMITH.GAMES GROUP BY 1, 2 ORDER BY 1, 2;

-- No season was silently unfiltered.
SELECT COUNT(DISTINCT season) FROM NFL_DEV_DB.DEV_JSMITH.PLAYS;
```

2024 and 2025 are both 49 preseason, 272 regular, 13 postseason. A new season should match that
shape.

Then run the coverage query from [MAKE-COMMANDS.md](MAKE-COMMANDS.md). A non-zero result is not
automatically a load failure: ask the API directly for one of the missing games, and zero rows back
means a source gap that re-running will not fix. The known gaps are listed there.

---

## Other targets

```bash
make dev-pool-status          # DLT_DEV_POOL must be ACTIVE or IDLE
make sync-apply               # registries/*.yml -> PIPELINE_REGISTRY
make dev-spec-upload          # spec templates -> @DLT_DB.DEPLOY.SPECS
make image-push               # rebuild + push the image (slow on Apple Silicon)
make run-spcs NAME=sample     # credential-free smoke test
```

`make run-spcs NAME=sample` is the first thing to reach for when a real pipeline fails and you cannot
tell whether the container path or the source is at fault. It needs no secret, no egress and no
arguments, so if it passes the infrastructure is fine.
