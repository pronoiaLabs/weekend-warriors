"""A sport profile is a table map plus a capability list. It holds no SQL and no
column names: the APP marts carry sport-agnostic columns, so a tile reads the
same columns for every sport and only the table's location differs.

Declared per sport in app/sports/profiles/<sport>.py and registered in
app/sports/registry.py. Frozen: a profile is configuration, never mutated.
"""

import datetime as dt

from pydantic import BaseModel, ConfigDict, Field

from app import config
from app.sports.capabilities import Capability
from app.sports.payloads import CapabilitiesPayload


class SportProfile(BaseModel):
    model_config = ConfigDict(frozen=True)

    key: str = Field(pattern=r"^[a-z]+$", description="URL segment and env stem, e.g. nfl")
    label: str
    default_season: int
    tables: dict[Capability, str] = Field(
        default_factory=dict, description="capability -> mart name inside <db>.<schema>"
    )
    extensions: tuple[str, ...] = ()
    vendors: tuple[str, ...] = Field(default=(), description="books the slate can filter by")
    default_vendor: str | None = None

    @property
    def capabilities(self) -> list[Capability]:
        return list(self.tables)

    def has(self, cap: Capability) -> bool:
        return cap in self.tables

    def location(self) -> tuple[str, str]:
        return config.app_location(self.key)

    def fqn(self, cap: Capability) -> str:
        db, schema = self.location()
        return f"{db}.{schema}.{self.tables[cap]}"

    def describe(self, as_of: dt.datetime, data: str) -> CapabilitiesPayload:
        db, schema = self.location()
        return CapabilitiesPayload(
            sport=self.key,
            label=self.label,
            default_season=self.default_season,
            capabilities=self.capabilities,
            extensions=list(self.extensions),
            vendors=list(self.vendors),
            default_vendor=self.default_vendor,
            app_location=f"{db}.{schema}",
            as_of=as_of,
            data=data,
        )
