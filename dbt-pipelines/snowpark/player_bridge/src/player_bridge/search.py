"""Candidate generation: one batch Cortex Search job over every pending row.

Batch rather than interactive because this runs set-based inside a
procedure with thousands of queries at once, and because batch mode queries
a SUSPENDED service (it spins its own resources), so the service can sleep
between refreshes. The call is written as SQL rather than through
join_table_function: LATERAL with named arguments is the documented form.

Output shape (measured 2026-08-23): the service's indexed columns plus
METADATA$REQUEST_ID, METADATA$RANK (1 = best), METADATA$ERROR and
METADATA$RESULT_DETAIL, a JSON string {"scores": {"cosine_similarity": x,
"text_match": y}}. HIT_RANK is the service's own rank; HIT_SCORE is the
cosine similarity, kept on the bridge row as MATCH_SCORE for audit only
(no tier thresholds on it).
"""

from __future__ import annotations

from snowflake.snowpark import DataFrame, Session

SERVICE = "NFL_PROD_DB.DIM.PLAYER_SEARCH"
LIMIT = 5


def batch_search(
    session: Session, pending_table: str, service: str = SERVICE, limit: int = LIMIT
) -> DataFrame:
    """Top-`limit` index hits per pending row: keys, HIT_RANK, HIT_GSIS_ID, HIT_SCORE."""
    return session.sql(
        f"""
        SELECT
            p.VENDOR,
            p.VENDOR_PLAYER_ID,
            r."METADATA$RANK"                                            AS HIT_RANK,
            r.GSIS_ID                                                    AS HIT_GSIS_ID,
            TRY_TO_DOUBLE(
                TRY_PARSE_JSON(r."METADATA$RESULT_DETAIL"::STRING):scores.cosine_similarity::STRING
            )                                                            AS HIT_SCORE
        FROM {pending_table} p,
        LATERAL CORTEX_SEARCH_BATCH(
            service_name => '{service}',
            query        => p.SEARCH_TEXT,
            filter       => p.SEARCH_FILTER,
            limit        => {int(limit)}
        ) r
        WHERE r."METADATA$ERROR" IS NULL
        """
    )
