# Makefile for analytics-dashboard
#
# Quickstart:
#   make install   # api deps (uv) + web deps (npm)
#   make dev-api   # FastAPI with reload on :8010
#   make dev-web   # Vite dev server on :5174 proxying /api to :8010
#
# Own ports, so this app and ops-dashboard (:8000 / :5173) run side by side.

UV      ?= uv
UV_RUN  := $(UV) run --extra dev

SNOW_CONN ?=
SNOW_CLI := snow $(if $(SNOW_CONN),--connection $(SNOW_CONN),)
SNOW := $(SNOW_CLI) sql

define hdr
printf '\n\033[1;36m== %s ==\033[0m\n' "$(1)"
endef

.DEFAULT_GOAL := help

.PHONY: help install dev-api dev-web serve test test-live lint build setup

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

dev-api: ## Run FastAPI with reload on :8010 (live data as ANALYTICS_DASHBOARD_ROLE)
	cd api && $(UV_RUN) uvicorn app.main:app --reload --port 8010

dev-api-fixtures: ## Run FastAPI on :8010 against recorded fixtures (no Snowflake)
	cd api && ANALYTICS_DASHBOARD_DATA=fixtures $(UV_RUN) uvicorn app.main:app --reload --port 8010

dev-web: ## Run the Vite dev server on :5174 (proxies /api to :8010)
	cd web && npm run dev

serve: build ## Build the web app and serve api + web together on :8010
	@$(call hdr,dashboard on http://localhost:8010)
	cd api && $(UV_RUN) uvicorn app.main:app --port 8010

##@ Quality

test: ## Run the api test suite (fixture mode; live tests skipped)
	cd api && $(UV_RUN) pytest -q

test-live: ## Run the suite including live contract tests against Snowflake
	cd api && ANALYTICS_DASHBOARD_LIVE=1 $(UV_RUN) pytest -q

lint: ## Ruff on the api + type-check the web
	@$(call hdr,api ruff)
	cd api && $(UV_RUN) ruff check .
	@$(call hdr,web tsc)
	cd web && npx tsc -b

build: ## Production build of the web app into web/dist
	cd web && npm run build

##@ Snowflake setup (live; run by a human, never CI)

setup: ## Apply deploy/sql/*.sql in order (CONFIRM=1 required)
	@if [ "$(CONFIRM)" != "1" ]; then \
		echo "Creates ANALYTICS_DASHBOARD_ROLE and grants it SELECT on the semantic views and"; \
		echo "on each sport's APP schema. 03_app_grants.sql fails until the first prod dbt"; \
		echo "build has created APP; re-run after that, the files are idempotent."; \
		echo "Re-run with CONFIRM=1"; \
		exit 2; \
	fi
	@for f in deploy/sql/*.sql; do echo "== applying $$f =="; $(SNOW) -f $$f || exit 1; done
