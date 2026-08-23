"""AI confirmation of the residual: one verdict per (vendor row, candidate) pair.

Two verdicts per pair, and a row is decided only when both say yes:

  AI_SAME  AI_FILTER(PROMPT(...)) over both records rendered as text.
  NAME_OK  a deterministic gate built from evidence.py's rules: compatible
           surnames (space-stripped remainder, prefix-tolerant for hyphenated
           doubles) and compatible first names (equal, prefix, contained, or
           a known nickname pair).

Why both. Measured on the first full refresh (2026-08-23), the model alone
said yes to same-surname strangers (Rashod Owens -> Tinker Owens, Kenny
Britt -> Kendrick Mosley), which also produced most of the "ambiguous" rows.
Measured on the second, a naive prefix-only gate blocked 91 true matches
(Mike/Michael Reid, Nick/Nicholas Schommer, De Cambra/Decambra, Dru/Andru
Phillips), hence the nickname table, containment and surname folding. The
gate costs nothing; the model still decides stale teams, jersey changes and
everything else within a compatible name.

AI_FILTER(PROMPT(...)) as a column rather than DataFrame.ai.filter: the
verdicts are data (stored in the unmatched ledger's CANDIDATES so a human
can see why a row stayed open), and a filter would only keep the yes rows.
Called through call_function so the procedure does not depend on which
Snowpark release added the Python wrappers.
"""

from __future__ import annotations

from snowflake.snowpark import Column, DataFrame
from snowflake.snowpark import functions as F

from player_bridge.evidence import NICKNAME_PAIRS

PROMPT = (
    "Two records from different NFL data providers are below. Answer true only if they "
    "describe the same person. The surname must be the same; a first name may be a nickname "
    "or abbreviation of the other (Pat and Patrick) but a different first name means a "
    "different person. A team may be stale after a trade or release. Jersey numbers change "
    "between seasons, so a different number alone is not disqualifying; colleges and birth "
    "years, when both present, are strong evidence. Record A: {0}. Record B: {1}."
)


def _first(name: Column) -> Column:
    return F.regexp_substr(name, F.lit(r"^\S+"))


def _surname_key(name: Column) -> Column:
    """evidence.surname_key in SQL: rest after the first token, spaces removed."""
    rest = F.regexp_replace(name, F.lit(r"^\S+\s*"), F.lit(""))
    return F.iff(
        F.coalesce(rest, F.lit("")) == F.lit(""), name, F.replace(rest, F.lit(" "), F.lit(""))
    )


def _first_names_compatible(a: Column, b: Column) -> Column:
    """evidence.first_names_compatible in SQL."""
    short_len = F.least(F.length(a), F.length(b))
    prefixish = ((a == b) | F.startswith(a, b) | F.startswith(b, a)) & (short_len >= 2)
    contained = (short_len >= 3) & (F.contains(a, b) | F.contains(b, a))
    pair = F.concat(F.least(a, b), F.lit("|"), F.greatest(a, b))
    nicknames = pair.isin([f"{x}|{y}" for x, y in sorted(NICKNAME_PAIRS)])
    return prefixish | contained | nicknames


def _surnames_compatible(a: Column, b: Column) -> Column:
    """evidence.surnames_compatible in SQL."""
    short_len = F.least(F.length(a), F.length(b))
    return (a == b) | ((short_len >= 4) & (F.startswith(a, b) | F.startswith(b, a)))


def confirm(pairs: DataFrame) -> DataFrame:
    """Add AI_SAME, NAME_OK and IS_SAME to pairs.

    pairs carries A_TEXT / B_TEXT (the rendered records) and A_NAME_NORM /
    B_NAME_NORM (the normalized names, vendor side and index side).
    """
    ai_same = F.coalesce(
        F.call_function(
            "AI_FILTER",
            F.call_function("PROMPT", F.lit(PROMPT), F.col("A_TEXT"), F.col("B_TEXT")),
        ),
        F.lit(False),
    )
    a, b = F.col("A_NAME_NORM"), F.col("B_NAME_NORM")
    name_ok = F.coalesce(
        _surnames_compatible(_surname_key(a), _surname_key(b))
        & _first_names_compatible(_first(a), _first(b)),
        F.lit(False),
    )
    return pairs.with_columns(
        ["AI_SAME", "NAME_OK", "IS_SAME"],
        [ai_same, name_ok, ai_same & name_ok],
    )
