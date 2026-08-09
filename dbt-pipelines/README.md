# Cortex Agent Development Lifecycle with dbt Projects on Snowflake

Think of this as a starter kit for building Cortex Agents the way you'd build any other piece of software: in version control, promoted across dev, staging, and prod, tested with evaluations, and shipped through CI/CD. Everything (semantic views, agent specs, evaluations, and scheduling) lives as code in one dbt project and runs natively inside Snowflake. Fork it, point it at your data, and you've got a repeatable lifecycle instead of a pile of one-off UI clicks.

## Prerequisites

Before you start, here's what you'll need:

| Requirement | Details |
|:---|:---|
| **Snowflake Account** | Any edition with Cortex Agents enabled |
| **Role** | Must have `CREATE SEMANTIC VIEW`, `CREATE AGENT`, `CREATE TASK` on the target schema |
| **Warehouse** | Any warehouse (XS is fine for development) |
| **External Access Integration** | Required for `dbt deps` to download packages from `hub.getdbt.com` |
| **Git Repository** | Fork this repo to your own GitHub account |

### External Access Integration Setup

You only need to do this once, and it takes ACCOUNTADMIN. It lets `dbt deps` reach out and download packages:

```sql
CREATE OR REPLACE NETWORK RULE dbt_network_rule
  MODE = EGRESS
  TYPE = HOST_PORT
  VALUE_LIST = ('hub.getdbt.com', 'codeload.github.com');

CREATE OR REPLACE EXTERNAL ACCESS INTEGRATION dbt_ext_access
  ALLOWED_NETWORK_RULES = (dbt_network_rule)
  ENABLED = TRUE;
```

## Environment variables (env.yml)

One codebase, every environment: that's the goal. This template leans on [SQL environment variables](https://docs.snowflake.com/en/user-guide/data-engineering/dbt-projects-on-snowflake-environment-variables) so you never hardcode a database or schema name. When you run `EXECUTE DBT PROJECT`, Snowflake reads `env.yml`, evaluates any SQL inside it, and injects the results as environment variables that `profiles.yml` picks up with `env_var()`.

Here's the flow when you run it:

1. **`EXECUTE DBT PROJECT ... ENVIRONMENT = 'dev'`** kicks things off.
2. **`env.yml`** picks the `dev` environment and evaluates any SQL inside it (like `{{ select CURRENT_USER() }}`), then injects `DBT_DATABASE`, `DBT_SCHEMA`, `DBT_WAREHOUSE`, and `DBT_ROLE`.
3. **`profiles.yml`** reads those with `env_var()` and maps them onto `target.database`, `target.schema`, and the rest.
4. Everything dbt builds lands in that target, and the agent macro substitutes the same values into the agent spec.

Here's what adjusts automatically:

- **Semantic views, staging models, and evaluations** build into `{DBT_DATABASE}.{DBT_SCHEMA}` on their own, because they inherit the dbt target. No tokens needed.
- **The eval stage and file format** (`create_eval_stage`, `run_evaluation`) read `target.database`/`target.schema`, so they follow the environment too.
- **The agent spec** lives in a wrapper macro (`agents/*.sql`) because dbt Projects on Snowflake can't read a file at runtime. The wrapper passes the spec to `create_agent`/`alter_agent`, which swap the `<<DATABASE>>`, `<<SCHEMA>>`, and `<<WAREHOUSE>>` tokens for the active target values.
- **Raw sources** (`models/sources.yml`) are deliberately *not* env-driven: every developer reads the same raw input tables.

**Environments** (`env.yml`), `default_environment: dev`:

| Environment | Database | Schema | Role |
|:---|:---|:---|:---|
| `dev` | `DEV_DB` | `CURRENT_USER()` (per-developer) | `CURRENT_ROLE()` |
| `staging` | `STAGING_DB` | `CORTEX_AGENTS` | `SYSADMIN` |
| `prod` | `PROD_DB` | `CORTEX_AGENTS` | `SYSADMIN` |

Per-developer schemas in `dev` mean each engineer's agents, semantic views, and evaluations stay isolated, so nobody overwrites anyone else while iterating.

A few rules to keep in mind:

| Rule | Example |
|:---|:---|
| Keys must be `DBT_` prefixed | `DBT_SCHEMA`, not `SCHEMA` |
| Keys must be UPPERCASE | `DBT_DATABASE`, not `dbt_database` |
| SQL values need double quotes | `"{{ select CURRENT_USER() }}"` |
| `env.yml` lives next to `dbt_project.yml` | project root |

Precedence, highest wins: `ENV_VARS=(...)` on `EXECUTE` (or `--env-vars` on the CLI) > shell env vars (CLI only, `--use-shell-env-vars`) > the `env.yml` selected environment.

> **Note:** the `env_var()` calls in `profiles.yml` have no fallback defaults, so a run fails fast if a variable is missing (for example, running outside Snowflake without `env.yml` resolution) instead of quietly using the wrong database. Always run through `EXECUTE DBT PROJECT` / `snow dbt execute` with an environment selected.

## Getting started

There are two ways to get this into a Snowflake Workspace. Pick whichever fits: connect your Git fork (recommended, since you get version history and PR review), or just upload the folder.

> **Prefer to work locally?** Fork the repo, clone it, and open it in [Cortex Code Desktop](https://docs.snowflake.com/en/user-guide/cortex-code/cortex-code-desktop). You get an AI agent that lives right next to your editor and terminal, wired into your Snowflake connection, so you can edit models, run `snow dbt execute`, and ship the agent without leaving the app. Push your changes and they flow into the Workspace through the same Git connection from Option A.

### Option A: From a Git repo (recommended)

1. **Fork this repository** to your GitHub account.
2. In Snowsight, head to **Projects > Workspaces** and choose **Create Workspace > From Git repository**.
3. Enter your forked repo URL and pick your API integration (see [connecting Git to Snowflake](https://docs.snowflake.com/en/developer-guide/git/git-setting-up)).

### Option B: Upload the folder (no Git)

1. **Download this template directory** to your local machine.
2. In Snowsight, head to **Projects > Workspaces** and choose **Create Workspace > Blank Workspace**, then name it (e.g. `cortex_agent_lifecycle`).
3. Click **+ Add new > Upload folder** and select the downloaded template directory.

> **Heads up:** without Git you won't have version history or PR-based review. You can connect a Git repository later in the Workspace settings if you change your mind.

### Then, once it's in your Workspace

Both paths land here. From the command bar:

1. **Edit `env.yml`**: swap `DEV_DB` / `STAGING_DB` / `PROD_DB` and `ANALYTICS_WH` for your own databases and warehouse.
2. **Install dependencies**: click the dropdown arrow next to the execute button, enter your External Access Integration name (e.g. `dbt_ext_access`), and click **Deps**.
3. **Compile** to make sure everything resolves.
4. **Pick your environment** (dev/staging/prod) in the environment selector, then **Build** to materialize the models.
5. **Deploy** it as a DBT PROJECT object: **Connect > Deploy dbt Project**, choose your target database and schema, give it a name (e.g. `CORTEX_LIFECYCLE`), and click **Deploy**.

## Production builds are event-driven

Prod models rebuild automatically when ingestion lands: per sport, a stream on
`RAW._DLT_LOADS` feeds a triggered task that runs `EXECUTE DBT PROJECT` against
that sport's project object (`DLT_DB.DEPLOY.CORTEX_LIFECYCLE_<SPORT>`), as
`DBT_RUNNER_ROLE` on warehouse `DBT_WH`. The machinery lives in
`../dlt-pipelines/sql/sources/<sport>/05_dbt_trigger.sql`; the repo root
CLAUDE.md section "Event-driven dbt builds" has the full contract.

The consequence for this directory: **deploying a sport's project object is
the prod release step.** After merging model changes, run
`make deploy-sport SPORT=<sport>` (or `make deploy-all`); the next data load
builds with the new code. `make help` lists the targets. The sport-neutral
`CORTEX_LIFECYCLE` object serves interactive and dev use only.

Every query a build runs carries a JSON Snowflake `QUERY_TAG`
(`app`/`sport`/`env`/`build_id`/`node`): the base comes from env.yml's
`DBT_QUERY_TAG_BASE` through profiles.yml `query_tag`, and
`macros/query_tags.sql` overrides `snowflake__set_query_tag` to add the
per-node fields. Both keys are REQUIRED for any new environment (no
defaults, fail-fast). The tag is the correlation key for the observability
chain in `../dlt-pipelines/sql/ops/06-08` (query log, operator-stats
harvest, `V_DBT_RUNS`, cost tags) and the ops dashboard's dbt page; change
the JSON shape only together with those.

## Working from the Snowflake CLI

> **Requires Snowflake CLI >= 3.21.** The `env.yml` flags (`--default-env`, `--env`) only landed in 3.21. On older CLIs, use the Snowsight Workspace flow above, which resolves `env.yml` natively. Check yours with `snow --version`.

```bash
# Deploy the project object (--default-env sets the env used for compile + runs)
snow dbt deploy cortex_lifecycle --source . \
  --default-env dev \
  --external-access-integration dbt_ext_access --force

# Build with an environment. IMPORTANT: --env must come BEFORE the project name
# (tokens after the name are passed to dbt Core, which has no --env). Qualify the
# name so EXECUTE DBT has a database context.
snow dbt execute --env dev DB.SCHEMA.cortex_lifecycle build

# Deploy the agent (the wrapper macro defines the spec and calls create_agent)
snow dbt execute --env prod DB.SCHEMA.cortex_lifecycle run-operation deploy_example_agent
```

Inside a Snowsight Workspace you run dbt directly (the environment selector picks the `env.yml` environment):

```bash
dbt run-operation deploy_example_agent
```

## Project Structure

Here's the lay of the land:

```
├── dbt_project.yml              # Project configuration
├── packages.yml                 # dbt_semantic_view package dependency
├── profiles.yml                 # One profile, reads env_var() for all environments
├── env.yml                      # ★ Environment variables (dev / staging / prod)
│
├── .github/workflows/
│   ├── incoming_pr.yml.example  # CI: build + test on dev when a PR opens
│   └── pr_merged.yml.example    # CD: deploy + build + create agent on merge to prod
│
├── models/
│   ├── sources.yml              # Source table definitions: start here
│   ├── staging/                 # Staging models (clean source data)
│   ├── semantic_views/
│   │   ├── _semantic_views.yml  # Model documentation
│   │   └── sv_example.sql       # Semantic view skeleton (materialized='semantic_view')
│   └── evaluations/
│       └── eval_dataset.sql     # Evaluation dataset (PARSE_JSON from seed)
│
├── macros/
│   ├── create_agent.sql         # Helper: CREATE OR REPLACE AGENT from spec text
│   ├── alter_agent.sql          # Helper: ALTER AGENT MODIFY LIVE VERSION from spec text
│   ├── create_eval_stage.sql    # Create stage + file format for eval configs
│   └── run_evaluation.sql       # Upload YAML + EXECUTE_AI_EVALUATION
│
├── agents/                      # On macro-paths; holds per-agent wrapper macros
│   └── example_agent.sql        # deploy_example_agent(): spec inline + create/alter call
│
├── evaluations/
│   └── example_eval_config.yml  # Evaluation configuration YAML
│
└── seeds/
    └── eval_ground_truth.csv    # Sample evaluation Q&A pairs
```

## Workflow

> **Running a guided build session?** Check out [`WORKING-SESSION.md`](WORKING-SESSION.md): a phase-driven runbook you (or Cortex Code) can follow to build the agent end-to-end.

The big picture looks like this:

```
1. Define Sources ──> 2. Build Staging ──> 3. Create Semantic View ──> 4. Deploy Agent
                                                                            │
                                          6. Ship to Users <── 5. Run Evaluations
                                          (Teams / SI / MCP)       (>= 95% accuracy)
```

### Step-by-step

| Step | What | How |
|:-----|:-----|:----|
| **1** | Define source tables | Edit `models/sources.yml` with your database, schema, and table names |
| **2** | Build staging models | Create `.sql` files in `models/staging/` to clean source data |
| **3** | Create semantic view | Edit `models/semantic_views/sv_example.sql`: add TABLES, DIMENSIONS, METRICS, VERIFIED_QUERIES |
| **4** | Deploy agent | Edit the spec in `agents/example_agent.sql`, then run: `dbt run-operation deploy_example_agent` |
| **5** | Run evaluation | Edit `seeds/eval_ground_truth.csv` + `evaluations/example_eval_config.yml`, upload config to stage, then run: `dbt run-operation run_evaluation --args '{agent_name: example_agent, run_name: v1, config_file: example_eval_config.yml}'` |
| **6** | Schedule | Create a Snowflake Task (see below) |

### Scheduling with Snowflake Tasks

Want it to run on its own? Wrap the same commands in Tasks:

```sql
-- Schedule daily builds
CREATE OR REPLACE TASK daily_cortex_build
  WAREHOUSE = ANALYTICS_WH
  SCHEDULE = 'USING CRON 0 6 * * * America/Denver'
AS
  EXECUTE DBT PROJECT DEV_DB.CORTEX_AGENTS.CORTEX_LIFECYCLE
    ARGS='build --target prod';

ALTER TASK daily_cortex_build RESUME;

-- Schedule daily evaluation
CREATE OR REPLACE TASK daily_agent_evaluation
  WAREHOUSE = ANALYTICS_WH
  AFTER daily_cortex_build
AS
  EXECUTE DBT PROJECT DEV_DB.CORTEX_AGENTS.CORTEX_LIFECYCLE
    ARGS='run-operation run_evaluation --args "{agent_name: example_agent, run_name: daily, config_file: example_eval_config.yml}"';

ALTER TASK daily_agent_evaluation RESUME;
```

## CI/CD with GitHub Actions

Two workflow files live in `.github/workflows/`, kept with a `.example` extension so they don't auto-run on a public fork. Drop the extension to turn them on.

| File | Trigger | What it does |
|:---|:---|:---|
| `incoming_pr.yml.example` | PR opened/updated → `main` | Deploys a tester project object, builds models + semantic views with `--env dev` |
| `pr_merged.yml.example` | Push to `main` (after merge) | Deploys the prod project, builds with `--env prod`, then runs `deploy_example_agent` |

### Setup

1. Create an OIDC service user in Snowflake (no password needed):

```sql
CREATE USER IF NOT EXISTS github_actions_service_user
  TYPE = SERVICE
  WORKLOAD_IDENTITY = (
    TYPE = OIDC
    ISSUER = 'https://token.actions.githubusercontent.com'
    SUBJECT = 'repo:your-org/cortex-agents-dbt-project-template:environment:prod'
  )
  DEFAULT_ROLE = SYSADMIN;

-- SYSADMIN is enough for routine object creation (semantic views, agents,
-- stages). ACCOUNTADMIN is only needed once, by a human, for the External
-- Access Integration above. Don't grant it to the CI/CD service user.
GRANT ROLE SYSADMIN TO USER github_actions_service_user;
```

2. Add GitHub repo secrets and variables:

| Type | Name | Value |
|:---|:---|:---|
| Secret | `SNOWFLAKE_ACCOUNT` | Your account identifier (e.g. `org-account`) |
| Variable | `SNOWFLAKE_DATABASE` | Database for the dbt project object |
| Variable | `SNOWFLAKE_SCHEMA` | Schema for the dbt project object |

3. Create a GitHub environment named `prod` in repo **Settings → Environments** (it has to match the OIDC `SUBJECT`).

Open a PR and the CI workflow kicks off automatically.

## Writing effective semantic views

The semantic view is what makes Cortex Analyst accurate, so it's worth the effort. The high-leverage practices:

- **Business names + curated synonyms.** Name objects the way users speak ("Revenue", not `AMT_TOT`); add a few real alternate phrasings per key table/dimension/metric. Avoid auto-generated synonym spam.
- **Comments that teach.** At the view, table, and column level, state business meaning, **grain**, and any exclusions or caveats.
- **Model KPIs as metrics.** Put canonical calculations in `METRICS` (e.g. `net_sales`, `avg_order_value`) so the model doesn't re-derive them. Use `FACTS` for reusable row-level expressions and `DIMENSIONS` for what users group/filter by.
- **Sample values + enums.** Add `SAMPLE_VALUES` to categorical dimensions so the model maps phrasing to real filter values; add `IS_ENUM` only when the listed values are the *complete* set (`SAMPLE_VALUES` must appear before `IS_ENUM`).
- **Verified queries.** Add `AI_VERIFIED_QUERIES` for common and failure-prone questions, phrased the way users actually ask them: one of the strongest accuracy levers.
- **Custom instructions.** Use `AI_SQL_GENERATION` for recurring defaults / rounding / value decoding and `AI_QUESTION_CATEGORIZATION` for out-of-scope handling and clarifications. Keep these in the semantic view, not in the agent.
- **Explicit keys & relationships.** Declare `PRIMARY KEY` / `UNIQUE` and named `RELATIONSHIPS`. If two tables have multiple join paths, disambiguate a metric with `USING (relationship_name)`, and prefer a clean star shape to avoid multi-path ambiguity errors.
- **Keep scope tight.** Start with ~3-5 tables and roughly **50-100 columns total**: smaller, focused views outperform "do-it-all" models because Cortex Analyst has a limited context window. Split by domain when needed.

**Clause order is enforced**, so author the DDL in this sequence:

```
TABLES -> RELATIONSHIPS -> FACTS -> DIMENSIONS -> METRICS -> COMMENT
      -> AI_SQL_GENERATION -> AI_QUESTION_CATEGORIZATION -> AI_VERIFIED_QUERIES
```

`COMMENT` must come **before** the `AI_*` clauses, and `AI_VERIFIED_QUERIES` comes last (putting `COMMENT` after the `AI_*` clauses raises `unexpected 'COMMENT'`).

References: [Best practices for semantic views](https://docs.snowflake.com/en/user-guide/views-semantic/best-practices-dev) · [Semantic View Editor](https://docs.snowflake.com/en/user-guide/views-semantic/editor) · [CREATE SEMANTIC VIEW](https://docs.snowflake.com/en/sql-reference/sql/create-semantic-view) · [Using SQL to manage semantic views](https://docs.snowflake.com/en/user-guide/views-semantic/sql)

## Writing effective agents

Agent quality comes mostly from three things, and the trick is to keep them in **separate layers**. Mixing them is the most common cause of poor answers:

| Layer | Spec field | Put here | Keep out |
|:------|:-----------|:---------|:---------|
| **Orchestration** | `instructions.orchestration` | Tool routing, intent defaults (e.g. default time window), scope limits, multi-step workflows, fallback when a tool errors or returns nothing | Tone, formatting, SQL-generation rules |
| **Response** | `instructions.response` | Tone, answer-first structure, tables vs. charts, units/currency, data freshness, how to handle ambiguity or empty results | Tool routing, SQL-generation rules |
| **Tool description** | `tools[].tool_spec.description` | What the tool does, what data it accesses, when to use, when **not** to use, input guidance | (none) |

**Tool descriptions are the single biggest driver of routing accuracy.** Write each one with this formula:

> **what it does** + **what data it accesses** (grain, metrics, dimensions, history, refresh cadence) + **when to use** + **when NOT to use** + **input guidance**

Give every tool a distinct domain and a non-overlapping "when to use", and always include an explicit "when NOT to use" so the agent doesn't overuse it. When you have multiple Analyst tools, the descriptions are what let the agent tell them apart.

**Keep SQL-generation rules out of the agent.** Rounding, metric synonyms (e.g. "sales" = `net_sales`), and default filters belong in the semantic view's `AI_SQL_GENERATION` clause, not in agent instructions.

> **Tip:** raise `orchestration.budget.seconds` for long multi-step runs (e.g. `300` for 5 minutes).

> **Required:** every `cortex_analyst_text_to_sql` tool needs an `execution_environment` (the warehouse its generated SQL runs in) under `tool_resources`. Use `execution_environment: { type: warehouse, warehouse: <name> }`, not a top-level `warehouse` key.

References: [Best Practices to Building Cortex Agents](https://www.snowflake.com/en/developers/guides/best-practices-to-building-cortex-agents/) · [CREATE AGENT](https://docs.snowflake.com/en/sql-reference/sql/create-agent) · [Create and manage agents](https://docs.snowflake.com/en/user-guide/snowflake-cortex/cortex-agents-manage)

## Macros Reference

The macros that do the heavy lifting:

| Macro | Purpose | Usage |
|:------|:--------|:------|
| `deploy_<agent>` | Per-agent wrapper (in `agents/<agent>.sql`): defines the spec inline and calls the helper | `dbt run-operation deploy_example_agent` (add `--args '{alter: true}'` for a zero-downtime update) |
| `create_agent` | Helper called by a wrapper: `create_agent(agent_name, spec)` -> CREATE OR REPLACE AGENT with token substitution | (called by `deploy_<agent>`, not directly) |
| `alter_agent` | Helper called by a wrapper: `alter_agent(agent_name, spec)` -> ALTER live version | (called by `deploy_<agent>`, not directly) |
| `create_eval_stage` | Creates the stage and file format required for evaluation configs | `dbt run-operation create_eval_stage` |
| `run_evaluation` | Creates the stage (if needed) and starts an evaluation run | `dbt run-operation run_evaluation --args '{agent_name: example_agent, run_name: v1, config_file: example_eval_config.yml}'` |

## Customization

### Adding a new semantic view
1. Create a new `.sql` file in `models/semantic_views/`
2. Use `{{ config(materialized='semantic_view') }}` at the top
3. Reference tables with `{{ source() }}` or `{{ ref() }}`
4. Run `dbt build --select my_new_sv`

### Adding a new agent
1. Copy `agents/example_agent.sql` to `agents/my_new_agent.sql`
2. Rename the macro to `deploy_my_new_agent` and change the `create_agent('example_agent', spec)` / `alter_agent('example_agent', spec)` calls to `'my_new_agent'`
3. Edit the inline `spec` (models, instructions, tools, tool_resources). For fully-qualified names (semantic view, warehouse, search service) use the `<<DATABASE>>`, `<<SCHEMA>>`, and `<<WAREHOUSE>>` tokens: the helpers substitute the active environment's target values
4. Run `dbt run-operation deploy_my_new_agent`

### Adding evaluation data
1. Add rows to `seeds/eval_ground_truth.csv`
2. Run `dbt seed` to reload
3. Run `dbt run --select eval_dataset` to rebuild the evaluation table

## Resources

- [dbt Projects on Snowflake](https://docs.snowflake.com/en/user-guide/data-engineering/dbt-projects-on-snowflake)
- [dbt_semantic_view Package](https://hub.getdbt.com/Snowflake-Labs/dbt_semantic_view/latest/)
- [CREATE SEMANTIC VIEW](https://docs.snowflake.com/en/sql-reference/sql/create-semantic-view)
- [CREATE AGENT](https://docs.snowflake.com/en/sql-reference/sql/create-agent)
- [Cortex Agent Evaluations](https://docs.snowflake.com/en/user-guide/snowflake-cortex/cortex-agents-evaluations)
- [EXECUTE DBT PROJECT](https://docs.snowflake.com/en/sql-reference/sql/execute-dbt-project)
- [Snowflake Workspaces](https://docs.snowflake.com/en/user-guide/data-engineering/dbt-projects-on-snowflake-using-workspaces)
