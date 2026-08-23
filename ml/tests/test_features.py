from pathlib import Path

from weekend_warriors_ml.features import FEATURE_COLUMNS, assert_feature_contract
from weekend_warriors_ml.pipeline import PLAYER_LABEL_EXPR
from weekend_warriors_ml.specs import GAME_FEATURES, SPECS, get_spec

NOTEBOOKS = Path(__file__).resolve().parents[1] / "notebooks" / "v1"


def test_feature_list_has_no_close_or_label() -> None:
    assert_feature_contract()
    assert all(not c.startswith("close_") for c in FEATURE_COLUMNS)
    assert all(not c.startswith("label_") for c in FEATURE_COLUMNS)
    assert "close_total" not in FEATURE_COLUMNS
    assert "label_total" not in FEATURE_COLUMNS
    assert FEATURE_COLUMNS == GAME_FEATURES
    assert len(FEATURE_COLUMNS) == 56


def test_assert_rejects_leaks() -> None:
    try:
        assert_feature_contract(("weather_temp_f", "close_total"))
    except ValueError as exc:
        assert "close_total" in str(exc)
    else:
        raise AssertionError("expected ValueError")


def test_every_spec_keeps_x_clean() -> None:
    assert len(SPECS) == 14
    for spec in SPECS.values():
        assert_feature_contract(spec.feature_columns)
        assert spec.label_column.startswith("label_")
        assert spec.pred_column.startswith("pred_")
        assert spec.notebook.endswith(".ipynb")
        if spec.comparator_column:
            assert spec.comparator_column.startswith("close_")


def test_get_spec_and_unknown() -> None:
    assert get_spec("NFL_GAME_TOTAL").label_column == "label_total"
    try:
        get_spec("NOT_A_MODEL")
    except KeyError as exc:
        assert "NOT_A_MODEL" in str(exc)
    else:
        raise AssertionError("expected KeyError")


def test_player_labels_and_gates() -> None:
    players = [s for s in SPECS.values() if s.family == "player"]
    assert players
    for spec in players:
        assert spec.min_feature is not None
        assert spec.min_feature in spec.feature_columns
        assert spec.label_column in PLAYER_LABEL_EXPR
    anytime = get_spec("NFL_PLAYER_ANYTIME_TD")
    assert anytime.task == "classification"
    assert all(s.task == "regression" for s in SPECS.values() if s.name != anytime.name)


def test_notebooks_exist_for_every_spec() -> None:
    assert (NOTEBOOKS / "00_nfl_models.ipynb").is_file()
    for spec in SPECS.values():
        assert (NOTEBOOKS / spec.notebook).is_file(), spec.notebook
