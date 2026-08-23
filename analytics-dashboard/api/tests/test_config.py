"""Backend, location, and FQN defaults. Fixture mode never opens a connection."""

from app import config
from app.sports.capabilities import Capability as C
from app.sports.profiles.nfl import NFL
from app.sports.tiles.explore import kind_of


def test_backend_is_fixtures_when_data_is_fixtures(monkeypatch) -> None:
    monkeypatch.setenv("ANALYTICS_DASHBOARD_DATA", "fixtures")
    monkeypatch.delenv("ANALYTICS_DASHBOARD_BACKEND", raising=False)
    assert config.backend() == "fixtures"
    assert config.is_postgres() is False
    assert config.is_snowflake() is False


def test_live_backend_defaults_to_postgres(monkeypatch) -> None:
    monkeypatch.setenv("ANALYTICS_DASHBOARD_DATA", "live")
    monkeypatch.delenv("ANALYTICS_DASHBOARD_BACKEND", raising=False)
    assert config.backend() == "postgres"
    assert config.is_postgres() is True


def test_live_backend_snowflake(monkeypatch) -> None:
    monkeypatch.setenv("ANALYTICS_DASHBOARD_DATA", "live")
    monkeypatch.setenv("ANALYTICS_DASHBOARD_BACKEND", "snowflake")
    assert config.is_snowflake() is True
    assert config.app_location("nfl") == ("NFL_PROD_DB", "APP")
    assert NFL.fqn(C.SCHEDULE) == "NFL_PROD_DB.APP.app_game_slate"


def test_postgres_location_and_fqn(monkeypatch) -> None:
    monkeypatch.setenv("ANALYTICS_DASHBOARD_DATA", "live")
    monkeypatch.setenv("ANALYTICS_DASHBOARD_BACKEND", "postgres")
    monkeypatch.delenv("NFL_APP_DB", raising=False)
    monkeypatch.delenv("NFL_APP_SCHEMA", raising=False)
    assert config.app_location("nfl") == ("app", "app_copy")
    assert NFL.fqn(C.SCHEDULE) == "app_copy.app_game_slate"
    assert config.role() == "app_api"


def test_kind_of_snowflake_and_postgres_types() -> None:
    assert kind_of("NUMBER(19,0)") == "integer"
    assert kind_of("NUMBER(18,2)") == "number"
    assert kind_of("FLOAT") == "number"
    assert kind_of("BOOLEAN") == "boolean"
    assert kind_of("DATE") == "date"
    assert kind_of("TIMESTAMP_NTZ") == "datetime"
    assert kind_of("bigint") == "integer"
    assert kind_of("integer") == "integer"
    assert kind_of("double precision") == "number"
    assert kind_of("numeric") == "number"
    assert kind_of("boolean") == "boolean"
    assert kind_of("timestamp with time zone") == "datetime"
    assert kind_of("timestamp without time zone") == "datetime"
    assert kind_of("jsonb") == "text"
    assert kind_of("text") == "text"
