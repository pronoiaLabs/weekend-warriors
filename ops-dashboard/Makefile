# Makefile for ops-dashboard
#
# Quickstart:
#   make install   # api deps (uv) + web deps (npm)
#   make dev-api   # FastAPI with reload on :8000
#   make dev-web   # Vite dev server proxying /api to :8000

UV      ?= uv
UV_RUN  := $(UV) run --extra dev

# Terminal banner helper: `@$(call hdr,message)` prints a bold cyan section header.
# (Keep messages comma-free -- commas split $(call) arguments.)
define hdr
printf '\n\033[1;36m== %s ==\033[0m\n' "$(1)"
endef

.DEFAULT_GOAL := help

.PHONY: help install dev-api dev-web \
        test lint build

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

dev-api: ## Run FastAPI with reload on :8000
	cd api && $(UV_RUN) uvicorn app.main:app --reload --port 8000

dev-web: ## Run the Vite dev server (proxies /api to :8000)
	cd web && npm run dev

##@ Quality

test: ## Run the api test suite
	cd api && $(UV_RUN) pytest -q

lint: ## Ruff on the api + type-check the web (tsc -b: the root tsconfig only holds references)
	@$(call hdr,api ruff)
	cd api && $(UV_RUN) ruff check .
	@$(call hdr,web tsc)
	cd web && npx tsc -b

build: ## Production build of the web app into web/dist
	cd web && npm run build
