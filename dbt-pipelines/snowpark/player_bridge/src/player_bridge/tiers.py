"""The deterministic tiers, in priority order: id, exact, tiebreak.

A vendor row takes the best tier that produces exactly ONE nflverse
candidate. Two candidates at the best tier is an ambiguity, and an ambiguous
row matches nobody here: it falls through to the search and AI tier, which
sees every candidate and can say no to all of them.
"""

from __future__ import annotations

from snowflake.snowpark import DataFrame, Window
from snowflake.snowpark import functions as F

from player_bridge.tables import KEYS

METHOD_ID = "id"
METHOD_EXACT = "exact"
METHOD_TIEBREAK = "tiebreak"
METHOD_SEARCH_AI = "search_ai"


def _pairs(pending: DataFrame, index: DataFrame, cond, method: str, priority: int) -> DataFrame:
    return pending.join(index, cond).select(
        pending["VENDOR"].alias("VENDOR"),
        pending["VENDOR_PLAYER_ID"].alias("VENDOR_PLAYER_ID"),
        index["GSIS_ID"].alias("GSIS_ID"),
        F.lit(method).alias("MATCH_METHOD"),
        F.lit(priority).alias("PRIORITY"),
    )


def deterministic(pending: DataFrame, index: DataFrame) -> DataFrame:
    """One row per vendor player the deterministic tiers decide: keys, GSIS_ID, MATCH_METHOD."""
    p, i = pending, index

    same_name_team = (p["NAME_NORM"] == i["NAME_NORM"]) & (p["TEAM"] == i["TEAM"])

    by_id = _pairs(
        p,
        i,
        (p["GSIS_ID_HINT"] == i["GSIS_ID"]) | (p["ESPN_ID_HINT"] == i["ESPN_ID"]),
        METHOD_ID,
        1,
    )
    exact = _pairs(p, i, same_name_team & (p["POS_GROUP"] == i["POS_GROUP"]), METHOD_EXACT, 2)
    tiebreak = _pairs(
        p,
        i,
        same_name_team
        & (
            (p["JERSEY"] == i["JERSEY"])
            | (p["COLLEGE_NORM"] == i["COLLEGE_NORM"])
            | (p["BIRTH_YEAR"] == i["BIRTH_YEAR"])
        ),
        METHOD_TIEBREAK,
        3,
    )

    candidates = by_id.union_all(exact).union_all(tiebreak).distinct()
    per_row = Window.partition_by(*KEYS)
    best = candidates.with_column("BEST", F.min(F.col("PRIORITY")).over(per_row)).filter(
        F.col("PRIORITY") == F.col("BEST")
    )
    counted = best.with_column("N_CANDIDATES", F.count_distinct(F.col("GSIS_ID")).over(per_row))
    return (
        counted.filter(F.col("N_CANDIDATES") == 1)
        .select(*KEYS, "GSIS_ID", "MATCH_METHOD")
        .distinct()
    )
