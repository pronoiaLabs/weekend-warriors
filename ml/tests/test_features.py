from weekend_warriors_ml.features import FEATURE_COLUMNS, assert_feature_contract


def test_feature_list_has_no_close_or_label() -> None:
    assert_feature_contract()
    assert all(not c.startswith("close_") for c in FEATURE_COLUMNS)
    assert all(not c.startswith("label_") for c in FEATURE_COLUMNS)
    assert "close_total" not in FEATURE_COLUMNS
    assert "label_total" not in FEATURE_COLUMNS


def test_assert_rejects_leaks() -> None:
    try:
        assert_feature_contract(("weather_temp_f", "close_total"))
    except ValueError as exc:
        assert "close_total" in str(exc)
    else:
        raise AssertionError("expected ValueError")
