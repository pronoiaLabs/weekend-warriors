"""Sport derivation rules against the recorded registry fixture."""

import json
from pathlib import Path

FIXTURE = Path(__file__).parents[1] / "app" / "fixtures" / "registry.json"


def test_sport_derivation() -> None:
    rows = json.loads(FIXTURE.read_text())
    sports = sorted({r["target_database"] for r in rows if r["schedule"] is not None})
    assert sports == ["NFL"]


def test_sample_pipeline_excluded_by_schedule() -> None:
    rows = json.loads(FIXTURE.read_text())
    sample = [r for r in rows if r["name"] == "sample"]
    assert sample and sample[0]["schedule"] is None
    assert sample[0]["target_database"] == "DLT"
