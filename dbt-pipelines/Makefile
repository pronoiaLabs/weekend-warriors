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
	$(SNOW_DBT) deploy $(DEV_FQN) -c $(CONN) --source . \
		--default-env dev --external-access-integration $(EAI) --force

deploy-sport: ## Upload the source tree to a sport's prod object (SPORT=nfl|wnba)
	@test -n "$(SPORT)" || { echo "usage: make deploy-sport SPORT=nfl|wnba"; exit 1; }
	@$(call hdr,deploy $(DEV_FQN)_$(shell echo $(SPORT) | tr a-z A-Z))
	$(SNOW_DBT) deploy $(DEV_FQN)_$(shell echo $(SPORT) | tr a-z A-Z) -c $(CONN) --source . \
		--default-env $(call sport_env,$(SPORT)) --external-access-integration $(EAI) --force

deploy-all: deploy-dev ## Deploy dev + every sport object
	@$(MAKE) deploy-sport SPORT=nfl
	@$(MAKE) deploy-sport SPORT=wnba

##@ Run builds by hand

build-dev: ## Dev build as yourself (ENV=dev|wnba_dev, default dev)
	@$(call hdr,build $(or $(ENV),dev) on $(DEV_FQN))
	$(SNOW_DBT) execute -c $(CONN) --env $(or $(ENV),dev) $(DEV_FQN) build

build-sport: ## Prod build on a sport's object, as the connection's role (SPORT=nfl|wnba)
	@test -n "$(SPORT)" || { echo "usage: make build-sport SPORT=nfl|wnba"; exit 1; }
	@$(call hdr,build $(call sport_env,$(SPORT)) on $(DEV_FQN)_$(shell echo $(SPORT) | tr a-z A-Z))
	$(SNOW_DBT) execute -c $(CONN) --env $(call sport_env,$(SPORT)) \
		$(DEV_FQN)_$(shell echo $(SPORT) | tr a-z A-Z) $(if $(filter nfl,$(SPORT)),run,build)
