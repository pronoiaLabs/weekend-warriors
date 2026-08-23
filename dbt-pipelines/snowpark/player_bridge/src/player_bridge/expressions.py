"""Snowpark column builders that push evidence.py's rules into SQL.

Each builder is generated from the same dict the pure function reads, so the
two can never disagree on a vocabulary. The string functions mirror
evidence.normalize_name step for step.
"""

from __future__ import annotations

from snowflake.snowpark import Column
from snowflake.snowpark import functions as F

from player_bridge.evidence import EVIDENCE_FIELDS, POSITION_TO_GROUP, TO_NFLVERSE_TEAM


def _upper_trim(col: Column) -> Column:
    return F.upper(F.trim(col.cast("string")))


def nflverse_team_col(col: Column) -> Column:
    """CASE over TO_NFLVERSE_TEAM; unknown codes pass through; '' -> NULL."""
    code = F.nullif(_upper_trim(col), F.lit(""))
    expr = None
    for vendor_code, nflverse_code in TO_NFLVERSE_TEAM.items():
        cond = code == F.lit(vendor_code)
        expr = (
            F.when(cond, F.lit(nflverse_code))
            if expr is None
            else expr.when(cond, F.lit(nflverse_code))
        )
    return expr.otherwise(code)


def position_group_col(col: Column) -> Column:
    """CASE over POSITION_TO_GROUP; unknown codes -> NULL."""
    code = _upper_trim(col)
    expr = None
    for position, group in POSITION_TO_GROUP.items():
        cond = code == F.lit(position)
        expr = F.when(cond, F.lit(group)) if expr is None else expr.when(cond, F.lit(group))
    return expr.otherwise(F.lit(None))


def normalize_name_col(col: Column) -> Column:
    """upper -> strip JR/SR/II/III/IV -> drop non-alnum -> collapse spaces -> NULLIF ''."""
    out = F.upper(col.cast("string"))
    out = F.regexp_replace(out, F.lit(r"\s+(JR\.?|SR\.?|II|III|IV)$"), F.lit(""))
    out = F.regexp_replace(out, F.lit("[^A-Z0-9 ]"), F.lit(""))
    out = F.regexp_replace(out, F.lit(r"\s+"), F.lit(" "))
    return F.nullif(F.trim(out), F.lit(""))


def jersey_col(col: Column) -> Column:
    """'12', 12, 12.0 -> '12'; anything non-numeric -> NULL."""
    return F.call_function("TRY_TO_NUMBER", col.cast("string")).cast("string")


def evidence_hash_col(**cols: Column) -> Column:
    """sha2(concat_ws('|', coalesce(upper(trim(x)), '') ...), 256) in EVIDENCE_FIELDS order."""
    unknown = set(cols) - set(EVIDENCE_FIELDS)
    if unknown:
        raise ValueError(f"unknown evidence fields: {sorted(unknown)}")
    parts = [
        F.coalesce(_upper_trim(cols[name]), F.lit("")) if name in cols else F.lit("")
        for name in EVIDENCE_FIELDS
    ]
    return F.sha2(F.concat_ws(F.lit("|"), *parts), 256)


def search_text_col(
    full_name: Column, position: Column, team: Column, jersey: Column, college: Column
) -> Column:
    """Space-joined present parts, same shape as the service's SEARCH_TEXT."""
    return F.call_function(
        "ARRAY_TO_STRING",
        F.call_function(
            "ARRAY_CONSTRUCT_COMPACT",
            full_name,
            position,
            team,
            F.iff(jersey.is_null(), F.lit(None), F.concat(F.lit("#"), jersey)),
            college,
        ),
        F.lit(" "),
    )


def search_filter_col(team: Column, pos_group: Column) -> Column:
    """{"@or": [{"@eq": {"LATEST_TEAM": t}}, {"@eq": {"POS_GROUP": g}}]}.

    Narrows to the single clause when one side is NULL; NULL when both are.
    """
    team_clause = F.object_construct(F.lit("@eq"), F.object_construct(F.lit("LATEST_TEAM"), team))
    group_clause = F.object_construct(
        F.lit("@eq"), F.object_construct(F.lit("POS_GROUP"), pos_group)
    )
    both = F.object_construct(F.lit("@or"), F.array_construct(team_clause, group_clause))
    return (
        F.when(team.is_not_null() & pos_group.is_not_null(), both)
        .when(team.is_not_null(), team_clause)
        .when(pos_group.is_not_null(), group_clause)
        .otherwise(F.lit(None))
    )


def render_col(
    full_name: Column,
    position: Column,
    team: Column,
    jersey: Column,
    college: Column,
    birth_year: Column,
) -> Column:
    """One record as the AI confirmation prompt sees it (evidence.render)."""
    return F.call_function(
        "ARRAY_TO_STRING",
        F.call_function(
            "ARRAY_CONSTRUCT_COMPACT",
            F.coalesce(full_name, F.lit("unknown name")),
            position,
            team,
            F.iff(jersey.is_null(), F.lit(None), F.concat(F.lit("#"), jersey)),
            college,
            F.iff(
                birth_year.is_null(),
                F.lit(None),
                F.concat(F.lit("born "), birth_year.cast("string")),
            ),
        ),
        F.lit(", "),
    )
