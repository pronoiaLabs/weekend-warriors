.PHONY: sync inspect fit cook cook-local test

sync: ## Install the uv lock
	uv sync --extra dev

inspect: ## Row counts on FEAT_GAME_MATCHUP
	uv run python -m weekend_warriors_ml inspect

fit: ## Walk-forward only (no registry write)
	uv run python -m weekend_warriors_ml fit

cook: ## Fit, register, local preds, run_batch on ML_DEV_POOL
	uv run python -m weekend_warriors_ml cook

cook-local: ## Fit, register, local preds; skip the pool
	uv run python -m weekend_warriors_ml cook --no-batch

test:
	uv run pytest tests
