# Makefile for ops-dashboard
#
# Quickstart:
#   make install   # api deps (uv) + web deps (npm)
#   make dev-api   # FastAPI with reload on :8000
#   make dev-web   # Vite dev server proxying /api to :8000

UV      ?= uv
UV_RUN  := $(UV) run --extra dev

# Image tag = short git SHA. NEVER latest: ALTER SERVICE only rolls when the
# rendered spec text changes, and a fixed tag makes every push a silent no-op.
TAG        ?= $(shell git rev-parse --short HEAD)
IMAGE      := ops-dashboard:$(TAG)
IMAGE_REPO := /dlt_db/deploy/images

# Optional connection override: `make image-push SNOW_CONN=other`.
SNOW_CONN ?=
SNOW_CLI := snow $(if $(SNOW_CONN),--connection $(SNOW_CONN),)
# For SQL files that pick their own role via USE ROLE.
SNOW := $(SNOW_CLI) sql

# Repo-root Snowflake Postgres env. Live targets source PGHOST / APP_API_PASSWORD.
# The API logs in as app_api. OPS_DASHBOARD_BACKEND=snowflake skips this.
POSTGRES_ENV ?= ../.env.postgres

# Terminal banner helper: `@$(call hdr,message)` prints a bold cyan section header.
# (Keep messages comma-free -- commas split $(call) arguments.)
define hdr
printf '\n\033[1;36m== %s ==\033[0m\n' "$(1)"
endef

define with_live_env
set -a; \
if [ "$${OPS_DASHBOARD_BACKEND:-postgres}" != "snowflake" ] && [ -f "$(POSTGRES_ENV)" ]; then \
  . "$(POSTGRES_ENV)"; \
fi; \
set +a
endef

.DEFAULT_GOAL := help

.PHONY: help install dev dev-fixtures dev-api dev-api-fixtures dev-web serve \
        test test-live lint build smoke schema fixtures \
        setup spec-upload image-build image-login image-push \
        deploy endpoint service-status service-logs

# The fixture snapshot's era: every "last N days" window is measured from this
# pin when serving fixtures, the same literal tests/conftest.py uses.
FIXTURE_NOW := 2026-08-09T18:00:00+00:00

help: ## Show this help
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage: make \033[36m<target>\033[0m\n"} \
		/^[a-zA-Z0-9_.-]+:.*?##/ { printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2 } \
		/^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) }' $(MAKEFILE_LIST)
	@echo ""

##@ Development

install: ## Install api (uv) and web (npm) dependencies
	@$(call hdr,api dependencies)
	cd api && $(UV) sync --extra dev
	@$(call hdr,web dependencies)
	cd web && npm install

dev: ## Run the API (:8000, live Postgres) and the Vite dev server (:5173) together
	@$(call hdr,api on :8000 and web on :5173)
	@trap 'kill 0' EXIT; \
	  ( $(with_live_env); cd api && OPS_DASHBOARD_BACKEND=$${OPS_DASHBOARD_BACKEND:-postgres} $(UV_RUN) uvicorn app.main:app --reload --port 8000 ) & \
	  (cd web && npm run dev) & \
	  wait

dev-fixtures: ## The same on recorded fixtures, no database connection
	@$(call hdr,api on :8000 [fixtures] and web on :5173)
	@trap 'kill 0' EXIT; \
	  (cd api && OPS_DASHBOARD_DATA=fixtures OPS_DASHBOARD_NOW=$(FIXTURE_NOW) $(UV_RUN) uvicorn app.main:app --reload --port 8000) & \
	  (cd web && npm run dev) & \
	  wait

dev-api: ## Run FastAPI with reload on :8000 (live data as app_api)
	@$(with_live_env); \
	cd api && OPS_DASHBOARD_BACKEND=$${OPS_DASHBOARD_BACKEND:-postgres} $(UV_RUN) uvicorn app.main:app --reload --port 8000

dev-api-fixtures: ## Run FastAPI on :8000 against recorded fixtures (no Snowflake)
	cd api && OPS_DASHBOARD_DATA=fixtures OPS_DASHBOARD_NOW=$(FIXTURE_NOW) $(UV_RUN) uvicorn app.main:app --reload --port 8000

dev-web: ## Run the Vite dev server (proxies /api to :8000)
	cd web && npm run dev

serve: build ## Build the web app and serve api + web together on :8000
	@$(call hdr,dashboard on http://localhost:8000)
	@$(with_live_env); \
	cd api && OPS_DASHBOARD_BACKEND=$${OPS_DASHBOARD_BACKEND:-postgres} $(UV_RUN) uvicorn app.main:app --port 8000

##@ Quality

test: ## Run the api test suite (fixture mode; live tests skipped)
	cd api && $(UV_RUN) pytest -q

test-live: ## The suite plus the live contract test against Postgres
	@$(with_live_env); \
	cd api && OPS_DASHBOARD_LIVE=1 OPS_DASHBOARD_BACKEND=$${OPS_DASHBOARD_BACKEND:-postgres} $(UV_RUN) pytest -q

lint: ## Ruff on the api + type-check the web (tsc -b: the root tsconfig only holds references)
	@$(call hdr,api ruff)
	cd api && $(UV_RUN) ruff check .
	@$(call hdr,web tsc)
	cd web && npx tsc -b

build: ## Production build of the web app into web/dist
	cd web && npm run build

smoke: build ## Walk every route in headless Chrome against fixtures; fails on console errors
	./scripts/smoke.sh

##@ Fixtures (live reads of DLT_DB.OPS through the snow connection)

schema: ## Record DESCRIBE of every object the datasource reads into api/app/fixtures/schema/
	cd api && OPS_DASHBOARD_BACKEND=snowflake $(UV_RUN) python scripts/capture_fixtures.py schema

fixtures: ## Re-snapshot the row fixtures (CONFIRM=1: the endpoint tests pin the current snapshot)
	@if [ "$(CONFIRM)" != "1" ]; then \
		echo "Replaces api/app/fixtures/*.json with a fresh snapshot. The endpoint tests and"; \
		echo "FIXTURE_NOW pin the current one, so re-pin them in the same change."; \
		echo "Re-run with CONFIRM=1"; \
		exit 2; \
	fi
	cd api && $(UV_RUN) python scripts/capture_fixtures.py rows

##@ Snowflake setup (live; run by a human, never CI)

setup: ## Apply deploy/sql/*.sql: role, pool, service (CONFIRM=1 required)
	@if [ "$(CONFIRM)" != "1" ]; then \
		echo "Creates OPS_DASHBOARD_ROLE (grants incl. ACCOUNTADMIN bind), OPS_DASHBOARD_POOL"; \
		echo "(always-on XS node) and the OPS_DASHBOARD service. 03_service.sql needs its"; \
		echo "<GIT_SHA> placeholder filled in first."; \
		echo "Re-run with CONFIRM=1"; \
		exit 2; \
	fi
	@for f in deploy/sql/*.sql; do echo "== applying $$f =="; $(SNOW) -f $$f || exit 1; done

##@ SPCS image and service

spec-upload: ## Upload the service spec template to @DLT_DB.DEPLOY.SPECS
	$(SNOW_CLI) stage copy deploy/spcs/ops_dashboard.tmpl.yaml @DLT_DB.DEPLOY.SPECS --overwrite

image-build: ## Build the SPCS image (linux/amd64; Docker required)
	docker build --platform linux/amd64 --load -f deploy/spcs/Dockerfile -t $(IMAGE) .

image-login: ## Docker-login to the Snowflake image registry via snow
	$(SNOW_CLI) spcs image-registry login

image-push: image-build image-login ## Build + push ops-dashboard:<git sha>
	@host="$$($(SNOW_CLI) spcs image-registry url)"; \
	  target="$$host$(IMAGE_REPO)/$(IMAGE)"; \
	  echo "== pushing $$target =="; \
	  docker tag $(IMAGE) "$$target" && docker push "$$target"; \
	  echo "== pushed tag $(TAG); deploy with: make deploy TAG=$(TAG) =="

deploy: spec-upload ## Roll the service to TAG (upgrades in place)
	$(SNOW) --role OPS_DASHBOARD_ROLE -q "ALTER SERVICE DLT_DB.DEPLOY.OPS_DASHBOARD FROM @DLT_DB.DEPLOY.SPECS SPECIFICATION_TEMPLATE_FILE = 'ops_dashboard.tmpl.yaml' USING (tag => '$(TAG)');"

endpoint: ## Show the ingress URL (populates once the service is READY)
	$(SNOW) -q "SHOW ENDPOINTS IN SERVICE DLT_DB.DEPLOY.OPS_DASHBOARD;" --format JSON

service-status: ## Service state and container status
	$(SNOW) -q "SELECT SYSTEM\$$GET_SERVICE_STATUS('DLT_DB.DEPLOY.OPS_DASHBOARD');" --format JSON

service-logs: ## Tail the app container log
	$(SNOW) -q "SELECT SYSTEM\$$GET_SERVICE_LOGS('DLT_DB.DEPLOY.OPS_DASHBOARD', 0, 'app', 200);"
