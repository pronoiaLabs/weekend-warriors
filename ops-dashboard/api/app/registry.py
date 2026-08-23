"""Sport and pipeline discovery from DLT_DB.OPS.PIPELINE_REGISTRY.

The registry is the only source that knows the sport list, the pipeline-to-sport
mapping, and the cron schedules. The run table cannot serve any of those: it
only contains runs that happened. Nothing here is hardcoded to a sport, so a
new sport is a registry row, not a code change.

Sport identity is TARGET_DATABASE, not SOURCE: SOURCE is 'rest_api' for every
real pipeline. The 'sample' smoke test (TARGET_DATABASE=DLT, SCHEDULE null) is
excluded by requiring a schedule. DLT_DB.OPS.PIPELINE_RUNS spells SPORT with
the same uppercase TARGET_DATABASE stems, so registry values compare directly
against the table with no case folding (unlike V_DBT_RUNS, which is lowercase).
"""

import time
from dataclasses import dataclass

from app import db

_TTL_SECONDS = 60


@dataclass(frozen=True)
class Pipeline:
    name: str
    sport: str
    schedule: str  # 5-field cron, UTC
    enabled: bool


_cache: tuple[float, list[Pipeline]] | None = None


def load_registry() -> list[Pipeline]:
    global _cache
    now = time.monotonic()
    if _cache is not None and now - _cache[0] < _TTL_SECONDS:
        return _cache[1]
    from app import datasource

    rows = db.query(datasource.registry_sql(), tag={"tile": "registry"})
    pipelines = [
        Pipeline(
            name=r["name"],
            sport=r["target_database"],
            schedule=r["schedule"],
            enabled=bool(r["enabled"]),
        )
        for r in rows
    ]
    _cache = (now, pipelines)
    return pipelines


def sports() -> list[str]:
    return sorted({p.sport for p in load_registry()})


def pipelines_for(sport: str) -> list[Pipeline]:
    return [p for p in load_registry() if p.sport == sport]


def invalidate() -> None:
    global _cache
    _cache = None
