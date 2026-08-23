"""Pure helpers: the vocabularies and rules every tier agrees on.

WHY a pure module: the matching runs as pushdown SQL (expressions.py builds
the Snowpark columns from these tables), but the rules themselves are data
and need unit tests that run without a session. The dbt side mirrors two of
them (macros/nfl/nfl_helpers.sql: nfl_team_abbr_nflverse, nfl_position_group)
and the search service mirrors POSITION_GROUPS in
dlt-pipelines/sql/sources/nfl/09_player_bridge.sql. Change one, change all.

Everything here was measured against RAW on 2026-08-23: the three vendors
agree on 29 of 32 abbreviations (LA/LAR, WAS/WSH differ; Sleeper still carries
OAK on a few rows), and the position vocabularies overlap only at the group
level (BDL says LCB and WLB, nflverse says SAF and MLB, Sleeper says DB and OL).
"""

from __future__ import annotations

import hashlib
import re

# Vendor abbreviation -> nflverse abbreviation. Anything not listed passes
# through unchanged. Legacy codes (OAK, SD, STL) fold onto the current club.
TO_NFLVERSE_TEAM: dict[str, str] = {
    "LAR": "LA",
    "WSH": "WAS",
    "OAK": "LV",
    "SD": "LAC",
    "STL": "LA",
}

NFLVERSE_TEAMS: frozenset[str] = frozenset(
    "ARI ATL BAL BUF CAR CHI CIN CLE DAL DEN DET GB HOU IND JAX KC LA LAC LV MIA MIN "
    "NE NO NYG NYJ PHI PIT SEA SF TB TEN WAS".split()
)

# Position group -> the position codes any vendor uses for it.
POSITION_GROUPS: dict[str, tuple[str, ...]] = {
    "QB": ("QB",),
    "RB": ("RB", "FB", "HB"),
    "WR": ("WR",),
    "TE": ("TE",),
    "OL": ("OL", "OT", "T", "G", "OG", "C"),
    "DL": ("DL", "DE", "DT", "NT", "EDGE"),
    "LB": ("LB", "ILB", "OLB", "MLB", "WLB", "SLB"),
    "DB": ("DB", "CB", "S", "SS", "FS", "SAF", "LCB", "RCB"),
    "SPEC": ("K", "PK", "P", "LS", "KR", "PR"),
}

POSITION_TO_GROUP: dict[str, str] = {
    code: group for group, codes in POSITION_GROUPS.items() for code in codes
}

# The columns whose values decide whether an unmatched player is retried:
# when any of them changes on the vendor's side, the hash changes and the
# procedure tries again. Order matters (it is the hash input order).
EVIDENCE_FIELDS: tuple[str, ...] = ("full_name", "team", "position", "jersey", "college")

# Mirror of macros/nfl/nfl_helpers.sql::nfl_normalize_player_name, in order:
# upper, strip a generational suffix, drop non-alphanumerics, collapse spaces.
_SUFFIX = re.compile(r"\s+(JR\.?|SR\.?|II|III|IV)$")
_NON_ALNUM = re.compile(r"[^A-Z0-9 ]")
_SPACES = re.compile(r"\s+")


def nflverse_team(abbr: str | None) -> str | None:
    """Map a vendor abbreviation onto nflverse's; None stays None."""
    if abbr is None:
        return None
    code = abbr.strip().upper()
    if not code:
        return None
    return TO_NFLVERSE_TEAM.get(code, code)


def position_group(position: str | None) -> str | None:
    """Collapse a vendor position code to its group, or None if unknown."""
    if position is None:
        return None
    return POSITION_TO_GROUP.get(position.strip().upper())


def normalize_name(name: str | None) -> str | None:
    """Fold a player name into the comparable key the dbt macro produces."""
    if name is None:
        return None
    out = _SUFFIX.sub("", name.upper())
    out = _NON_ALNUM.sub("", out)
    out = _SPACES.sub(" ", out).strip()
    return out or None


def _clean(value: object) -> str:
    """The per-field normalization the hash uses: upper(trim()), NULL -> ''."""
    if value is None:
        return ""
    text = str(value).strip().upper()
    return text


def evidence_hash(**fields: object) -> str:
    """SHA-256 over the EVIDENCE_FIELDS values, '|'-joined after _clean().

    Mirrors expressions.evidence_hash_col exactly (sha2(concat_ws('|', ...), 256)
    over coalesce(upper(trim(x)), '')), so a Python-side expectation and the
    SQL-side value agree byte for byte.
    """
    unknown = set(fields) - set(EVIDENCE_FIELDS)
    if unknown:
        raise ValueError(f"unknown evidence fields: {sorted(unknown)}")
    joined = "|".join(_clean(fields.get(name)) for name in EVIDENCE_FIELDS)
    return hashlib.sha256(joined.encode("utf-8")).hexdigest()


def search_text(
    full_name: str | None,
    position: str | None,
    team: str | None,
    jersey: str | None,
    college: str | None,
) -> str:
    """The query string sent to the search service: present parts, space-joined.

    Same shape as the service's indexed SEARCH_TEXT (name, position, team,
    '#jersey', college) so keyword hits line up.
    """
    parts = [full_name, position, team, f"#{jersey}" if jersey else None, college]
    return " ".join(p.strip() for p in parts if p and p.strip())


def search_filter(team: str | None, pos_group: str | None) -> dict | None:
    """Per-row Cortex Search filter: same team OR same position group.

    OR rather than AND because a traded or released player's vendor team is
    stale until that vendor's next dump, and the position group survives a
    trade. Either attribute missing narrows to the other; both missing means
    no filter (the hybrid search still ranks by name).
    """
    clauses = []
    if team:
        clauses.append({"@eq": {"LATEST_TEAM": team}})
    if pos_group:
        clauses.append({"@eq": {"POS_GROUP": pos_group}})
    if not clauses:
        return None
    if len(clauses) == 1:
        return clauses[0]
    return {"@or": clauses}


# Nickname pairs the prefix rule cannot see (MIKE is not a prefix of MICHAEL).
# Stored as sorted tuples; first_names_compatible checks both orders. Names the
# prefix or containment rules already cover (DAN/DANIEL, VINCE/VINCENT,
# DRU/ANDRU) are deliberately absent.
NICKNAME_PAIRS: frozenset[tuple[str, str]] = frozenset(
    tuple(sorted(pair))
    for pair in [
        ("MIKE", "MICHAEL"),
        ("NICK", "NICHOLAS"),
        ("BILL", "WILLIAM"),
        ("BILLY", "WILLIAM"),
        ("BOB", "ROBERT"),
        ("BOBBY", "ROBERT"),
        ("ROB", "ROBERT"),
        ("DAVE", "DAVID"),
        ("JIM", "JAMES"),
        ("JIMMY", "JAMES"),
        ("TONY", "ANTHONY"),
        ("ABE", "ABRAHAM"),
        ("GABE", "GABRIEL"),
        ("TOM", "THOMAS"),
        ("TOMMY", "THOMAS"),
        ("TED", "THEODORE"),
        ("ANDY", "ANDREW"),
        ("DREW", "ANDREW"),
        ("JAKE", "JACOB"),
        ("NATE", "NATHAN"),
        ("NATE", "NATHANIEL"),
        ("VINNY", "VINCENT"),
        ("KENNY", "KENNETH"),
        ("JOE", "JOSEPH"),
        ("JOEY", "JOSEPH"),
        ("STEVE", "STEPHEN"),
        ("RICK", "RICHARD"),
        ("RICKY", "RICHARD"),
        ("DICK", "RICHARD"),
        ("EDDIE", "EDWARD"),
        ("CHUCK", "CHARLES"),
        ("CHARLIE", "CHARLES"),
        ("LARRY", "LAWRENCE"),
        ("TERRY", "TERRENCE"),
        ("JERRY", "GERALD"),
        ("HANK", "HENRY"),
        ("FREDDIE", "FREDERICK"),
        ("RONNIE", "RONALD"),
        ("DONNIE", "DONALD"),
        ("ZAK", "ZACHARY"),
        ("JEFF", "JEFFREY"),
        ("GREG", "GREGORY"),
    ]
)


def first_names_compatible(a: str | None, b: str | None) -> bool:
    """Could these be the same first name? Equal, prefix, contained, or nickname.

    Containment (DRU in ANDRU) needs the shorter side to be at least 3
    characters so a stray initial cannot match everything. A bare initial
    against a full name is NOT accepted: one letter is not evidence.
    """
    if not a or not b:
        return False
    a, b = a.upper(), b.upper()
    if a == b or a.startswith(b) or b.startswith(a):
        # A single letter passing as a "prefix" of anything is too weak.
        return min(len(a), len(b)) >= 2
    short, long_ = (a, b) if len(a) <= len(b) else (b, a)
    if len(short) >= 3 and short in long_:
        return True
    return tuple(sorted((a, b))) in NICKNAME_PAIRS


def surname_key(name_norm: str | None) -> str | None:
    """Everything after the first token, spaces removed: DE CAMBRA -> DECAMBRA.

    Compared with prefix tolerance (shorter side at least 4 characters) so a
    hyphenated double surname still matches its shorter form after
    normalization folds the hyphen away (MARTINRHODES vs MARTIN).
    """
    if not name_norm:
        return None
    parts = name_norm.split(" ")
    if len(parts) < 2:
        return name_norm
    return "".join(parts[1:]) or None


def surnames_compatible(a_key: str | None, b_key: str | None) -> bool:
    if not a_key or not b_key:
        return False
    if a_key == b_key:
        return True
    short = min(len(a_key), len(b_key))
    return short >= 4 and (a_key.startswith(b_key) or b_key.startswith(a_key))


def render(
    full_name: str | None,
    position: str | None,
    team: str | None,
    jersey: str | None,
    college: str | None,
    birth_year: int | None,
) -> str:
    """One record as the AI confirmation prompt sees it."""
    parts = [
        full_name or "unknown name",
        position,
        team,
        f"#{jersey}" if jersey else None,
        college,
        f"born {birth_year}" if birth_year else None,
    ]
    return ", ".join(p for p in parts if p)
