"""Pure tests for evidence.py: the vocabularies and rules the tiers share."""

import hashlib

import pytest

from player_bridge import evidence as E

# Measured vendor vocabularies (RAW, 2026-08-23). If a vendor starts emitting a
# code outside these, the group map needs the code before the bridge sees it.
BDL_TEAMS = (
    "ARI ATL BAL BUF CAR CHI CIN CLE DAL DEN DET GB HOU IND JAX KC LAC LAR LV MIA MIN "
    "NE NO NYG NYJ PHI PIT SEA SF TB TEN WSH"
).split()
SLEEPER_TEAMS = BDL_TEAMS[:-1] + ["WAS", "OAK"]
BDL_POSITIONS = (
    "C CB DB DE DL DT FB FS G KR LB LCB LS NT OG OL OT P PK QB RB S SS TE WLB WR"
).split()
NFLVERSE_POSITIONS = (
    "C CB DB DE DL DT FB FS G ILB K LB LS MLB NT OL OLB OT P QB RB S SAF TE WR"
).split()
SLEEPER_POSITIONS = (
    "WR DB LB OL TE CB RB DT DL DE QB OT G T K P LS C OG FB SS NT S FS ILB"
).split()


@pytest.mark.parametrize("abbr", BDL_TEAMS + SLEEPER_TEAMS)
def test_every_vendor_team_maps_into_nflverse(abbr):
    assert E.nflverse_team(abbr) in E.NFLVERSE_TEAMS


def test_team_map_is_exact_on_the_known_differences():
    assert E.nflverse_team("LAR") == "LA"
    assert E.nflverse_team("WSH") == "WAS"
    assert E.nflverse_team("OAK") == "LV"
    assert E.nflverse_team(" kc ") == "KC"
    assert E.nflverse_team(None) is None
    assert E.nflverse_team("") is None


@pytest.mark.parametrize("code", BDL_POSITIONS + NFLVERSE_POSITIONS + SLEEPER_POSITIONS)
def test_every_vendor_position_has_a_group(code):
    assert E.position_group(code) in E.POSITION_GROUPS


def test_position_group_unknown_is_none():
    assert E.position_group("UNK") is None
    assert E.position_group(None) is None


def test_groups_are_disjoint():
    seen = {}
    for group, codes in E.POSITION_GROUPS.items():
        for code in codes:
            assert code not in seen, f"{code} in both {seen[code]} and {group}"
            seen[code] = group


@pytest.mark.parametrize(
    "raw, expected",
    [
        ("Ja'Marr Chase", "JAMARR CHASE"),
        ("Odell Beckham Jr.", "ODELL BECKHAM"),
        ("Marvin Harrison Jr", "MARVIN HARRISON"),
        ("Robert Griffin III", "ROBERT GRIFFIN"),
        ("  T.J.   Watt ", "TJ WATT"),
        ("Amon-Ra St. Brown", "AMONRA ST BROWN"),
        ("", None),
        (None, None),
    ],
)
def test_normalize_name_mirrors_the_dbt_macro(raw, expected):
    assert E.normalize_name(raw) == expected


def test_evidence_hash_is_stable_and_field_ordered():
    a = E.evidence_hash(full_name="A. Player", team="LA", position="WR", jersey="1", college="LSU")
    b = E.evidence_hash(college="lsu ", jersey="1", position="wr", team="la", full_name="a. player")
    assert a == b, "case, whitespace and keyword order must not matter"
    expected = hashlib.sha256(b"A. PLAYER|LA|WR|1|LSU").hexdigest()
    assert a == expected


def test_evidence_hash_changes_when_evidence_changes():
    base = dict(full_name="A. Player", team="LA", position="WR", jersey="1", college="LSU")
    moved = E.evidence_hash(**{**base, "team": "KC"})
    assert moved != E.evidence_hash(**base)


def test_evidence_hash_treats_missing_as_empty():
    assert E.evidence_hash(full_name="X") == E.evidence_hash(
        full_name="X", team=None, position=None, jersey=None, college=None
    )


def test_evidence_hash_rejects_unknown_fields():
    with pytest.raises(ValueError):
        E.evidence_hash(full_name="X", age=30)


def test_search_text_keeps_present_parts_in_order():
    assert E.search_text("Puka Nacua", "WR", "LA", "17", "BYU") == "Puka Nacua WR LA #17 BYU"
    assert E.search_text("Puka Nacua", None, "LA", None, "") == "Puka Nacua LA"


def test_search_filter_shapes():
    assert E.search_filter("LA", "WR") == {
        "@or": [{"@eq": {"LATEST_TEAM": "LA"}}, {"@eq": {"POS_GROUP": "WR"}}]
    }
    assert E.search_filter("LA", None) == {"@eq": {"LATEST_TEAM": "LA"}}
    assert E.search_filter(None, "WR") == {"@eq": {"POS_GROUP": "WR"}}
    assert E.search_filter(None, None) is None


@pytest.mark.parametrize(
    "a, b, expected",
    [
        ("PAT", "PATRICK", True),  # prefix
        ("MIKE", "MICHAEL", True),  # nickname table
        ("NICK", "NICHOLAS", True),  # nickname table
        ("DRU", "ANDRU", True),  # containment
        ("VINNY", "VINCENT", True),  # nickname table
        ("STEVE", "STEPHEN", True),  # nickname table
        ("KENNY", "KENDRICK", False),  # the Britt/Mosley failure: must stay out
        ("RASHOD", "TINKER", False),  # the Owens failure: must stay out
        ("TROY", "MONDOE", False),
        ("T", "MARCUS", False),  # a bare initial is not evidence
        ("AL", "ABRAHAM", False),
        (None, "MIKE", False),
    ],
)
def test_first_names_compatible(a, b, expected):
    assert E.first_names_compatible(a, b) is expected
    assert E.first_names_compatible(b, a) is expected


def test_nickname_pairs_are_sorted_tuples():
    for pair in E.NICKNAME_PAIRS:
        assert pair == tuple(sorted(pair))


def test_surname_key_folds_spaces_after_the_first_token():
    assert E.surname_key("KAENA DE CAMBRA") == "DECAMBRA"
    assert E.surname_key("KAENA DECAMBRA") == "DECAMBRA"
    assert E.surname_key("AMONRA ST BROWN") == "STBROWN"
    assert E.surname_key("MADONNA") == "MADONNA"  # single token: the whole name
    assert E.surname_key(None) is None


@pytest.mark.parametrize(
    "a, b, expected",
    [
        ("DECAMBRA", "DECAMBRA", True),
        ("MARTINRHODES", "MARTIN", True),  # hyphenated double vs short form
        ("OWENS", "OWE", False),  # short prefix is not enough
        ("SMITH", "SMYTHE", False),
        (None, "SMITH", False),
    ],
)
def test_surnames_compatible(a, b, expected):
    assert E.surnames_compatible(a, b) is expected
    assert E.surnames_compatible(b, a) is expected


def test_render_reads_like_a_record():
    assert E.render("Puka Nacua", "WR", "LA", "17", "BYU", 2001) == (
        "Puka Nacua, WR, LA, #17, BYU, born 2001"
    )
    assert E.render(None, None, None, None, None, None) == "unknown name"
