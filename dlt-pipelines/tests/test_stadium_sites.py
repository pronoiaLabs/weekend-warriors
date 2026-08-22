"""Keep the dbt stadium seed and the extractor site list on the same stadium_ids.

The SPCS image cannot see dbt-pipelines/, and the dbt project object cannot see
dlt-pipelines/. Coords are therefore duplicated; this test is the lockstep.
"""
from __future__ import annotations

import csv
from pathlib import Path

_REPO = Path(__file__).resolve().parents[2]
_SEED = _REPO / "dbt-pipelines" / "seeds" / "nfl" / "seed_nfl_stadiums.csv"
_SITES = _REPO / "dlt-pipelines" / "pipelines" / "batch" / "data" / "nfl_stadium_sites.csv"


def _ids(path: Path, column: str) -> set[str]:
    with path.open(newline="") as fh:
        return {row[column] for row in csv.DictReader(fh)}


def test_seed_and_extractor_share_the_same_stadium_ids() -> None:
    seed_ids = _ids(_SEED, "stadium_id")
    site_ids = _ids(_SITES, "stadium_id")
    assert seed_ids == site_ids, (
        f"in seed only: {sorted(seed_ids - site_ids)}; "
        f"in sites only: {sorted(site_ids - seed_ids)}"
    )


def test_seed_has_the_47_raw_venue_strings() -> None:
    with _SEED.open(newline="") as fh:
        names = [row["venue_name"] for row in csv.DictReader(fh)]
    assert len(names) == 47
    assert len(set(names)) == 47
    assert "GEHA Field at Arrowhead Stadium" in names
    assert "Arrowhead Stadium" in names
    assert "Highmark Stadium (Old)" in names
    assert "FC Bayern Munich Stadium" in names
