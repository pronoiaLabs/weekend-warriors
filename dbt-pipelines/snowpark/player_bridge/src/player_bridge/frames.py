"""The three player frames, read straight from NFL_PROD_DB.RAW.

RAW rather than dbt models on purpose: every environment reads the same prod
RAW tables, so the procedure has no ordering dependency on the dbt DAG and
works on a first-ever dev build. The vendor frame (BallDontLie + Sleeper) is
the left side of every tier; the index frame (nflverse players) is the right
side and is also what the search service indexes.

Column contract (uppercase, shared by every module):
  vendor rows : VENDOR, VENDOR_PLAYER_ID, FULL_NAME, NAME_NORM, POSITION, POS_GROUP,
                TEAM, JERSEY, COLLEGE, COLLEGE_NORM, BIRTH_YEAR, GSIS_ID_HINT,
                ESPN_ID_HINT, EVIDENCE_HASH, SEARCH_TEXT, SEARCH_FILTER, RENDER
  index rows  : GSIS_ID, ESPN_ID, DISPLAY_NAME, NAME_NORM, POSITION, POS_GROUP, TEAM,
                JERSEY, COLLEGE, COLLEGE_NORM, BIRTH_YEAR, RENDER
"""

from __future__ import annotations

from snowflake.snowpark import DataFrame, Session
from snowflake.snowpark import functions as F

from player_bridge import expressions as X

RAW = "NFL_PROD_DB.RAW"

VENDOR_BDL = "bdl"
VENDOR_SLEEPER = "sleeper"


def _derive(df: DataFrame) -> DataFrame:
    """Add the computed columns every vendor row carries."""
    return df.with_columns(
        ["NAME_NORM", "POS_GROUP", "COLLEGE_NORM", "EVIDENCE_HASH", "SEARCH_TEXT", "SEARCH_FILTER"],
        [
            X.normalize_name_col(F.col("FULL_NAME")),
            X.position_group_col(F.col("POSITION")),
            F.nullif(F.upper(F.trim(F.col("COLLEGE"))), F.lit("")),
            X.evidence_hash_col(
                full_name=F.col("FULL_NAME"),
                team=F.col("TEAM"),
                position=F.col("POSITION"),
                jersey=F.col("JERSEY"),
                college=F.col("COLLEGE"),
            ),
            X.search_text_col(
                F.col("FULL_NAME"),
                F.col("POSITION"),
                F.col("TEAM"),
                F.col("JERSEY"),
                F.col("COLLEGE"),
            ),
            F.lit(None),  # placeholder, replaced below once POS_GROUP exists
        ],
    ).with_columns(
        ["SEARCH_FILTER", "RENDER"],
        [
            X.search_filter_col(F.col("TEAM"), F.col("POS_GROUP")),
            X.render_col(
                F.col("FULL_NAME"),
                F.col("POSITION"),
                F.col("TEAM"),
                F.col("JERSEY"),
                F.col("COLLEGE"),
                F.col("BIRTH_YEAR"),
            ),
        ],
    )


def bdl_frame(session: Session) -> DataFrame:
    """Every BallDontLie player row. BDL has an age, not a birth date, so no year."""
    p = session.table(f"{RAW}.PLAYERS")
    return _derive(
        p.select(
            F.lit(VENDOR_BDL).alias("VENDOR"),
            p["ID"].cast("string").alias("VENDOR_PLAYER_ID"),
            F.trim(F.concat_ws(F.lit(" "), p["FIRST_NAME"], p["LAST_NAME"])).alias("FULL_NAME"),
            F.upper(F.trim(p["POSITION_ABBREVIATION"])).alias("POSITION"),
            X.nflverse_team_col(p["TEAM__ABBREVIATION"]).alias("TEAM"),
            X.jersey_col(p["JERSEY_NUMBER"]).alias("JERSEY"),
            p["COLLEGE"].alias("COLLEGE"),
            F.lit(None).cast("integer").alias("BIRTH_YEAR"),
            F.lit(None).cast("string").alias("GSIS_ID_HINT"),
            F.lit(None).cast("string").alias("ESPN_ID_HINT"),
        )
    )


def sleeper_frame(session: Session) -> DataFrame:
    """Active, rostered, non-DEF Sleeper players (~3.2k of the 12k dump)."""
    s = session.table(f"{RAW}.SLEEPER_PLAYERS")
    rostered = s.filter(
        (s["ACTIVE"] == F.lit(True)) & s["TEAM"].is_not_null() & (s["POSITION"] != F.lit("DEF"))
    )
    return _derive(
        rostered.select(
            F.lit(VENDOR_SLEEPER).alias("VENDOR"),
            rostered["PLAYER_ID"].cast("string").alias("VENDOR_PLAYER_ID"),
            F.coalesce(
                rostered["FULL_NAME"],
                F.trim(F.concat_ws(F.lit(" "), rostered["FIRST_NAME"], rostered["LAST_NAME"])),
            ).alias("FULL_NAME"),
            F.upper(F.trim(rostered["POSITION"])).alias("POSITION"),
            X.nflverse_team_col(rostered["TEAM"]).alias("TEAM"),
            X.jersey_col(rostered["NUMBER"]).alias("JERSEY"),
            rostered["COLLEGE"].alias("COLLEGE"),
            F.year(F.call_function("TRY_TO_DATE", rostered["BIRTH_DATE"].cast("string")))
            .cast("integer")
            .alias("BIRTH_YEAR"),
            F.nullif(F.trim(rostered["GSIS_ID"].cast("string")), F.lit("")).alias("GSIS_ID_HINT"),
            X.jersey_col(rostered["ESPN_ID"]).alias("ESPN_ID_HINT"),
        )
    )


def vendor_frame(session: Session) -> DataFrame:
    return bdl_frame(session).union_all(sleeper_frame(session))


def index_frame(session: Session) -> DataFrame:
    """nflverse players, the spine: one row per gsis_id (unique, tested in dbt)."""
    n = session.table(f"{RAW}.NFLVERSE_PLAYERS").filter(F.col("GSIS_ID").is_not_null())
    base = n.select(
        n["GSIS_ID"].alias("GSIS_ID"),
        X.jersey_col(n["ESPN_ID"]).alias("ESPN_ID"),
        n["DISPLAY_NAME"].alias("DISPLAY_NAME"),
        F.upper(F.trim(n["POSITION"])).alias("POSITION"),
        F.upper(F.trim(n["LATEST_TEAM"])).alias("TEAM"),
        X.jersey_col(n["JERSEY_NUMBER"]).alias("JERSEY"),
        n["COLLEGE_NAME"].alias("COLLEGE"),
        F.year(F.call_function("TRY_TO_DATE", n["BIRTH_DATE"].cast("string")))
        .cast("integer")
        .alias("BIRTH_YEAR"),
    )
    return base.with_columns(
        ["NAME_NORM", "POS_GROUP", "COLLEGE_NORM", "RENDER"],
        [
            X.normalize_name_col(F.col("DISPLAY_NAME")),
            X.position_group_col(F.col("POSITION")),
            F.nullif(F.upper(F.trim(F.col("COLLEGE"))), F.lit("")),
            X.render_col(
                F.col("DISPLAY_NAME"),
                F.col("POSITION"),
                F.col("TEAM"),
                F.col("JERSEY"),
                F.col("COLLEGE"),
                F.col("BIRTH_YEAR"),
            ),
        ],
    )
