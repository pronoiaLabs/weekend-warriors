"""Back-compat aliases for the game-total contract. New models live in specs.py."""

from weekend_warriors_ml.specs import (
    COMPUTE_POOL,
    ELIGIBLE_SEASON_TYPES,
    GAME_FEATURES,
    MATCHUP_TABLE,
    REGISTRY_DB,
    REGISTRY_SCHEMA,
    TEST_SEASON,
    TRAIN_SEASONS,
    assert_feature_contract,
)

FEATURE_COLUMNS = GAME_FEATURES

LABEL_COLUMN = "label_total"
COMPARATOR_COLUMN = "close_total"
ID_COLUMNS = ("game_key", "season", "week", "season_type", "is_completed")
MODEL_NAME = "NFL_GAME_TOTAL"
PRED_TABLE = "PRED_GAME_TOTAL"
INFERENCE_STAGE = "@NFL_PROD_DB.ML.INFERENCE_STAGE/game_total/"

__all__ = [
    "COMPARATOR_COLUMN",
    "COMPUTE_POOL",
    "ELIGIBLE_SEASON_TYPES",
    "FEATURE_COLUMNS",
    "ID_COLUMNS",
    "INFERENCE_STAGE",
    "LABEL_COLUMN",
    "MATCHUP_TABLE",
    "MODEL_NAME",
    "PRED_TABLE",
    "REGISTRY_DB",
    "REGISTRY_SCHEMA",
    "TEST_SEASON",
    "TRAIN_SEASONS",
    "assert_feature_contract",
]
