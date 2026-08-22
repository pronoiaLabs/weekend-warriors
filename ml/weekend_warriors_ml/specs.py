"""Dedicated-model specs. X is FEATURES only; close_* and label_* are forbidden in X."""

from __future__ import annotations

from dataclasses import dataclass

REGISTRY_DB = "NFL_PROD_DB"
REGISTRY_SCHEMA = "ML"
COMPUTE_POOL = "ML_DEV_POOL"
MATCHUP_TABLE = "NFL_PROD_DB.FEATURES.FEAT_GAME_MATCHUP"
PLAYER_ROLLING_TABLE = "NFL_PROD_DB.FEATURES.FEAT_PLAYER_GAME_ROLLING"
PLAYER_WEATHER_TABLE = "NFL_PROD_DB.FEATURES.FEAT_PLAYER_WEATHER"
PLAYER_OFFENSE_FACT = "NFL_PROD_DB.CORE.FACT_PLAYER_GAME_OFFENSE"

TRAIN_SEASONS = (2023, 2024)
TEST_SEASON = 2025
ELIGIBLE_SEASON_TYPES = (2, 3)

GAME_ID_COLUMNS = ("game_key", "season", "week", "season_type", "is_completed")
PLAYER_ID_COLUMNS = (
    "player_game_key",
    "player_key",
    "game_key",
    "season",
    "week",
    "season_type",
    "is_completed",
)

_WINDOWS = ("l5", "std")
_GAME_RATE_STATS = (
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
GAME_CONTEXT = (
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
GAME_FEATURES: tuple[str, ...] = GAME_CONTEXT + tuple(
    f"{side}_{stat}_{window}"
    for side in ("home", "away")
    for stat in _GAME_RATE_STATS
    for window in _WINDOWS
)

_PLAYER_RATES = (
    "n_games_played",
    "n_passing",
    "n_rushing",
    "n_receiving",
    "pass_yds_per_game",
    "pass_att_per_game",
    "pass_td_per_game",
    "ypa",
    "completion_rate",
    "int_rate",
    "sack_rate",
    "team_pass_share",
    "rush_yds_per_game",
    "rush_att_per_game",
    "rush_td_per_game",
    "ypc",
    "team_rush_share",
    "rec_yds_per_game",
    "targets_per_game",
    "rec_per_game",
    "rec_td_per_game",
    "team_target_share",
    "scrimmage_yds_per_game",
    "touches_per_game",
)
PLAYER_CONTEXT = (
    "week",
    "is_home",
    "is_weather_relevant",
    "weather_temp_f",
    "weather_wind_mph",
    "weather_precip_in",
    "elevation_m",
)


def _player_features(*weather_products: str) -> tuple[str, ...]:
    rates = tuple(
        f"{stat}_{window}" for stat in _PLAYER_RATES for window in _WINDOWS
    )
    return PLAYER_CONTEXT + rates + weather_products


@dataclass(frozen=True)
class ModelSpec:
    name: str
    family: str
    label_column: str
    pred_column: str
    pred_table: str
    inference_subdir: str
    feature_columns: tuple[str, ...]
    id_columns: tuple[str, ...]
    comparator_column: str | None
    task: str
    min_feature: str | None
    notebook: str
    comment: str

    @property
    def inference_stage(self) -> str:
        return f"@NFL_PROD_DB.ML.INFERENCE_STAGE/{self.inference_subdir}/"


def assert_feature_contract(columns: tuple[str, ...] | None = None) -> None:
    cols = GAME_FEATURES if columns is None else columns
    leaked = [c for c in cols if c.startswith(("close_", "label_"))]
    if leaked:
        raise ValueError(f"X must not include close_* or label_*: {leaked}")


SPECS: dict[str, ModelSpec] = {}


def _add(spec: ModelSpec) -> None:
    assert_feature_contract(spec.feature_columns)
    if spec.task not in ("regression", "classification"):
        raise ValueError(f"unknown task {spec.task}")
    if spec.family not in ("game", "player"):
        raise ValueError(f"unknown family {spec.family}")
    SPECS[spec.name] = spec


def get_spec(name: str) -> ModelSpec:
    try:
        return SPECS[name]
    except KeyError as exc:
        known = ", ".join(SPECS)
        raise KeyError(f"unknown model {name}. Known: {known}") from exc


_add(
    ModelSpec(
        name="NFL_GAME_TOTAL",
        family="game",
        label_column="label_total",
        pred_column="pred_total",
        pred_table="PRED_GAME_TOTAL",
        inference_subdir="game_total",
        feature_columns=GAME_FEATURES,
        id_columns=GAME_ID_COLUMNS,
        comparator_column="close_total",
        task="regression",
        min_feature=None,
        notebook="nfl_game_total_v1.ipynb",
        comment="Game total. X from FEAT_GAME_MATCHUP l5+std rates. No close_*, no label_*.",
    )
)
_add(
    ModelSpec(
        name="NFL_GAME_HOME_POINTS",
        family="game",
        label_column="label_home_points",
        pred_column="pred_home_points",
        pred_table="PRED_GAME_HOME_POINTS",
        inference_subdir="game_home_points",
        feature_columns=GAME_FEATURES,
        id_columns=GAME_ID_COLUMNS,
        comparator_column="close_implied_home_total",
        task="regression",
        min_feature=None,
        notebook="nfl_game_home_points_v1.ipynb",
        comment="Home score. Same matchup X as game total.",
    )
)
_add(
    ModelSpec(
        name="NFL_GAME_AWAY_POINTS",
        family="game",
        label_column="label_away_points",
        pred_column="pred_away_points",
        pred_table="PRED_GAME_AWAY_POINTS",
        inference_subdir="game_away_points",
        feature_columns=GAME_FEATURES,
        id_columns=GAME_ID_COLUMNS,
        comparator_column="close_implied_away_total",
        task="regression",
        min_feature=None,
        notebook="nfl_game_away_points_v1.ipynb",
        comment="Away score. Same matchup X as game total.",
    )
)
_add(
    ModelSpec(
        name="NFL_GAME_MARGIN",
        family="game",
        label_column="label_home_margin",
        pred_column="pred_home_margin",
        pred_table="PRED_GAME_MARGIN",
        inference_subdir="game_margin",
        feature_columns=GAME_FEATURES,
        id_columns=GAME_ID_COLUMNS,
        comparator_column="close_spread",
        task="regression",
        min_feature=None,
        notebook="nfl_game_margin_v1.ipynb",
        comment="Home margin (home - away). Comparator is close_spread.",
    )
)
_add(
    ModelSpec(
        name="NFL_GAME_HOME_NET_PASS",
        family="game",
        label_column="label_home_net_pass",
        pred_column="pred_home_net_pass",
        pred_table="PRED_GAME_HOME_NET_PASS",
        inference_subdir="game_home_net_pass",
        feature_columns=GAME_FEATURES,
        id_columns=GAME_ID_COLUMNS,
        comparator_column=None,
        task="regression",
        min_feature=None,
        notebook="nfl_game_home_net_pass_v1.ipynb",
        comment="Home net passing yards. No historical close.",
    )
)
_add(
    ModelSpec(
        name="NFL_GAME_AWAY_NET_PASS",
        family="game",
        label_column="label_away_net_pass",
        pred_column="pred_away_net_pass",
        pred_table="PRED_GAME_AWAY_NET_PASS",
        inference_subdir="game_away_net_pass",
        feature_columns=GAME_FEATURES,
        id_columns=GAME_ID_COLUMNS,
        comparator_column=None,
        task="regression",
        min_feature=None,
        notebook="nfl_game_away_net_pass_v1.ipynb",
        comment="Away net passing yards. No historical close.",
    )
)
_add(
    ModelSpec(
        name="NFL_GAME_HOME_RUSH",
        family="game",
        label_column="label_home_rush",
        pred_column="pred_home_rush",
        pred_table="PRED_GAME_HOME_RUSH",
        inference_subdir="game_home_rush",
        feature_columns=GAME_FEATURES,
        id_columns=GAME_ID_COLUMNS,
        comparator_column=None,
        task="regression",
        min_feature=None,
        notebook="nfl_game_home_rush_v1.ipynb",
        comment="Home rushing yards. No historical close.",
    )
)
_add(
    ModelSpec(
        name="NFL_GAME_AWAY_RUSH",
        family="game",
        label_column="label_away_rush",
        pred_column="pred_away_rush",
        pred_table="PRED_GAME_AWAY_RUSH",
        inference_subdir="game_away_rush",
        feature_columns=GAME_FEATURES,
        id_columns=GAME_ID_COLUMNS,
        comparator_column=None,
        task="regression",
        min_feature=None,
        notebook="nfl_game_away_rush_v1.ipynb",
        comment="Away rushing yards. No historical close.",
    )
)
_add(
    ModelSpec(
        name="NFL_PLAYER_PASSING_YARDS",
        family="player",
        label_column="label_passing_yards",
        pred_column="pred_passing_yards",
        pred_table="PRED_PLAYER_PASSING_YARDS",
        inference_subdir="player_passing_yards",
        feature_columns=_player_features("pass_volume_in_wind", "pass_volume_in_cold"),
        id_columns=PLAYER_ID_COLUMNS,
        comparator_column=None,
        task="regression",
        min_feature="n_passing_l5",
        notebook="nfl_player_passing_yards_v1.ipynb",
        comment="QB passing yards. X from player rolling + weather products. Label from CORE box.",
    )
)
_add(
    ModelSpec(
        name="NFL_PLAYER_RUSHING_YARDS",
        family="player",
        label_column="label_rushing_yards",
        pred_column="pred_rushing_yards",
        pred_table="PRED_PLAYER_RUSHING_YARDS",
        inference_subdir="player_rushing_yards",
        feature_columns=_player_features("rush_share_in_wind"),
        id_columns=PLAYER_ID_COLUMNS,
        comparator_column=None,
        task="regression",
        min_feature="n_rushing_l5",
        notebook="nfl_player_rushing_yards_v1.ipynb",
        comment="Rushing yards. Gate: trailing rush games on l5.",
    )
)
_add(
    ModelSpec(
        name="NFL_PLAYER_RECEIVING_YARDS",
        family="player",
        label_column="label_receiving_yards",
        pred_column="pred_receiving_yards",
        pred_table="PRED_PLAYER_RECEIVING_YARDS",
        inference_subdir="player_receiving_yards",
        feature_columns=_player_features("targets_in_wind"),
        id_columns=PLAYER_ID_COLUMNS,
        comparator_column=None,
        task="regression",
        min_feature="n_receiving_l5",
        notebook="nfl_player_receiving_yards_v1.ipynb",
        comment="Receiving yards. Gate: trailing receiving games on l5.",
    )
)
_add(
    ModelSpec(
        name="NFL_PLAYER_RECEPTIONS",
        family="player",
        label_column="label_receptions",
        pred_column="pred_receptions",
        pred_table="PRED_PLAYER_RECEPTIONS",
        inference_subdir="player_receptions",
        feature_columns=_player_features("targets_in_wind"),
        id_columns=PLAYER_ID_COLUMNS,
        comparator_column=None,
        task="regression",
        min_feature="n_receiving_l5",
        notebook="nfl_player_receptions_v1.ipynb",
        comment="Receptions. Same stack as receiving yards.",
    )
)
_add(
    ModelSpec(
        name="NFL_PLAYER_PASSING_TDS",
        family="player",
        label_column="label_passing_tds",
        pred_column="pred_passing_tds",
        pred_table="PRED_PLAYER_PASSING_TDS",
        inference_subdir="player_passing_tds",
        feature_columns=_player_features("pass_volume_in_wind"),
        id_columns=PLAYER_ID_COLUMNS,
        comparator_column=None,
        task="regression",
        min_feature="n_passing_l5",
        notebook="nfl_player_passing_tds_v1.ipynb",
        comment="Passing TD count. Not a Bernoulli anytime-TD model.",
    )
)
_add(
    ModelSpec(
        name="NFL_PLAYER_ANYTIME_TD",
        family="player",
        label_column="label_anytime_td",
        pred_column="pred_anytime_td",
        pred_table="PRED_PLAYER_ANYTIME_TD",
        inference_subdir="player_anytime_td",
        feature_columns=_player_features("ball_security_in_precip"),
        id_columns=PLAYER_ID_COLUMNS,
        comparator_column=None,
        task="classification",
        min_feature="n_games_played_l5",
        notebook="nfl_player_anytime_td_v1.ipynb",
        comment="I(rush TD + rec TD >= 1). QB pass-or-rush variant is a later spec.",
    )
)

DEFERRED = (
    "NFL_PLAYER_FIRST_TD — needs play-level scoring order",
    "CLV / residual vs close — blocked on 2023-25 closes",
    "feat_player_prop_train — later FEATURES grain, not this PR",
)
