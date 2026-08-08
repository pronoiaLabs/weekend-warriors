# Makefile for dlt-snowflake-template
#
# Quickstart for a new machine:
#   make setup                  # doctor + install (uv) + secrets bootstrap
#   make list                   # show pipelines declared in registries/*.yml
#   make run-local NAME=sample  # load a pipeline locally to DuckDB
#
# Dependency management uses `uv`. `make install` runs `uv sync` (creates .venv
# and uv.lock); every other Python target runs through `uv run`, which keeps the
# environment in sync automatically.

# INLINE COMMENTS AND TRAILING WHITESPACE
# Make keeps everything between a value and a trailing '#', so
# `VAR ?= value          # note` stores "value          ", spaces included. That is
# invisible until the value is quoted or concatenated, at which point it silently
# corrupts a tag, an identifier, or a path.
#
# So: any variable that carries a DEFAULT VALUE puts its comment on the line above.
# Variables that default to EMPTY keep the aligned inline style, because make strips
# the leading whitespace after `?=` and they end up genuinely empty.

UV          ?= uv
# space-separated: EXTRAS="dev postgres"
# 'docs' is in the default set on purpose: `uv run` syncs the venv to exactly the
# extras it is given, so a separate --extra docs for `make plan` would uninstall
# the dev extra on every switch between `make plan` and `make test`.
EXTRAS      ?= dev docs
EXTRA_FLAGS := $(foreach e,$(EXTRAS),--extra $(e))
UV_RUN      := $(UV) run $(EXTRA_FLAGS)

# default destination for `make run-local`
DEST        ?= duckdb
# Where `make run-local` writes its DuckDB file. Every local pipeline shares this one
# database and keeps its own dataset, so they land as separate SCHEMAS inside it and can
# be joined locally, which per-pipeline files did not allow.
#
# Passed as an env var rather than set in .dlt/config.toml, because dlt classes a
# destination credential as a secret and refuses to read one from config.toml. Keeping
# it here also means a fresh clone needs no secrets file to run locally.
#
# The path is relative to the repo root (dlt resolves it against the run context's local
# directory, not the current working directory).
DUCKDB_PATH ?= duck-db/local.duckdb
NAME        ?=                                       # pipeline name for the run-* targets
GROUP       ?=                                       # or a pipeline group for `make run-local`
# space-separated subset of NAME's resources: RESOURCE="teams players". Empty = all.
RESOURCE    ?=
RES_FLAGS   := $(foreach r,$(RESOURCE),--resource $(r))
# space-separated query-param overrides, e.g. PARAM="seasons[]=2023 seasons[]=2022".
# A bare KEY=VALUE applies to the single selected RESOURCE. Prefix it to name a
# different one, which is what a parent-child pipeline needs since the filter belongs
# on the resource that lists the parents:
#   PARAM="games_post_ref:seasons[]=2025"
# Single-quoted below so the shell does not treat the brackets as a glob.
PARAM       ?=
PARAM_FLAGS := $(foreach p,$(PARAM),--param '$(p)')

SNOW_CONN   ?=                                       # optional named snow connection

# THREE SNOW INVOCATIONS, ONE PER ROLE. Which role a command runs as is not cosmetic:
# it decides who OWNS what gets created, and ownership is far more awkward to change
# afterwards than to get right the first time.
#
#   SNOW         your connection's default role. For DDL only, where the .sql file
#                picks its own role with USE ROLE (SYSADMIN / USERADMIN / ACCOUNTADMIN).
#   SNOW_DEV     DLT_DEV_ROLE. Ad-hoc dev jobs and the schemas they create.
#   SNOW_LOADER  DLT_LOADER_ROLE. Anything production owns or writes.
#
# SNOW_LOADER exists for two distinct reasons, worth keeping straight:
#
#   OWNERSHIP. A Snowflake Task runs with the privileges of its owner. Applying
#   tasks.sql as SYSADMIN would make every scheduled load run as SYSADMIN, and fixing
#   that later means a GRANT OWNERSHIP per Task rather than a re-run.
#
#   PROVING THE GRANT. sync-apply and the spec uploads confer no ownership, but their
#   privileges (INSERT/UPDATE/DELETE on PIPELINE_REGISTRY, WRITE on @DEPLOY.SPECS) are
#   granted to DLT_LOADER_ROLE alone. Running them as SYSADMIN succeeds by inheritance
#   without ever exercising the grant, so a missing one stays hidden until CI, which
#   authenticates as DLT_DEPLOYER with no inheritance at all.
PROD_ROLE   ?= DLT_LOADER_ROLE
SNOW        := snow sql $(if $(SNOW_CONN),--connection $(SNOW_CONN),)
SNOW_LOADER := snow sql --role $(PROD_ROLE) $(if $(SNOW_CONN),--connection $(SNOW_CONN),)

# Develop-in-Snowflake knobs (see the "Develop in Snowflake" targets)
# role dev jobs run under
DEV_ROLE    ?= DLT_DEV_ROLE
# warehouse the dev role can use
DEV_WH      ?= DLT_DEV_WH
SNOW_DEV    := snow sql --role $(DEV_ROLE) $(if $(SNOW_CONN),--connection $(SNOW_CONN),)
DATASET     ?=                                       # dev schema; empty => DEV_<snowflake_user> from your snow connection
SECRET      ?=                                       # e.g. DLT_DB.OPS.NFL_API_KEY
ENVVAR      ?=                                       # e.g. SOURCES__NFL__API_KEY
EAI         ?=                                       # optional External Access Integration
SPECS_STAGE := @DLT_DB.DEPLOY.SPECS

# Laptop -> Snowflake auth reused from a `snow` CLI connection (no secrets.toml)
CONN        ?=                                       # snow connection name (blank = default_connection_name)
# Destination DB override for run-snowflake. Empty by default: the database is now a
# per-pipeline property resolved from the registry (`database: NFL` -> NFL_DEV_DB), so
# this exists only to force a target, which is also the only way to use GROUP= when a
# group's pipelines could disagree.
SF_DATABASE ?=

# SPCS image build/push. Docker refs must be lowercase, and the tag is the case where
# a trailing space actually breaks something (see the note at the top of this file).
IMAGE       ?= dlt-pipeline:latest
IMAGE_REPO  := /dlt_db/deploy/images
SNOW_CLI    := snow $(if $(SNOW_CONN),--connection $(SNOW_CONN),)

# Terminal banner helper: `@$(call hdr,message)` prints a bold cyan section header.
# (Keep messages comma-free -- commas split $(call) arguments.)
define hdr
printf '\n\033[1;36m== %s ==\033[0m\n' "$(1)"
endef

# Resolve the Snowflake database a pipeline loads into, or stop.
#
# The database is a per-pipeline property (registry `database: NFL` -> NFL_DEV_DB),
# not something typed on the command line. Asking the registry rather than accepting a
# DB= variable is deliberate: a stale `export DB=NFL_DEV_DB` left over from an NFL run
# would silently land an NBA pipeline's data in the NFL database, and nothing
# downstream would notice. A pipeline names its own sport, so that cannot happen.
#
# Same capture-check-use shape as snow_env_or_die below, for the same reason: an empty
# result here would interpolate a blank database into SQL rather than fail.
#
#   $(call resolve_db_or_die,<pipeline>,DEV|PROD)   -> sets $db
define resolve_db_or_die
db="$$($(UV_RUN) python -m pipelines.batch.models --database $(1) --env $(2) 2>&1)"; rc=$$?; \
  if [ $$rc -ne 0 ] || [ -z "$$db" ]; then \
    printf '\033[0;31m✗ could not resolve a database for "%s" (%s): %s\033[0m\n' "$(1)" "$(2)" "$$db"; \
    exit 1; \
  fi
endef

# Resolve the secret binding for a pipeline from the registry, unless it was passed.
#
# The same values a scheduled Task reads. Before this, dev typed SECRET= and ENVVAR=
# on every command while prod read them from the registry, which is two records of one
# fact and an invitation for them to disagree. Explicit SECRET= / ENVVAR= still win, so
# testing an alternate secret needs no registry edit.
#
# Silence is meaningful here: `sample` legitimately declares neither, and a pipeline
# with no secret must still run. So a failed lookup leaves both empty rather than
# aborting, and run-spcs then picks the no-secret template exactly as it always has.
#
#   $(call resolve_secret,<pipeline>)   -> sets $sec and $envvar
define resolve_secret
sec="$(SECRET)"; envvar="$(ENVVAR)"; \
  if [ -z "$$sec" ]; then \
    sec="$$($(UV_RUN) python -m pipelines.batch.models --secret $(1) 2>/dev/null)" || sec=""; \
  fi; \
  if [ -z "$$envvar" ]; then \
    envvar="$$($(UV_RUN) python -m pipelines.batch.models --env-var $(1) 2>/dev/null)" || envvar=""; \
  fi
endef

# Load a snow connection into this shell's environment, or stop.
#
# Do NOT write this as `eval "$$(deploy.snow_env)"`. Command substitution captures
# stdout only, so when the bridge fails you get `eval ""`, which succeeds. The
# recipe then carries on and the pipeline runs with no credentials at all, failing
# much later inside dlt with an error that says nothing about your connection.
#
# Capture first, check the status, evaluate last. The bridge writes its diagnostic
# to stderr, which is left alone so it reaches the terminal.
define snow_env_or_die
exports="$$($(UV_RUN) python -m deploy.snow_env $(CONN))"; rc=$$?; \
  if [ $$rc -ne 0 ]; then \
    printf '\033[0;31m✗ could not resolve Snowflake credentials (see above); aborting\033[0m\n'; \
    exit $$rc; \
  fi; \
  eval "$$exports"
endef

.DEFAULT_GOAL := help

.PHONY: help doctor install secrets setup \
        test test-config lint fmt list plan \
        run-local run-snowflake run-spcs \
        sync-sql tasks-sql tasks-suspend-sql tasks-resume-sql emit \
        setup-base setup-dev setup-prod setup-ops setup-source new-source \
        image-build image-login image-push \
        dev-spec-upload dev-pool-status snow-env \
        sync-apply tasks-apply tasks-suspend tasks-resume deploy \
        clean

help: ## Show this help
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage: make \033[36m<target>\033[0m\n"} \
		/^[a-zA-Z0-9_.-]+:.*?##/ { printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2 } \
		/^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) }' $(MAKEFILE_LIST)
	@echo ""

##@ Environment setup

doctor: ## Check required tooling (uv, docker, snow)
	@echo "Checking tooling..."
	@command -v uv     >/dev/null 2>&1 && echo "  uv:     $$(uv --version)"            || echo "  uv:     MISSING  (install: https://docs.astral.sh/uv/)"
	@command -v docker >/dev/null 2>&1 && echo "  docker: $$(docker --version)"        || echo "  docker: missing  (only needed to build/push the image)"
	@command -v snow   >/dev/null 2>&1 && echo "  snow:   $$(snow --version 2>&1 | head -1)" || echo "  snow:   missing  (only needed for live Snowflake apply)"
	@echo "uv provisions Python >=3.11 automatically from pyproject.toml."

install: ## Install deps into .venv via uv (EXTRAS="dev postgres")
	$(UV) sync $(EXTRA_FLAGS)

secrets: ## Create .dlt/secrets.toml from the example if it does not exist
	@if [ -f .dlt/secrets.toml ]; then \
		echo ".dlt/secrets.toml already exists - leaving it untouched."; \
	else \
		cp .dlt/secrets.toml.example .dlt/secrets.toml; \
		echo "Created .dlt/secrets.toml. You usually don't need to fill the Snowflake"; \
		echo "destination block: 'make run-local' loads to DuckDB, and 'make run-snowflake'"; \
		echo "reuses your snow connection. Fill in only the SOURCE creds you load from."; \
	fi

setup: doctor install secrets ## One-command onboarding (doctor + install + secrets)
	@echo ""
	@echo "Setup complete. Next steps:"
	@echo "  make test                   # run the test suite"
	@echo "  make list                   # show pipelines in the registry"
	@echo "  make run-local NAME=sample  # load a pipeline locally to DuckDB"

##@ Local verify

test: ## Run the full test suite
	$(UV_RUN) pytest -q

test-config: ## Run the pure config unit tests only (no dlt/network)
	$(UV_RUN) pytest tests/test_registry_config.py -q

lint: ## Lint with ruff
	$(UV_RUN) ruff check .

fmt: ## Format with ruff
	$(UV_RUN) ruff format .

list: ## List pipelines declared in registries/*.yml
	DLT_REGISTRY_SOURCE=yaml $(UV_RUN) python -m pipelines.batch.run --list

##@ Docs
# FIX-PLAN.md is the source of truth. The .html is generated and should never be
# hand-edited; regenerate it instead.

plan: ## Render FIX-PLAN.md -> FIX-PLAN.html (self-contained, no network)
	$(UV_RUN) python tools/build_plan.py
	@echo "Wrote FIX-PLAN.html"

##@ Run pipelines
# The suffix says where the data lands. run-local needs nothing; run-snowflake
# needs a snow connection plus setup-base/setup-dev; run-spcs additionally needs
# a pushed image and dev-spec-upload.

run-local: ## laptop -> DuckDB, no credentials (NAME=|GROUP= [RESOURCE="a b"] [PARAM="k=v"] [DEST=])
	@if [ -z "$(NAME)$(GROUP)" ]; then \
		echo "Set NAME=<pipeline> or GROUP=<group>. See 'make list'."; \
		exit 2; \
	fi
	@mkdir -p $(dir $(DUCKDB_PATH))
	DLT_REGISTRY_SOURCE=yaml DLT_DESTINATION=$(DEST) DESTINATION__DUCKDB__CREDENTIALS=$(DUCKDB_PATH) $(UV_RUN) python -m pipelines.batch.run $(if $(GROUP),--group $(GROUP),$(NAME)) $(RES_FLAGS) $(PARAM_FLAGS)

run-snowflake: ## laptop -> Snowflake via a snow connection (NAME=|GROUP= [RESOURCE=] [PARAM=] [CONN=] [DATASET=])
	@if [ -z "$(NAME)$(GROUP)" ]; then \
		echo "Set NAME=<pipeline> or GROUP=<group>. See 'make list'."; \
		exit 2; \
	fi
	@if [ -n "$(GROUP)" ] && [ -z "$(SF_DATABASE)" ]; then \
		echo "GROUP= spans pipelines that may target different databases."; \
		echo "Run them by NAME=, or pass SF_DATABASE= to force one."; \
		exit 2; \
	fi
	@$(call resolve_db_or_die,$(NAME),DEV); \
	  db="$(if $(SF_DATABASE),$(SF_DATABASE),$$db)"; \
	  $(snow_env_or_die); \
	  ds="$(DATASET)"; ds="$${ds:-$$DLT_DEV_DATASET}"; \
	  DLT_REGISTRY_SOURCE=yaml DLT_DESTINATION=snowflake \
	  DESTINATION__SNOWFLAKE__CREDENTIALS__ROLE=$(DEV_ROLE) SNOWFLAKE_ROLE=$(DEV_ROLE) \
	  DESTINATION__SNOWFLAKE__CREDENTIALS__WAREHOUSE=$(DEV_WH) SNOWFLAKE_WAREHOUSE=$(DEV_WH) \
	  DESTINATION__SNOWFLAKE__CREDENTIALS__DATABASE="$$db" DLT_DATASET="$$ds" \
	  $(UV_RUN) python -m pipelines.batch.run $(if $(GROUP),--group $(GROUP),$(NAME)) $(RES_FLAGS) $(PARAM_FLAGS) && \
	  echo "Ran '$(if $(GROUP),group $(GROUP),$(NAME))'$(if $(RESOURCE), resources [$(RESOURCE)],)$(if $(PARAM), params [$(PARAM)],) -> $$db.$$ds as $(DEV_ROLE) using snow connection '$(CONN)'."

# The container entrypoint is `python -m pipelines.batch.run`, so RESOURCE and PARAM
# are the same CLI flags run-local and run-snowflake pass; they just have to travel
# through the job spec to get there. The spec templates take one `args` variable
# holding the whole argv as a JSON array (see deploy/spcs/dlt_dev_job.tmpl.yaml for
# why it is one variable rather than several).
#
# The array is assembled by json.dumps rather than by concatenating strings here. One
# token per line into stdin is the only version of this that stays correct for values
# containing brackets, spaces or equals signs, and PARAM contains all three:
# `seasons[]=2023` would be glob-expanded by the shell and split by a naive join.
#
# CLAUSE ORDER IS FIXED. EXECUTE JOB SERVICE takes its properties in a set order and
# the parser does not accept them rearranged:
#
#   IN COMPUTE POOL -> NAME -> [ASYNC|QUERY_WAREHOUSE|COMMENT|EXTERNAL_ACCESS_INTEGRATIONS]
#   -> FROM <stage> -> SPECIFICATION_TEMPLATE_FILE -> USING
#
# EXTERNAL_ACCESS_INTEGRATIONS therefore goes BEFORE `FROM`, not after the template
# file. Putting it last is a plain SQL compilation error, and only for runs that pass
# EAI=, so a pipeline needing no egress hides the mistake completely.
run-spcs: ## Snowflake container -> Snowflake dev schema (NAME= [RESOURCE=] [PARAM=] [DATASET=]; secret/EAI come from the registry)
	@if [ -z "$(NAME)" ]; then echo "Set NAME=<pipeline>. See 'make list'."; exit 2; fi
	@if [ -n "$(SECRET)" ] && [ -z "$(ENVVAR)" ]; then \
		echo "SECRET set but ENVVAR missing. Override both or neither, e.g.:"; \
		echo "  make run-spcs NAME=nfl_reference SECRET=DLT_DB.OPS.NFL_API_KEY ENVVAR=SOURCES__NFL__API_KEY"; \
		exit 2; \
	fi
	@$(call hdr,SPCS run '$(NAME)')
	@$(call resolve_db_or_die,$(NAME),DEV); \
	  $(call resolve_secret,$(NAME)); \
	  eai="$(EAI)"; \
	  if [ -z "$$eai" ]; then \
	    eai="$$($(UV_RUN) python -m pipelines.batch.models --external-access $(NAME) 2>/dev/null)" || eai=""; \
	  fi; \
	  $(snow_env_or_die); \
	  ds="$(DATASET)"; ds="$${ds:-$$DLT_DEV_DATASET}"; \
	  args_json=$$(printf '%s\n' "$(NAME)" $(RES_FLAGS) $(PARAM_FLAGS) \
	    | python3 -c 'import sys, json; print(json.dumps(sys.stdin.read().splitlines()))'); \
	  if [ -n "$$sec" ]; then \
	    tmpl='dlt_dev_job.tmpl.yaml'; \
	    using="USING (args => '$$args_json', database => '\"$$db\"', dataset => '\"$$ds\"', secret => '\"$$sec\"', env_var => '\"$$envvar\"')"; \
	  else \
	    tmpl='dlt_dev_job_nosecret.tmpl.yaml'; \
	    using="USING (args => '$$args_json', database => '\"$$db\"', dataset => '\"$$ds\"')"; \
	  fi; \
	  printf '  \033[2margs=%s target=%s.%s template=%s\033[0m\n' "$$args_json" "$$db" "$$ds" "$$tmpl"; \
	  $(SNOW_DEV) -q "DROP SERVICE IF EXISTS DLT_DB.DEPLOY.dlt_dev_$(NAME);" >/dev/null 2>&1 || true; \
	  $(SNOW_DEV) -q "EXECUTE JOB SERVICE IN COMPUTE POOL DLT_DEV_POOL NAME = DLT_DB.DEPLOY.dlt_dev_$(NAME) $${eai:+EXTERNAL_ACCESS_INTEGRATIONS = ($$eai) }FROM $(SPECS_STAGE) SPECIFICATION_TEMPLATE_FILE='$$tmpl' $$using;" \
	    && printf '\033[0;32m✓ SPCS run complete -> %s.%s\033[0m\n' "$$db" "$$ds" \
	    || { printf '\033[0;31m✗ SPCS run failed\033[0m\n'; exit 1; }

##@ Snowflake artifacts (offline, no connection)

build:
	@mkdir -p build

sync-sql: build ## Emit registry sync SQL -> build/sync.sql
	$(UV_RUN) python -m pipelines.batch.registry_sync --emit-sql --prune > build/sync.sql
	@echo "Wrote build/sync.sql"

tasks-sql: build ## Emit per-pipeline Task DDL -> build/tasks.sql
	$(UV_RUN) python -m deploy.tasks.generate_tasks > build/tasks.sql
	@echo "Wrote build/tasks.sql"

tasks-suspend-sql: build ## Emit ALTER TASK ... SUSPEND -> build/suspend.sql
	$(UV_RUN) python -m deploy.tasks.generate_tasks --suspend > build/suspend.sql
	@echo "Wrote build/suspend.sql"

tasks-resume-sql: build ## Emit ALTER TASK ... RESUME -> build/resume.sql
	$(UV_RUN) python -m deploy.tasks.generate_tasks --resume > build/resume.sql
	@echo "Wrote build/resume.sql"

emit: sync-sql tasks-sql ## Emit both sync.sql and tasks.sql

##@ Snowflake setup (live; requires a snow connection)
# Dev is the primary path for developers. Run setup-base once, then setup-dev.
# setup-prod is a separate, customer-tailored flow you run when ready to schedule
# production loads.

setup-base: ## Apply shared control-plane DDL sql/base/* (guard: CONFIRM=1)
	@if [ "$(CONFIRM)" != "1" ]; then \
		echo "Creates roles (DLT_LOADER_ROLE, DLT_DEV_ROLE) + DLT_DB control plane"; \
		echo "(registry table, image repo, spec stage, source EAI + secret)."; \
		echo "Re-run with CONFIRM=1"; \
		echo "(optionally SNOW_CONN=<connection>)."; \
		exit 2; \
	fi
	@for f in sql/base/*.sql; do echo "== applying $$f =="; $(SNOW) -f $$f || exit 1; done
	@echo "Base control plane ready. Next (primary): make setup-dev. For scheduled prod later: make setup-prod."

setup-dev: ## Apply development DDL sql/dev/* -- the primary developer path (guard: CONFIRM=1)
	@if [ "$(CONFIRM)" != "1" ]; then \
		echo "Creates DLT_DEV_DB (per-developer schemas), DLT_DEV_POOL, DLT_DEV_WH."; \
		echo "This is where developers work. Re-run with CONFIRM=1  (optionally SNOW_CONN=<connection>)."; \
		exit 2; \
	fi
	@for f in sql/dev/*.sql; do echo "== applying $$f =="; $(SNOW) -f $$f || exit 1; done
	@echo "Dev ready. Grant DLT_DEV_ROLE to developers, then: make dev-spec-upload and make run-spcs."

# A glob, not a file list. An explicit list silently skips any file added later, which
# is how sql/sources/ nearly got missed. The one file that must NOT run unattended,
# 03b_service_user_oidc.sql, carries unresolved <owner>/<repo> placeholders and lives
# in sql/prod/optional/ precisely so this glob cannot pick it up.
setup-prod: ## Apply production DDL sql/prod/* -- tailor to the customer's needs first (guard: CONFIRM=1)
	@if [ "$(CONFIRM)" != "1" ]; then \
		echo "Production is a separate, customer-specific flow. Review warehouse sizing,"; \
		echo "multi-cluster, and scheduling in sql/prod/* before applying."; \
		echo "Creates DLT_PROD_DB, DLT_POOL, DLT_WH, the DLT_LOADER service user (key-pair),"; \
		echo "and DLT_DEPLOYER (03b: keyless GitHub OIDC for CI, plus its network policy)."; \
		echo "03b's SUBJECT names a specific repo and GitHub environment -- check it matches"; \
		echo "yours before applying, or CI authentication will fail."; \
		echo "Re-run with CONFIRM=1."; \
		exit 2; \
	fi
	@for f in sql/prod/*.sql; do echo "== applying $$f =="; $(SNOW) -f $$f || exit 1; done
	@echo "Prod ready. Next: make deploy (sync registry + apply Tasks)."

# Everything specific to one upstream API: its two databases, its external access
# integration and its secret. setup-base/dev/prod build only what is genuinely shared
# (roles, control plane, registry table, compute), so `make setup-base` no longer
# hands an adopter somebody else's API credential.
#
# This is the one setup target you run more than once, once per source.
setup-ops: ## Apply observability DDL sql/ops/* -- event table + binding (guard: CONFIRM=1)
	@if [ "$(CONFIRM)" != "1" ]; then \
		echo "Creates DLT_OPS_WH and the DLT_DB.OPS.DLT_EVENTS event table, and binds"; \
		echo "it to DLT_DB so every SPCS job writes telemetry there instead of to the"; \
		echo "shared SNOWFLAKE.TELEMETRY.EVENTS. Rows already in the shared table stay"; \
		echo "there: history splits at this point."; \
		echo "Needs ACCOUNTADMIN for the ALTER DATABASE ... SET EVENT_TABLE."; \
		echo "Requires setup-base. Re-run with CONFIRM=1"; \
		echo "(optionally SNOW_CONN=<connection>)."; \
		exit 2; \
	fi
	@for f in sql/ops/*.sql; do echo "== applying $$f =="; $(SNOW) -f $$f || exit 1; done
	@echo "Observability ready, but NOT yet in effect on any warm compute pool."
	@echo "  1. snow sql -q \"SHOW PARAMETERS LIKE 'EVENT_TABLE' IN ACCOUNT;\"   -- level must read ACCOUNT"
	@echo "     (check ACCOUNT, not DATABASE: SPCS ignores the database-level binding)"
	@echo "  2. Cycle any pool with live nodes, or the old routing persists:"
	@echo "     snow sql -q \"ALTER COMPUTE POOL DLT_DEV_POOL SUSPEND;\"   -- auto_resume brings it back"
	@echo "  3. make run-spcs NAME=sample, then confirm rows land in DLT_DB.OPS.DLT_EVENTS"
	@echo "     while MAX(TIMESTAMP) in SNOWFLAKE.TELEMETRY.EVENTS stays put."

setup-source: ## Apply one source's DDL sql/sources/$(SOURCE)/* (SOURCE=nfl, guard: CONFIRM=1)
	@if [ -z "$(SOURCE)" ]; then \
		echo "Set SOURCE=<name>, e.g. make setup-source SOURCE=nfl CONFIRM=1"; \
		echo "Available: $$(ls -d sql/sources/*/ 2>/dev/null | xargs -n1 basename | tr '\n' ' ')"; \
		echo "New one?   make new-source NAME=<name> HOST=api.example.com"; \
		exit 2; \
	fi
	@if [ ! -d "sql/sources/$(SOURCE)" ]; then \
		echo "No DDL for source '$(SOURCE)'. Scaffold it:"; \
		echo "  make new-source NAME=$(SOURCE) HOST=api.example.com"; \
		exit 2; \
	fi
	@if [ "$(CONFIRM)" != "1" ]; then \
		echo "Creates $$(echo $(SOURCE) | tr a-z A-Z)_DEV_DB and $$(echo $(SOURCE) | tr a-z A-Z)_PROD_DB,"; \
		echo "its external access integration, and its API-key secret."; \
		echo "Requires setup-base (roles + control plane) first. Re-run with CONFIRM=1."; \
		exit 2; \
	fi
	@for f in sql/sources/$(SOURCE)/*.sql; do echo "== applying $$f =="; $(SNOW) -f $$f || exit 1; done
	@echo "Source '$(SOURCE)' ready. Set the real API key, which no DDL can do:"
	@echo "  ALTER SECRET DLT_DB.OPS.$$(echo $(SOURCE) | tr a-z A-Z)_API_KEY SET SECRET_STRING = '<key>';"
	@echo "Then: make sync-apply, then make run-spcs NAME=<pipeline>."

new-source: ## Scaffold SQL + registry for a new upstream API (NAME=weather [HOST=api.weather.com])
	@if [ -z "$(NAME)" ]; then \
		echo "Set NAME=<source>, e.g. make new-source NAME=weather HOST=api.weather.example"; \
		exit 2; \
	fi
	@$(UV_RUN) python tools/new_source.py $(NAME) $(if $(HOST),--host $(HOST),)

##@ Develop in Snowflake

# THE SPEC STAGE IS DEV-ONLY, WHICH LOOKS LIKE AN OVERSIGHT AND IS NOT.
#
# Production used to stage its template too, and let Snowflake render it server-side.
# That failed for every Task: the renderer resolves a dependency through
# snowflake.snowpark.pypi_shared_repository, which the Task's role could not reach.
# generate_tasks.py now renders locally and inlines the spec into each Task, so there
# is no prod template to upload. See deploy/tasks/generate_tasks.py section 1.
#
# Dev still stages its two, because `run-spcs` submits interactively where the
# renderer works, and staging keeps the spec editable without regenerating anything.
dev-spec-upload: ## Upload the dev job spec templates (with- and no-secret) to @DLT_DB.DEPLOY.SPECS
	@$(call hdr,Upload dev spec templates -> @DLT_DB.DEPLOY.SPECS)
	@mkdir -p build
	@$(SNOW_LOADER) -q "PUT file://deploy/spcs/dlt_dev_job.tmpl.yaml $(SPECS_STAGE) AUTO_COMPRESS=FALSE OVERWRITE=TRUE;" > build/spec.out 2>&1 \
	  && $(SNOW_LOADER) -q "PUT file://deploy/spcs/dlt_dev_job_nosecret.tmpl.yaml $(SPECS_STAGE) AUTO_COMPRESS=FALSE OVERWRITE=TRUE;" >> build/spec.out 2>&1 \
	  && printf '\033[0;32m✓ uploaded dlt_dev_job.tmpl.yaml + dlt_dev_job_nosecret.tmpl.yaml\033[0m\n' \
	  || { printf '\033[0;31m✗ upload failed\033[0m\n'; cat build/spec.out; exit 1; }

snow-env: ## Print export lines for a snow connection, e.g. eval "$(make snow-env CONN=innovation-igloo)"
	@$(UV_RUN) python -m deploy.snow_env $(CONN)

dev-pool-status: ## Show DLT_DEV_POOL state (must be ACTIVE/IDLE before run-spcs)
	@$(call hdr,DLT_DEV_POOL status)
	@$(SNOW) --format json -q "DESCRIBE COMPUTE POOL DLT_DEV_POOL" 2>/dev/null \
	  | python3 -c 'import sys,json; d=json.load(sys.stdin); r=d[0] if isinstance(d,list) else d; print("  state:", r.get("state"), " nodes: active="+str(r.get("active_nodes")), "idle="+str(r.get("idle_nodes")), "min="+str(r.get("min_nodes")), "max="+str(r.get("max_nodes")))' \
	  || echo "  (could not read pool state)"

##@ SPCS image

image-build: ## Build the SPCS image (linux/amd64; Docker required)
	@echo "Building linux/amd64 (required by SPCS x86_64 pools)."
	@echo "On Apple Silicon this emulates via QEMU and is slow -- prefer the CI"
	@echo "image build (.github/workflows/deploy.yml) on an amd64 runner."
	docker build --platform linux/amd64 --load -f deploy/spcs/Dockerfile -t $(IMAGE) .

image-login: ## Docker-login to the Snowflake image registry via snow
	$(SNOW_CLI) spcs image-registry login

image-push: image-build image-login ## Build + push the image to DLT_DB.DEPLOY.IMAGES
	@host="$$($(SNOW_CLI) spcs image-registry url)"; \
	  target="$$host$(IMAGE_REPO)/$(IMAGE)"; \
	  echo "Pushing to $$target"; \
	  docker tag $(IMAGE) "$$target" && docker push "$$target"

##@ Snowflake apply (live; requires a snow connection)

sync-apply: sync-sql ## Apply build/sync.sql to the account
	@$(call hdr,Sync registry -> DLT_DB.OPS.PIPELINE_REGISTRY)
	@$(SNOW_LOADER) -f build/sync.sql > build/sync.out 2>&1 \
	  && printf '\033[0;32m✓ synced %s pipeline(s)\033[0m \033[2m(full log: build/sync.out)\033[0m\n' "$$(grep -c 'MERGE INTO' build/sync.sql)" \
	  || { printf '\033[0;31m✗ sync failed\033[0m\n'; cat build/sync.out; exit 1; }

tasks-apply: tasks-sql ## Apply build/tasks.sql to the account
	@$(call hdr,Apply per-pipeline Tasks)
	@$(SNOW_LOADER) -f build/tasks.sql > build/tasks.out 2>&1 \
	  && printf '\033[0;32m✓ applied %s task(s)\033[0m \033[2m(full log: build/tasks.out)\033[0m\n' "$$(grep -c 'CREATE OR ALTER TASK' build/tasks.sql)" \
	  || { printf '\033[0;31m✗ tasks apply failed\033[0m\n'; cat build/tasks.out; exit 1; }

# SUSPEND BEFORE APPLY IS MANDATORY, NOT TIDINESS.
#   CREATE OR ALTER TASK fails on a task that is started, with
#   `091421 (22000): Unable to update graph with root task <name> since that root
#   task is not suspended`, and changes nothing. `snow sql -f` stops at the first
#   error, so a fleet whose first task is running aborts before the rest are even
#   attempted: some Tasks carry the new spec, some the old, and the output does not
#   say which. Measured against the live 17-Task fleet on 2026-08-08.
tasks-suspend: tasks-suspend-sql ## Suspend every Task (run BEFORE tasks-apply)
	@$(call hdr,Suspend per-pipeline Tasks)
	@$(SNOW_LOADER) -f build/suspend.sql > build/suspend.out 2>&1 \
	  && printf '\033[0;32m✓ suspended %s task(s)\033[0m \033[2m(full log: build/suspend.out)\033[0m\n' "$$(grep -c 'ALTER TASK' build/suspend.sql)" \
	  || { printf '\033[0;31m✗ suspend failed\033[0m\n'; cat build/suspend.out; exit 1; }

tasks-resume: tasks-resume-sql ## Resume every Task (run AFTER tasks-apply)
	@$(call hdr,Resume per-pipeline Tasks)
	@$(SNOW_LOADER) -f build/resume.sql > build/resume.out 2>&1 \
	  && printf '\033[0;32m✓ resumed %s task(s)\033[0m \033[2m(full log: build/resume.out)\033[0m\n' "$$(grep -c 'ALTER TASK' build/resume.sql)" \
	  || { printf '\033[0;31m✗ resume failed\033[0m\n'; cat build/resume.out; exit 1; }

# Order is load bearing and the three steps are not independently useful:
# suspend -> apply -> resume. Leaving any one out leaves the fleet either
# half-applied or stopped, and stopped looks exactly like success.
deploy: sync-apply tasks-suspend tasks-apply tasks-resume ## Sync registry + suspend, apply and resume Tasks
	@echo "Deployed. Confirm every Task is running, because suspended looks like success:"
	@echo "  snow sql --role $(PROD_ROLE) -q \"SHOW TASKS IN SCHEMA DLT_DB.OPS;\""

##@ Cleanup

clean: ## Remove .venv, build artifacts, caches, and local DuckDB files
	rm -rf .venv build .pytest_cache
	find . -type d -name __pycache__ -prune -exec rm -rf {} +
	# duck-db/ is where run-local writes now; the loose *.duckdb are older runs that
	# predate it. Both are disposable and regenerate on the next local run.
	rm -rf duck-db
	rm -f *.duckdb
