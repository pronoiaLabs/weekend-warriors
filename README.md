# weekend-warriors

**Build a data pipeline for the sport you love, then talk to it in plain English.**

This repo is a complete, working example of an end-to-end sports analytics stack. It pulls league
data from a public API on a schedule, organizes it into clean, analysis-ready tables, and puts an AI
agent on top so you can ask questions like

> *"How has Detroit's third down and red zone efficiency changed season over season?"*

and get a real answer, computed from a real warehouse, with the SQL shown so you can check its work.

NFL and NCAAF run today. The whole design assumes you may add another sport: doing so is a scaffold
command and a config file, not a rewrite.

---

## What you end up with

Once it is set up, the stack runs itself:

- **Fresh data, automatically.** Each pipeline pulls from the sports API on its own schedule. You
  choose which seasons to load; a backfill can replay any year the API carries.
- **Models that update themselves.** Minutes after new data lands, the tables your agent reads are
  rebuilt. There is no nightly job to babysit and no "run this after that" checklist.
- **An agent per sport.** Ask about teams, players, games, or trends in plain English. The agent
  writes and runs the SQL, and shows it to you.
- **A dashboard to keep an eye on things.** A local web app shows every pipeline run, every model
  build, and what each one did, so "is it working?" is a glance, not an investigation.

Everything runs inside a Snowflake account. There is no separate orchestrator, no servers of your
own to patch, and nothing running on your laptop once it is deployed.

---

## What is in the box

| Part | What it does |
|---|---|
| [dlt-pipelines/](dlt-pipelines/) | The collector. Pulls API data on a schedule and lands it, raw and complete. |
| [dbt-pipelines/](dbt-pipelines/) | The brain. Turns raw tables into clean models, and defines the agents. |
| [ml/](ml/) | Spec-driven NFL models on FEATURES. Fit in a Workspace notebook; registry is `NFL_PROD_DB.ML`. |
| [ops-dashboard/](ops-dashboard/) | The window. A local dashboard for watching pipelines and builds run. |

Each part has its own README with the full technical detail. This page stays out of the weeds on
purpose; if you are an engineer who wants the deep end, start with
[dlt-pipelines/README.md](dlt-pipelines/README.md) and
[dbt-pipelines/README.md](dbt-pipelines/README.md), which explain every design decision and the
sharp edges they route around.

---

## Try it in five minutes, no Snowflake needed

You can watch the collector work on your laptop before committing to anything. A local run loads
into a small on-disk database instead of a warehouse.

**You need:** Python 3.11+, [uv](https://docs.astral.sh/uv/), and a free API key from
[balldontlie.io](https://www.balldontlie.io).

```bash
git clone https://github.com/pronoiaLabs/weekend-warriors.git
cd weekend-warriors/dlt-pipelines

make setup                        # installs everything, tells you where the API key goes
make run NAME=nfl_reference       # teams + players, about 30 seconds
```

That is the whole loop in miniature: an API on one side, queryable tables on the other.

---

## Setting it up for real

Deploying to your own Snowflake account is a sequence of reviewed steps you run yourself, on
purpose: the setup creates roles and permissions, and you should see what it does before it does it.
The ordered end-to-end bootstrap, covering everything from the connection file through the
Postgres instance, dbt, agents and dashboards, is [SETUP.md](SETUP.md). The ingestion-side
deep-dive with a verification query at each step is
[dlt-pipelines/MAKE-COMMANDS-PROD.md](dlt-pipelines/MAKE-COMMANDS-PROD.md).

The short version: a handful of `make setup-*` commands build the foundations, one command pushes
the collector container, one creates the schedules, and from then on the stack feeds itself.

---

## Adding your sport

This is the point of the whole design.

```bash
make new-source NAME=nba HOST=https://api.balldontlie.io
```

That one command scaffolds everything the new sport needs, names already wired together: the
pipeline config, the databases, the API access, and the trigger that rebuilds models when data
lands. Fill in which endpoints to pull, add models for what you want to ask about, and your agent
has a new sport to talk about. The existing sports are the worked examples to copy from.

---

## Honesty section

Sports APIs are imperfect, and this repo says so out loud rather than papering over it. Known data
gaps (a few games missing stats here, an endpoint that under-returns there) are encoded as tests
that fail visibly instead of letting bad numbers flow quietly into answers. The details live in the
technical READMEs and the test suites; the principle is simply that an agent you can trust needs a
pipeline that admits what it does not know.

---

## Provenance and license

Built on two templates by [innovation-igloo](https://github.com/innovation-igloo), each imported at
the commit below and then adapted. Both keep their original Apache 2.0 `LICENSE`.

| Directory | Upstream | Imported at |
|---|---|---|
| `dlt-pipelines/` | [dlt-snowflake-template](https://github.com/innovation-igloo/dlt-snowflake-template) | `3cc4194` |
| `dbt-pipelines/` | [cortex-agents-dbt-project-template](https://github.com/innovation-igloo/cortex-agents-dbt-project-template) | `ae5d195` |

Upstream history is not preserved here. Both templates are public if you want to see what changed.

Licensed under Apache 2.0. See [LICENSE](LICENSE).
