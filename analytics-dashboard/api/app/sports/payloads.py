"""Response models. Every route declares one of these as its response_model, so
the OpenAPI document carries real schemas and the frontend types in
web/src/api/sports/types.ts have something exact to mirror.

Envelope is the shape every tile returns: the sport and season it answers for,
the clock it was served at, the rows, and in dev the SQL that produced them.
"""

import datetime as dt
from typing import Generic, TypeVar

from pydantic import BaseModel, ConfigDict, Field

from app.sports.capabilities import Capability


class HealthPayload(BaseModel):
    ok: bool
    data: str
    backend: str
    role: str
    sports: list[str]
    as_of: dt.datetime


class CapabilitiesPayload(BaseModel):
    model_config = ConfigDict(frozen=True)

    sport: str
    label: str
    default_season: int
    capabilities: list[Capability]
    extensions: list[str] = Field(default_factory=list)
    vendors: list[str] = Field(default_factory=list)
    default_vendor: str | None = None
    app_location: str
    as_of: dt.datetime
    data: str


RowT = TypeVar("RowT", bound=BaseModel)


class Envelope(BaseModel, Generic[RowT]):
    sport: str
    season: int
    as_of: dt.datetime
    rows: list[RowT]
    query: str | None = None
