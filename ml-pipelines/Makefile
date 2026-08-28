.PHONY: sync list inspect test

sync: ## Install the uv lock
	uv sync --extra dev

list: ## Dedicated model specs
	uv run python -m weekend_warriors_ml list

inspect: ## Row counts. MODEL=NFL_GAME_TOTAL
	uv run python -m weekend_warriors_ml inspect $(MODEL)

test:
	uv run pytest tests
