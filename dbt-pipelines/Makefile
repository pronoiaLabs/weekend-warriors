# Makefile for dbt-pipelines
#
# The dbt project's lifecycle runs INSIDE Snowflake (EXECUTE DBT PROJECT), so
# these targets wrap `snow dbt` rather than local dbt Core, which this project
# does not support. Quickstart:
#   make deploy-dev                 # upload code to the shared dev object
#   make build-dev ENV=wnba_dev     # run a dev build as yourself
#   make deploy-sport SPORT=wnba    # upload code to a sport's prod object
#
# THREE PROJECT OBJECTS, ONE SOURCE TREE. Concurrent EXECUTE DBT PROJECT
# calls against one object are unsupported, and the per-sport trigger tasks
# (dlt-pipelines/sql/sources/<sport>/05_dbt_trigger.sql) can fire at the same
# time, so each sport gets its own object:
#   DLT_DB.DEPLOY.CORTEX_LIFECYCLE          interactive + dev builds
#   DLT_DB.DEPLOY.CORTEX_LIFECYCLE_NFL      prod, fired by DBT_BUILD_NFL
#   DLT_DB.DEPLOY.CORTEX_LIFECYCLE_WNBA     prod, fired by DBT_BUILD_WNBA
# Deploying is how code reaches prod: the triggers always run whatever the
# sport object holds, so `make deploy-sport` for each sport after merging
# model changes IS the release step.

SNOW      ?= snow
CONN      ?= weekend-warriors
# CI overrides with CONN_ARGS=-x: the deploy workflow authenticates via OIDC
# env vars (a temporary connection), not a named connections.toml entry.
CONN_ARGS ?= -c $(CONN)
SNOW_DBT  := $(SNOW) dbt
EAI       := dbt_ext_access

DEV_FQN   := DLT_DB.DEPLOY.CORTEX_LIFECYCLE

# Terminal banner helper: `@$(call hdr,message)` prints a bold cyan section header.
define hdr
printf '\n\033[1;36m== %s ==\033[0m\n' "$(1)"
endef

# The prod environment name is per sport and grandfathered for NFL: the first
# sport's env was named plain `prod` before wnba_prod set the <sport>_prod
# pattern. New sports follow the pattern (see tools/new_source.py scaffold).
define sport_env
$(if $(filter nfl,$(1)),prod,$(1)_prod)
endef

.DEFAULT_GOAL := help

help: ## Show this help
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z_-]+:.*?##/ { printf "  \033[36m%-24s\033[0m %s\n", $$1, $$2 } \
		/^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) }' $(MAKEFILE_LIST)

##@ Deploy project objects

deploy-dev: ## Upload the source tree to the shared dev object
	@$(call hdr,deploy $(DEV_FQN))
	$(SNOW_DBT) deploy $(DEV_FQN) $(CONN_ARGS) --source . \
		--default-env dev --external-access-integration $(EAI) --force

# The trailing GRANTs are load-bearing, not belt-and-suspenders:
#
# USAGE: `snow dbt deploy --force` is a CREATE OR REPLACE, and replacing the
# object DROPS its grants. The DBT_BUILD_<SPORT> trigger task runs as
# DBT_RUNNER_ROLE (primary role alone), so without USAGE re-granted here every
# triggered build fails with "does not exist or not authorized" until the task
# auto-suspends after the consecutive-failure threshold. Cost one two-day prod
# outage (Aug 2026) to learn.
#
# OWNERSHIP: CI (deploy.yml) deploys as DBT_RUNNER_ROLE while the laptop
# deploys as SYSADMIN, and CREATE OR REPLACE requires owning the existing
# object. Normalizing ownership to DBT_RUNNER_ROLE after every deploy makes
# both paths converge, so neither strands the other's next deploy. (SYSADMIN
# still deploys fine: it inherits DBT_RUNNER_ROLE through the role hierarchy.)
deploy-sport: ## Upload the source tree to a sport's prod object (SPORT=nfl|wnba|ncaaf)
	@test -n "$(SPORT)" || { echo "usage: make deploy-sport SPORT=nfl|wnba|ncaaf"; exit 1; }
	@$(call hdr,deploy $(DEV_FQN)_$(shell echo $(SPORT) | tr a-z A-Z))
	$(SNOW_DBT) deploy $(DEV_FQN)_$(shell echo $(SPORT) | tr a-z A-Z) $(CONN_ARGS) --source . \
		--default-env $(call sport_env,$(SPORT)) --external-access-integration $(EAI) --force
	$(SNOW) sql $(CONN_ARGS) -q "GRANT USAGE ON DBT PROJECT $(DEV_FQN)_$(shell echo $(SPORT) | tr a-z A-Z) TO ROLE DBT_RUNNER_ROLE"
	$(SNOW) sql $(CONN_ARGS) -q "GRANT OWNERSHIP ON DBT PROJECT $(DEV_FQN)_$(shell echo $(SPORT) | tr a-z A-Z) TO ROLE DBT_RUNNER_ROLE COPY CURRENT GRANTS"

deploy-all: deploy-dev ## Deploy dev + every sport object
	@$(MAKE) deploy-sport SPORT=nfl
	@$(MAKE) deploy-sport SPORT=wnba
	@$(MAKE) deploy-sport SPORT=ncaaf

##@ Run builds by hand

build-dev: ## Dev build as yourself (ENV=dev|wnba_dev, default dev)
	@$(call hdr,build $(or $(ENV),dev) on $(DEV_FQN))
	$(SNOW_DBT) execute $(CONN_ARGS) --env $(or $(ENV),dev) $(DEV_FQN) build

build-sport: ## Prod build on a sport's object, as the connection's role (SPORT=nfl|wnba)
	@test -n "$(SPORT)" || { echo "usage: make build-sport SPORT=nfl|wnba"; exit 1; }
	@$(call hdr,build $(call sport_env,$(SPORT)) on $(DEV_FQN)_$(shell echo $(SPORT) | tr a-z A-Z))
	$(SNOW_DBT) execute $(CONN_ARGS) --env $(call sport_env,$(SPORT)) \
		$(DEV_FQN)_$(shell echo $(SPORT) | tr a-z A-Z) build

##@ Deploy agents

# The --args value must carry EMBEDDED quotes: the CLI reassembles the dbt
# command line without re-quoting, and the space inside the YAML splits the
# token server-side ("String '{alter:' is not valid YAML"). This target is
# the single home for that trick and for the sport->env mapping; deploy.yml's
# agents job calls it rather than spelling the args inline.
deploy-agent: ## Redeploy a sport's analyst agent in place (SPORT=nfl|wnba|ncaaf)
	@test -n "$(SPORT)" || { echo "usage: make deploy-agent SPORT=nfl|wnba|ncaaf"; exit 1; }
	@$(call hdr,deploy agent $(SPORT)_analyst via $(call sport_env,$(SPORT)))
	$(SNOW_DBT) execute $(CONN_ARGS) --env $(call sport_env,$(SPORT)) \
		$(DEV_FQN)_$(shell echo $(SPORT) | tr a-z A-Z) \
		run-operation deploy_$(SPORT)_analyst --args "'{alter: true}'"

##@ Snowpark procedures (snowpark/)

# Procedures dbt calls from hooks. Each is a snow snowpark project under
# snowpark/<name>/ whose snowflake.yml is the source of truth for the CREATE
# PROCEDURE; `snow snowpark deploy --replace` is a CREATE OR REPLACE and, like
# the dbt object, DROPS the grants, so the USAGE re-grants below are load-
# bearing: the prod trigger task calls the procedure as DBT_RUNNER_ROLE
# (primary role alone) through bridge_player_ids' pre_hook. Ownership is
# normalized for the same reason deploy-sport does it: CI deploys as
# DBT_RUNNER_ROLE, the laptop as SYSADMIN.
SNOWPARK_DIR := snowpark
BRIDGE_PROC  := DLT_DB.DEPLOY.SP_PLAYER_BRIDGE(VARCHAR, VARCHAR, BOOLEAN)

snowpark-test: ## Lint + unit tests for the Snowpark procedures (pure Python, no Snowflake)
	cd $(SNOWPARK_DIR) && uv run --extra dev ruff check . && uv run --extra dev pytest -q

deploy-snowpark: ## Build, upload and CREATE OR REPLACE SP_PLAYER_BRIDGE, then re-grant
	@$(call hdr,deploy $(BRIDGE_PROC))
	# build takes CONN_ARGS too: newer snow CLI releases resolve requirements
	# against the Anaconda channel over a connection, and CI has only the -x
	# temporary connection (no default) -- without it the build step dies with
	# "Connection default is not configured" (bit 2026-08-28).
	cd $(SNOWPARK_DIR)/player_bridge && $(SNOW) snowpark build $(CONN_ARGS) && $(SNOW) snowpark deploy $(CONN_ARGS) --replace
	$(SNOW) sql $(CONN_ARGS) -q "GRANT USAGE ON PROCEDURE $(BRIDGE_PROC) TO ROLE DBT_RUNNER_ROLE"
	$(SNOW) sql $(CONN_ARGS) -q "GRANT USAGE ON PROCEDURE $(BRIDGE_PROC) TO ROLE DLT_DEV_ROLE"
	$(SNOW) sql $(CONN_ARGS) -q "GRANT OWNERSHIP ON PROCEDURE $(BRIDGE_PROC) TO ROLE DBT_RUNNER_ROLE COPY CURRENT GRANTS"
