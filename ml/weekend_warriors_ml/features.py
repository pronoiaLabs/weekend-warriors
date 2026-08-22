"""Explicit X for NFL_GAME_TOTAL. close_* and label_* are forbidden."""

from __future__ import annotations

MATCHUP_TABLE = "NFL_PROD_DB.FEATURES.FEAT_GAME_MATCHUP"
REGISTRY_DB = "NFL_PROD_DB"
REGISTRY_SCHEMA = "ML"
MODEL_NAME = "NFL_GAME_TOTAL"
COMPUTE_POOL = "ML_DEV_POOL"
INFERENCE_STAGE = "@NFL_PROD_DB.ML.INFERENCE_STAGE/game_total/"
PRED_TABLE = "NFL_PROD_DB.ML.PRED_GAME_TOTAL"

TRAIN_SEASONS = (2023, 2024)
TEST_SEASON = 2025
# dim_game season_type: 2 = regular, 3 = post. Preseason must not train.
ELIGIBLE_SEASON_TYPES = (2, 3)

ID_COLUMNS = ("game_key", "season", "week", "season_type", "is_completed")
LABEL_COLUMN = "label_total"
COMPARATOR_COLUMN = "close_total"

_WINDOWS = ("l5", "std")
_RATE_STATS = (
    "n_games_played",
    "points_per_game",
    "margin_per_game",
    "yards_per_play",
    "pass_rate",
    "turnover_rate",
    "opp_points_per_game",
    "takeaways_per_drive",
    "sacks_recorded_per_game",
    "third_down_rate",
    "red_zone_td_rate",
)

CONTEXT_COLUMNS = (
    "week",
    "is_postseason",
    "home_rest_days",
    "away_rest_days",
    "home_is_short_week",
    "away_is_short_week",
    "elevation_m",
    "is_weather_relevant",
    "is_international",
    "weather_temp_f",
    "weather_wind_mph",
    "weather_precip_in",
)

FEATURE_COLUMNS: tuple[str, ...] = CONTEXT_COLUMNS + tuple(
    f"{side}_{stat}_{window}"
    for side in ("home", "away")
    for stat in _RATE_STATS
    for window in _WINDOWS
)


def assert_feature_contract(columns: tuple[str, ...] = FEATURE_COLUMNS) -> None:
    leaked = [
        c
        for c in columns
        if c.startswith("close_") or c.startswith("label_")
    ]
    if leaked:
        raise ValueError(f"X must not include close_* or label_*: {leaked}")
