"""The two tables the procedure owns, and the rows still waiting on a decision.

PLAYER_BRIDGE holds stable ids only. Team, jersey and position are evidence
at match time and never keys, so a trade changes nothing. A row is written
once and never re-evaluated unless the caller asks for a full refresh.

PLAYER_BRIDGE_UNMATCHED is the retry ledger: a player lands here with the
hash of the evidence that failed to match, and is retried only when that
hash changes (a rookie who finally gets a team and a number, a corrected
name). A perpetual no-match therefore costs nothing after its first attempt.
"""

from __future__ import annotations

from snowflake.snowpark import DataFrame, Session
from snowflake.snowpark import functions as F

BRIDGE = "PLAYER_BRIDGE"
UNMATCHED = "PLAYER_BRIDGE_UNMATCHED"

KEYS = ["VENDOR", "VENDOR_PLAYER_ID"]

BRIDGE_DDL = """
CREATE TABLE IF NOT EXISTS {fqn}.PLAYER_BRIDGE (
    VENDOR            VARCHAR      NOT NULL,
    VENDOR_PLAYER_ID  VARCHAR      NOT NULL,
    GSIS_ID           VARCHAR      NOT NULL,
    MATCH_METHOD      VARCHAR      NOT NULL,
    MATCH_SCORE       FLOAT,
    SEARCH_GSIS_ID    VARCHAR,
    SEARCH_AGREES     BOOLEAN,
    EVIDENCE_HASH     VARCHAR      NOT NULL,
    DECIDED_AT        TIMESTAMP_TZ NOT NULL DEFAULT CURRENT_TIMESTAMP(),
    CONSTRAINT PK_PLAYER_BRIDGE PRIMARY KEY (VENDOR, VENDOR_PLAYER_ID)
)
COMMENT = 'Vendor id -> nflverse gsis_id, decided once by SP_PLAYER_BRIDGE. Never edit by hand.'
"""

UNMATCHED_DDL = """
CREATE TABLE IF NOT EXISTS {fqn}.PLAYER_BRIDGE_UNMATCHED (
    VENDOR            VARCHAR      NOT NULL,
    VENDOR_PLAYER_ID  VARCHAR      NOT NULL,
    EVIDENCE_HASH     VARCHAR      NOT NULL,
    EVIDENCE          VARIANT,
    CANDIDATES        VARIANT,
    REASON            VARCHAR      NOT NULL,
    LAST_TRIED_AT     TIMESTAMP_TZ NOT NULL DEFAULT CURRENT_TIMESTAMP(),
    CONSTRAINT PK_PLAYER_BRIDGE_UNMATCHED PRIMARY KEY (VENDOR, VENDOR_PLAYER_ID)
)
COMMENT = 'Players SP_PLAYER_BRIDGE could not place; retried only when the evidence hash changes.'
"""


def ensure_tables(session: Session, fqn: str, full_refresh: bool) -> None:
    session.sql(BRIDGE_DDL.format(fqn=fqn)).collect()
    session.sql(UNMATCHED_DDL.format(fqn=fqn)).collect()
    if full_refresh:
        # TRUNCATE keeps the objects (and any grants on them); the caller asked
        # to re-decide every player, which is the only sanctioned rewrite.
        session.sql(f"TRUNCATE TABLE {fqn}.{BRIDGE}").collect()
        session.sql(f"TRUNCATE TABLE {fqn}.{UNMATCHED}").collect()


def unbridged(session: Session, fqn: str, vendors: DataFrame) -> DataFrame:
    """Vendor rows with no bridge row and no unmatched row carrying today's evidence."""
    bridge = session.table(f"{fqn}.{BRIDGE}").select(*KEYS)
    open_rows = session.table(f"{fqn}.{UNMATCHED}").select(
        F.col("VENDOR").alias("U_VENDOR"),
        F.col("VENDOR_PLAYER_ID").alias("U_VENDOR_PLAYER_ID"),
        F.col("EVIDENCE_HASH").alias("U_EVIDENCE_HASH"),
    )
    fresh = vendors.join(bridge, on=KEYS, how="left_anti")
    joined = fresh.join(
        open_rows,
        (fresh["VENDOR"] == open_rows["U_VENDOR"])
        & (fresh["VENDOR_PLAYER_ID"] == open_rows["U_VENDOR_PLAYER_ID"]),
        how="left",
    )
    return joined.filter(
        joined["U_EVIDENCE_HASH"].is_null() | (joined["U_EVIDENCE_HASH"] != joined["EVIDENCE_HASH"])
    ).select(*vendors.columns)


def merge_bridge(session: Session, fqn: str, rows_table: str) -> int:
    """Insert (or, defensively, refresh) decided rows; returns rows affected."""
    result = session.sql(
        f"""
        MERGE INTO {fqn}.{BRIDGE} t
        USING {rows_table} s
          ON t.VENDOR = s.VENDOR AND t.VENDOR_PLAYER_ID = s.VENDOR_PLAYER_ID
        WHEN MATCHED THEN UPDATE SET
            GSIS_ID = s.GSIS_ID, MATCH_METHOD = s.MATCH_METHOD, MATCH_SCORE = s.MATCH_SCORE,
            SEARCH_GSIS_ID = s.SEARCH_GSIS_ID, SEARCH_AGREES = s.SEARCH_AGREES,
            EVIDENCE_HASH = s.EVIDENCE_HASH, DECIDED_AT = CURRENT_TIMESTAMP()
        WHEN NOT MATCHED THEN INSERT
            (VENDOR, VENDOR_PLAYER_ID, GSIS_ID, MATCH_METHOD, MATCH_SCORE,
             SEARCH_GSIS_ID, SEARCH_AGREES, EVIDENCE_HASH, DECIDED_AT)
          VALUES
            (s.VENDOR, s.VENDOR_PLAYER_ID, s.GSIS_ID, s.MATCH_METHOD, s.MATCH_SCORE,
             s.SEARCH_GSIS_ID, s.SEARCH_AGREES, s.EVIDENCE_HASH, CURRENT_TIMESTAMP())
        """
    ).collect()
    # A decided player leaves the retry ledger.
    session.sql(
        f"""
        DELETE FROM {fqn}.{UNMATCHED} u
        USING {rows_table} s
        WHERE u.VENDOR = s.VENDOR AND u.VENDOR_PLAYER_ID = s.VENDOR_PLAYER_ID
        """
    ).collect()
    return _affected(result)


def merge_unmatched(session: Session, fqn: str, rows_table: str) -> int:
    result = session.sql(
        f"""
        MERGE INTO {fqn}.{UNMATCHED} t
        USING {rows_table} s
          ON t.VENDOR = s.VENDOR AND t.VENDOR_PLAYER_ID = s.VENDOR_PLAYER_ID
        WHEN MATCHED THEN UPDATE SET
            EVIDENCE_HASH = s.EVIDENCE_HASH, EVIDENCE = s.EVIDENCE, CANDIDATES = s.CANDIDATES,
            REASON = s.REASON, LAST_TRIED_AT = CURRENT_TIMESTAMP()
        WHEN NOT MATCHED THEN INSERT
            (VENDOR, VENDOR_PLAYER_ID, EVIDENCE_HASH, EVIDENCE, CANDIDATES, REASON, LAST_TRIED_AT)
          VALUES
            (s.VENDOR, s.VENDOR_PLAYER_ID, s.EVIDENCE_HASH, s.EVIDENCE, s.CANDIDATES, s.REASON,
             CURRENT_TIMESTAMP())
        """
    ).collect()
    return _affected(result)


def _affected(rows: list) -> int:
    """MERGE returns one row of counters whose names vary; sum whatever came back."""
    if not rows:
        return 0
    return int(sum(v for v in rows[0].as_dict().values() if isinstance(v, int)))
