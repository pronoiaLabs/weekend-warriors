"""Open-Meteo weather source: zip columnar hourly arrays into stadium-hour rows.

WHY THIS IS A CUSTOM SOURCE
    Open-Meteo returns `hourly.time[]` alongside parallel arrays
    (`wind_speed_10m[]`, ...), not a list of hour-objects. The rest_api YAML
    source has no zip-arrays transform. Same class of exception as a chained
    vendor SDK: the payload cannot be expressed declaratively.

    The source type is named for the vendor (`openmeteo`). Pipelines and tables
    are named for the content (`nfl_weather_*`, `weather_hourly`) and land in
    NFL_PROD_DB.RAW. There is no API key.

CONTENTS
    1. Site list ........ load_sites (CSV shipped in the image)
    2. HTTP + zip ....... fetch_hourly, zip_hourly
    3. The source ....... openmeteo_weather

UNITS
    Fahrenheit, mph, inches. timezone=UTC so hour_at joins dim_game.game_datetime
    without a stadium-local conversion.
"""

from __future__ import annotations

import csv
import logging
import time
from collections.abc import Callable, Iterator
from pathlib import Path
from typing import Any
from urllib.parse import urlencode

import dlt

log = logging.getLogger("dlt_pipeline.openmeteo")

# Archive / historical-forecast payloads are large; Open-Meteo's free tier 429s
# a burst of them. Pause between sites and honour Retry-After.
SITE_PAUSE_S = 0.5
HTTP_RETRIES = 6
HTTP_TIMEOUT_S = 180

SITES_PATH = Path(__file__).with_name("data") / "nfl_stadium_sites.csv"

HOURLY_VARS = (
    "temperature_2m",
    "precipitation",
    "weather_code",
    "wind_speed_10m",
    "wind_gusts_10m",
    "wind_direction_10m",
)

HOSTS = {
    "forecast": "https://api.open-meteo.com/v1/forecast",
    "archive": "https://archive-api.open-meteo.com/v1/archive",
    "hist_forecast": "https://historical-forecast-api.open-meteo.com/v1/forecast",
}

PRODUCTS = frozenset(HOSTS)


def load_sites(
    path: Path = SITES_PATH,
    *,
    weather_relevant_only: bool = False,
) -> list[dict[str, Any]]:
    """Read the extractor site list. One row per physical stadium_id."""
    with path.open(newline="") as fh:
        rows = list(csv.DictReader(fh))
    sites: list[dict[str, Any]] = []
    for row in rows:
        relevant = row["is_weather_relevant"].strip().lower() == "true"
        if weather_relevant_only and not relevant:
            continue
        sites.append(
            {
                "stadium_id": row["stadium_id"],
                "lat": float(row["lat"]),
                "lon": float(row["lon"]),
                "timezone": row["timezone"],
                "is_weather_relevant": relevant,
            }
        )
    return sites


def zip_hourly(body: dict[str, Any], stadium_id: str, product: str) -> list[dict[str, Any]]:
    """Turn Open-Meteo's columnar hourly payload into one dict per hour."""
    hourly = body.get("hourly") or {}
    times = hourly.get("time") or []
    rows: list[dict[str, Any]] = []
    for i, ts in enumerate(times):
        rows.append(
            {
                "stadium_id": stadium_id,
                "hour_at": ts,
                "product": product,
                "temperature_f": _at(hourly, "temperature_2m", i),
                "wind_mph": _at(hourly, "wind_speed_10m", i),
                "gust_mph": _at(hourly, "wind_gusts_10m", i),
                "wind_dir_deg": _at(hourly, "wind_direction_10m", i),
                "precip_in": _at(hourly, "precipitation", i),
                "weather_code": _at(hourly, "weather_code", i),
                "elevation_m": body.get("elevation"),
            }
        )
    return rows


def _at(hourly: dict[str, Any], key: str, index: int) -> Any:
    values = hourly.get(key) or []
    if index >= len(values):
        return None
    return values[index]


def build_params(
    site: dict[str, Any],
    product: str,
    *,
    start_date: str | None = None,
    end_date: str | None = None,
    forecast_days: int | None = None,
) -> dict[str, str]:
    params: dict[str, str] = {
        "latitude": str(site["lat"]),
        "longitude": str(site["lon"]),
        "hourly": ",".join(HOURLY_VARS),
        "temperature_unit": "fahrenheit",
        "wind_speed_unit": "mph",
        "precipitation_unit": "inch",
        "timezone": "UTC",
    }
    if product == "forecast":
        params["forecast_days"] = str(forecast_days or 16)
    else:
        if not start_date or not end_date:
            raise ValueError(
                f"product {product!r} requires start_date and end_date"
            )
        params["start_date"] = start_date
        params["end_date"] = end_date
    return params


def _retry_after_seconds(response: Any, attempt: int) -> float:
    raw = getattr(response, "headers", {}).get("Retry-After")
    if raw is not None:
        try:
            return max(float(raw), 1.0)
        except (TypeError, ValueError):
            pass
    return float(min(2**attempt, 60))


def get_json(
    url: str,
    *,
    get: Callable[[str], dict[str, Any]] | None = None,
    http_get: Callable[[str], Any] | None = None,
    sleep: Callable[[float], None] = time.sleep,
    retries: int = HTTP_RETRIES,
) -> dict[str, Any]:
    """GET JSON, retrying 429s and read timeouts. `get` is the test seam."""
    if get is not None:
        return get(url)

    if http_get is None:
        import requests  # noqa: PLC0415

        def http_get(u: str) -> Any:
            return requests.get(u, timeout=HTTP_TIMEOUT_S)

    last: Any = None
    for attempt in range(retries):
        try:
            response = http_get(url)
        except Exception as exc:
            if not _is_retryable_http_error(exc) or attempt + 1 >= retries:
                raise
            wait = float(min(2**attempt, 60))
            log.warning(
                "openmeteo request error; sleeping %.1fs (attempt %s/%s): %s",
                wait,
                attempt + 1,
                retries,
                exc,
            )
            sleep(wait)
            continue
        last = response
        status = getattr(response, "status_code", None)
        if status == 429:
            wait = _retry_after_seconds(response, attempt)
            log.warning("openmeteo 429; sleeping %.1fs (attempt %s/%s)", wait, attempt + 1, retries)
            sleep(wait)
            continue
        response.raise_for_status()
        return response.json()
    if last is not None:
        last.raise_for_status()
    raise RuntimeError(f"openmeteo GET failed with no response: {url}")


def _is_retryable_http_error(exc: BaseException) -> bool:
    name = type(exc).__name__.lower()
    return "timeout" in name or "timeout" in str(exc).lower() or "connection" in name


def fetch_hourly(
    site: dict[str, Any],
    product: str,
    *,
    start_date: str | None = None,
    end_date: str | None = None,
    forecast_days: int | None = None,
    get: Callable[[str], dict[str, Any]] | None = None,
    http_get: Callable[[str], Any] | None = None,
    sleep: Callable[[float], None] = time.sleep,
) -> list[dict[str, Any]]:
    if product not in PRODUCTS:
        raise ValueError(f"unknown product {product!r}; expected one of {sorted(PRODUCTS)}")
    url = HOSTS[product] + "?" + urlencode(build_params(
        site,
        product,
        start_date=start_date,
        end_date=end_date,
        forecast_days=forecast_days,
    ))
    body = get_json(url, get=get, http_get=http_get, sleep=sleep)
    return zip_hourly(body, site["stadium_id"], product)


@dlt.source(name="openmeteo")
def openmeteo_weather(
    name: str,
    config: dict[str, Any],
    *,
    get: Callable[[str], dict[str, Any]] | None = None,
    sites: list[dict[str, Any]] | None = None,
) -> Any:
    """One resource: weather_hourly, merged on stadium_id + hour_at + product."""
    product = config.get("product")
    if product not in PRODUCTS:
        raise ValueError(
            f"pipeline '{name}': config.product must be one of {sorted(PRODUCTS)}, "
            f"got {product!r}"
        )

    weather_relevant_only = bool(config.get("weather_relevant_only", False))
    loaded = sites if sites is not None else load_sites(
        weather_relevant_only=weather_relevant_only
    )
    if not loaded:
        raise ValueError(f"pipeline '{name}': no stadium sites to request")

    start_date = config.get("start_date")
    end_date = config.get("end_date")
    forecast_days = config.get("forecast_days")

    @dlt.resource(
        name="weather_hourly",
        primary_key=["stadium_id", "hour_at", "product"],
        write_disposition="merge",
    )
    def weather_hourly() -> Iterator[dict[str, Any]]:
        for i, site in enumerate(loaded):
            if i:
                time.sleep(SITE_PAUSE_S)
            rows = fetch_hourly(
                site,
                product,
                start_date=start_date,
                end_date=end_date,
                forecast_days=forecast_days,
                get=get,
            )
            log.info(
                "openmeteo %s %s: %s hours",
                product,
                site["stadium_id"],
                len(rows),
            )
            yield from rows

    return weather_hourly
