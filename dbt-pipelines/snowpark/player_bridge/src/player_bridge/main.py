"""Procedure handler: decide every vendor player not yet decided, then stop.

WHAT ONE CALL DOES
  1. Ensure PLAYER_BRIDGE and PLAYER_BRIDGE_UNMATCHED exist in the target
     schema (truncate both on full_refresh).
  2. Find the unbridged vendor rows (tables.unbridged). If there are none,
     return immediately: no search job, no AI tokens. This is the steady
     state, and why dbt can call this on every build for free.
  3. Deterministic tiers over those rows (tiers.deterministic).
  4. One batch search for EVERY pending row (search.batch_search): the top
     hit audits the deterministic picks (SEARCH_AGREES), and the top-k are
     the candidates for the residual.
  5. Confirmation of the residual's candidates (confirm.confirm): the AI
     verdict AND the name gate. Exactly one yes -> decided as search_ai;
     none -> no_candidates, name_rejected (the model said yes, the gate no)
     or ai_rejected; several -> ambiguous. All land in the ledger with their
     candidates and both verdicts.
  6. MERGE both tables, return a JSON summary.

Every intermediate frame is materialized to a TEMPORARY table in the target
schema (_cache): Snowpark is lazy, and without that a frame used twice would
run the search job or the AI prompts twice. Explicitly qualified rather than
DataFrame.cache_result() because the caller's session may have no current
database (a plain CALL from the CLI), and the procedure must not depend on
or alter the caller's context.
"""

from __future__ import annotations

import json

from snowflake.snowpark import DataFrame, Session
from snowflake.snowpark import functions as F

from player_bridge import tables
from player_bridge.confirm import confirm
from player_bridge.frames import index_frame, vendor_frame
from player_bridge.search import LIMIT, SERVICE, batch_search
from player_bridge.tables import KEYS
from player_bridge.tiers import METHOD_SEARCH_AI, deterministic

REASON_NO_CANDIDATES = "no_candidates"
REASON_AI_REJECTED = "ai_rejected"
REASON_NAME_REJECTED = "name_rejected"
REASON_AMBIGUOUS = "ambiguous"


def _cache(session: Session, df: DataFrame, fqn: str, name: str) -> tuple[DataFrame, str]:
    """Materialize df as <fqn>.PLAYER_BRIDGE__<name> (temporary); return (frame, table name)."""
    table = f"{fqn}.PLAYER_BRIDGE__{name}"
    df.write.save_as_table(table, mode="overwrite", table_type="temporary")
    return session.table(table), table


def run(session: Session, target_db: str, target_schema: str, full_refresh: bool = False) -> str:
    fqn = f"{target_db}.{target_schema}"
    tables.ensure_tables(session, fqn, full_refresh)

    pending, pending_table = _cache(
        session, tables.unbridged(session, fqn, vendor_frame(session)), fqn, "PENDING"
    )
    n_pending = pending.count()
    summary: dict = {"target": fqn, "full_refresh": bool(full_refresh), "new": n_pending}
    if n_pending == 0:
        return json.dumps(summary)

    index, _ = _cache(session, index_frame(session), fqn, "INDEX")
    decided, _ = _cache(session, deterministic(pending, index), fqn, "DETERMINISTIC")
    hits, _ = _cache(session, batch_search(session, pending_table, SERVICE, LIMIT), fqn, "HITS")
    top = hits.filter(F.col("HIT_RANK") == 1)

    # Deterministic rows, audited by the search's top hit.
    det_rows = (
        decided.join(top, on=KEYS, how="left")
        .join(pending.select(*KEYS, "EVIDENCE_HASH"), on=KEYS)
        .select(
            *KEYS,
            F.col("GSIS_ID"),
            F.col("MATCH_METHOD"),
            F.col("HIT_SCORE").alias("MATCH_SCORE"),
            F.col("HIT_GSIS_ID").alias("SEARCH_GSIS_ID"),
            F.iff(
                F.col("HIT_GSIS_ID").is_null(),
                F.lit(None),
                F.col("GSIS_ID") == F.col("HIT_GSIS_ID"),
            ).alias("SEARCH_AGREES"),
            F.col("EVIDENCE_HASH"),
        )
    )

    # The residual: every pending row the tiers did not decide.
    residual, _ = _cache(
        session, pending.join(decided.select(*KEYS), on=KEYS, how="left_anti"), fqn, "RESIDUAL"
    )
    pairs = (
        residual.join(hits, on=KEYS)
        .join(index, hits["HIT_GSIS_ID"] == index["GSIS_ID"])
        .select(
            residual["VENDOR"].alias("VENDOR"),
            residual["VENDOR_PLAYER_ID"].alias("VENDOR_PLAYER_ID"),
            hits["HIT_RANK"].alias("HIT_RANK"),
            hits["HIT_GSIS_ID"].alias("HIT_GSIS_ID"),
            hits["HIT_SCORE"].alias("HIT_SCORE"),
            residual["RENDER"].alias("A_TEXT"),
            index["RENDER"].alias("B_TEXT"),
            residual["NAME_NORM"].alias("A_NAME_NORM"),
            index["NAME_NORM"].alias("B_NAME_NORM"),
        )
    )
    verdicts, _ = _cache(session, confirm(pairs), fqn, "VERDICTS")
    n_pairs = verdicts.count()

    per_row = verdicts.group_by(*KEYS).agg(
        F.sum(F.iff(F.col("IS_SAME"), F.lit(1), F.lit(0))).alias("N_YES"),
        F.sum(F.iff(F.col("AI_SAME"), F.lit(1), F.lit(0))).alias("N_AI_YES"),
        F.max(F.iff(F.col("IS_SAME"), F.col("HIT_GSIS_ID"), F.lit(None))).alias("YES_GSIS_ID"),
        F.max(F.iff(F.col("IS_SAME"), F.col("HIT_SCORE"), F.lit(None))).alias("YES_SCORE"),
        F.max(F.iff(F.col("HIT_RANK") == 1, F.col("HIT_GSIS_ID"), F.lit(None))).alias(
            "TOP_GSIS_ID"
        ),
        F.array_agg(
            F.object_construct(
                F.lit("rank"),
                F.col("HIT_RANK"),
                F.lit("gsis_id"),
                F.col("HIT_GSIS_ID"),
                F.lit("score"),
                F.col("HIT_SCORE"),
                F.lit("record"),
                F.col("B_TEXT"),
                F.lit("ai_same"),
                F.col("AI_SAME"),
                F.lit("name_ok"),
                F.col("NAME_OK"),
            )
        )
        .within_group(F.col("HIT_RANK"))
        .alias("CANDIDATES"),
    )

    ai_rows = (
        per_row.filter(F.col("N_YES") == 1)
        .join(pending.select(*KEYS, "EVIDENCE_HASH"), on=KEYS)
        .select(
            *KEYS,
            F.col("YES_GSIS_ID").alias("GSIS_ID"),
            F.lit(METHOD_SEARCH_AI).alias("MATCH_METHOD"),
            F.col("YES_SCORE").alias("MATCH_SCORE"),
            F.col("TOP_GSIS_ID").alias("SEARCH_GSIS_ID"),
            (F.col("YES_GSIS_ID") == F.col("TOP_GSIS_ID")).alias("SEARCH_AGREES"),
            F.col("EVIDENCE_HASH"),
        )
    )

    open_rows = (
        residual.join(per_row, on=KEYS, how="left")
        .filter(F.col("N_YES").is_null() | (F.col("N_YES") != 1))
        .select(
            *KEYS,
            F.col("EVIDENCE_HASH"),
            F.object_construct(
                F.lit("full_name"),
                F.col("FULL_NAME"),
                F.lit("team"),
                F.col("TEAM"),
                F.lit("position"),
                F.col("POSITION"),
                F.lit("jersey"),
                F.col("JERSEY"),
                F.lit("college"),
                F.col("COLLEGE"),
                F.lit("birth_year"),
                F.col("BIRTH_YEAR"),
                F.lit("search_text"),
                F.col("SEARCH_TEXT"),
            ).alias("EVIDENCE"),
            F.col("CANDIDATES"),
            F.when(F.col("N_YES").is_null(), F.lit(REASON_NO_CANDIDATES))
            .when((F.col("N_YES") == 0) & (F.col("N_AI_YES") > 0), F.lit(REASON_NAME_REJECTED))
            .when(F.col("N_YES") == 0, F.lit(REASON_AI_REJECTED))
            .otherwise(F.lit(REASON_AMBIGUOUS))
            .alias("REASON"),
        )
    )

    bridge_rows, bridge_table = _cache(session, det_rows.union_all_by_name(ai_rows), fqn, "DECIDED")
    open_cached, open_table = _cache(session, open_rows, fqn, "OPEN")

    summary["bridged"] = tables.merge_bridge(session, fqn, bridge_table)
    summary["unmatched"] = tables.merge_unmatched(session, fqn, open_table)
    summary["by_method"] = _counts(bridge_rows, "MATCH_METHOD")
    summary["by_reason"] = _counts(open_cached, "REASON")
    summary["search_disagrees"] = bridge_rows.filter(F.col("SEARCH_AGREES") == F.lit(False)).count()
    summary["search_queries"] = n_pending
    summary["ai_pairs"] = n_pairs
    return json.dumps(summary)


def _counts(df: DataFrame, column: str) -> dict[str, int]:
    return {str(r[0]): int(r[1]) for r in df.group_by(column).count().collect()}
