"""Unit tests for the Open-Meteo zipper. No network."""
from __future__ import annotations

import sys
from pathlib import Path

import pytest

_ROOT = Path(__file__).parent.parent.resolve()
if str(_ROOT) not in sys.path:
    sys.path.insert(0, str(_ROOT))

from pipelines.batch.openmeteo_source import (  # noqa: E402
    HOSTS,
    build_params,
    fetch_hourly,
    get_json,
    load_sites,
    zip_hourly,
)

_SITE = {
    "stadium_id": "metlife",
    "lat": 40.813611,
    "lon": -74.074444,
    "timezone": "America/New_York",
    "is_weather_relevant": True,
}

_BODY = {
    "elevation": 4.0,
    "hourly": {
        "time": ["2024-10-13T17:00", "2024-10-13T18:00"],
        "temperature_2m": [70.7, 72.3],
        "wind_speed_10m": [5.9, 8.1],
        "wind_gusts_10m": [14.5, 19.0],
        "wind_direction_10m": [121, 130],
        "precipitation": [0.0, 0.0],
        "weather_code": [1, 2],
    },
}


def test_load_sites_has_unique_stadium_ids() -> None:
    sites = load_sites()
    ids = [s["stadium_id"] for s in sites]
    assert ids
    assert len(ids) == len(set(ids))


def test_weather_relevant_only_drops_domes() -> None:
    all_sites = load_sites()
    outdoor = load_sites(weather_relevant_only=True)
    assert len(outdoor) < len(all_sites)
    assert all(s["is_weather_relevant"] for s in outdoor)
    assert any(s["stadium_id"] == "sofi" for s in all_sites)
    assert not any(s["stadium_id"] == "sofi" for s in outdoor)


def test_zip_hourly_pairs_columnar_arrays() -> None:
    rows = zip_hourly(_BODY, "metlife", "archive")
    assert len(rows) == 2
    first = rows[0]
    assert first["stadium_id"] == "metlife"
    assert first["hour_at"] == "2024-10-13T17:00"
    assert first["product"] == "archive"
    assert first["temperature_f"] == 70.7
    assert first["wind_mph"] == 5.9
    assert first["gust_mph"] == 14.5
    assert first["wind_dir_deg"] == 121
    assert first["precip_in"] == 0.0
    assert first["weather_code"] == 1
    assert first["elevation_m"] == 4.0


def test_zip_hourly_empty_payload_is_empty() -> None:
    assert zip_hourly({"hourly": {}}, "metlife", "forecast") == []


def test_forecast_params_use_utc_and_imperial_units() -> None:
    params = build_params(_SITE, "forecast", forecast_days=7)
    assert params["timezone"] == "UTC"
    assert params["temperature_unit"] == "fahrenheit"
    assert params["wind_speed_unit"] == "mph"
    assert params["forecast_days"] == "7"
    assert "start_date" not in params


def test_archive_params_require_a_window() -> None:
    with pytest.raises(ValueError, match="start_date"):
        build_params(_SITE, "archive")
    params = build_params(_SITE, "archive", start_date="2023-08-01", end_date="2026-02-15")
    assert params["start_date"] == "2023-08-01"
    assert params["end_date"] == "2026-02-15"


def test_fetch_hourly_uses_the_product_host_and_zips() -> None:
    seen: list[str] = []

    def get(url: str) -> dict:
        seen.append(url)
        return _BODY

    rows = fetch_hourly(
        _SITE,
        "archive",
        start_date="2024-10-13",
        end_date="2024-10-13",
        get=get,
    )
    assert len(rows) == 2
    assert seen[0].startswith(HOSTS["archive"])
    assert "latitude=40.813611" in seen[0]


class _FakeResponse:
    def __init__(self, status_code: int, body: dict | None = None, retry_after: str | None = None):
        self.status_code = status_code
        self._body = body or {}
        self.headers = {"Retry-After": retry_after} if retry_after else {}

    def json(self) -> dict:
        return self._body

    def raise_for_status(self) -> None:
        if self.status_code >= 400:
            raise RuntimeError(f"{self.status_code} Client Error")


def test_get_json_retries_429_then_succeeds() -> None:
    calls = {"n": 0}
    slept: list[float] = []

    def http_get(_url: str) -> _FakeResponse:
        calls["n"] += 1
        if calls["n"] == 1:
            return _FakeResponse(429, retry_after="1")
        return _FakeResponse(200, _BODY)

    body = get_json(
        "https://archive-api.open-meteo.com/v1/archive",
        http_get=http_get,
        sleep=slept.append,
    )
    assert calls["n"] == 2
    assert slept == [1.0]
    assert body["elevation"] == 4.0


def test_get_json_retries_read_timeout_then_succeeds() -> None:
    calls = {"n": 0}
    slept: list[float] = []

    def http_get(_url: str) -> _FakeResponse:
        calls["n"] += 1
        if calls["n"] == 1:
            raise TimeoutError("Read timed out. (read timeout=180)")
        return _FakeResponse(200, _BODY)

    body = get_json(
        "https://historical-forecast-api.open-meteo.com/v1/forecast",
        http_get=http_get,
        sleep=slept.append,
    )
    assert calls["n"] == 2
    assert slept == [1.0]
    assert body["elevation"] == 4.0


def test_unknown_product_is_rejected() -> None:
    with pytest.raises(ValueError, match="unknown product"):
        fetch_hourly(_SITE, "radar", get=lambda _u: _BODY)


def test_source_factory_yields_zipped_hours() -> None:
    from pipelines.batch.openmeteo_source import openmeteo_weather

    def get(_url: str) -> dict:
        return _BODY

    resource = openmeteo_weather(
        "nfl_weather_forecast",
        {"product": "forecast", "forecast_days": 7},
        get=get,
        sites=[_SITE],
    )
    rows = list(resource)
    assert len(rows) == 2
    assert rows[0]["stadium_id"] == "metlife"
    assert rows[0]["product"] == "forecast"
    assert rows[0]["temperature_f"] == 70.7
