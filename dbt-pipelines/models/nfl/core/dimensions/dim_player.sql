{{
    config(
        materialized='table'
    )
}}

/*
    dim_player -- player biographical attributes. Grain: player. SCD1.

    NO TEAM COLUMN, deliberately. The source holds only each player's current
    team, so putting it here would let a 2023 query return a player's 2025 team
    and look correct. Per-game team affiliation lives on the fact tables via
    team_key, which is accurate as loaded.

    BDL coverage is thin and worth knowing before building anything on top:
    13,503 players, 8,379 with position 'Unknown', 9,715 without measurements,
    no birth date, no draft info, no headshot. That is the problem the vendor
    enrichment below solves: bridge_player_ids ties each player to nflverse
    (gsis_id spine: bio, draft, the id crosswalk) and Sleeper (live status).

    Position is REPAIRED, with provenance. position_abbreviation is BDL's when
    BDL knows it, else nflverse's, else Sleeper's; position_source says which
    vendor supplied it (NULL when nobody knows). position_name / position_group
    / has_known_position all derive from the repaired value, and the name map
    deliberately folds vendor codes onto the existing labels (SAF/FS/SS ->
    'Safety', K -> 'Place Kicker') so the enum Cortex filters on never splits.
    Height and weight are backfilled from nflverse where BDL is null -- the
    only other sanctioned coalesce; every other vendor column lands under its
    own name.

    The Sleeper block is SERVING-ONLY current state: the daily dump is
    replaced each day, so injury_status, practice_participation and the depth
    chart columns are "as of the last load", not history. The filed reports
    live on fact_injury_report and chart history on fact_depth_chart.

    NULL on an enrichment column means "no match" (see has_nflverse_match /
    has_sleeper_match), never zero.
*/

with players as (

    select * from {{ ref('stg_nfl__players') }}

),

-- one bridge row per player_key. The bridge's grain is gsis_id and it already
-- collapses duplicate vendor ids per gsis; this qualify is the mirror-image
-- guard so a duplicate BDL id (two ids, one man: Testaverde) can never fan
-- this dimension out.
bridge as (

    select
        player_key,
        gsis_id,
        sleeper_player_id
    from {{ ref('bridge_player_ids') }}
    where player_key is not null
    qualify row_number() over (
        partition by player_key
        order by gsis_id
    ) = 1

),

nflverse as (

    select * from {{ ref('stg_nfl__nflverse_players') }}

),

sleeper as (

    select * from {{ ref('stg_nfl__sleeper_players') }}

)

select
    p.player_key,
    p.player_id,

    -- identity
    p.full_name,
    p.first_name,
    p.last_name,
    p.jersey_number,

    -- Position, repaired across vendors with provenance.
    --
    -- BDL's abbreviation is authoritative when it is not 'UNK'; nflverse then
    -- Sleeper fill the blanks. position_source records who supplied the value
    -- so a disagreement is auditable rather than silent -- it is NULL only
    -- when no vendor knows the position, in which case the abbreviation stays
    -- 'UNK' (explicit dimension member, the Kimball convention, so inner
    -- joins keep the row).
    coalesce(
        iff(p.position_abbreviation <> 'UNK', p.position_abbreviation, null),
        upper(trim(n.position)),
        upper(trim(s.position)),
        'UNK'
    )                               as position_abbreviation,
    case
        when p.position_abbreviation <> 'UNK' then 'balldontlie'
        when n.position is not null           then 'nflverse'
        when s.position is not null           then 'sleeper'
    end                             as position_source,

    -- position_name is DERIVED FROM THE (repaired) ABBREVIATION, not passed
    -- through: BDL's own label text splits enums ('Place kicker' vs 'Place
    -- Kicker'), and Cortex Analyst filters on literal values, so one clean
    -- label per position is the contract. Vendor-only codes fold onto the
    -- existing labels rather than minting near-duplicates.
    case coalesce(
        iff(p.position_abbreviation <> 'UNK', p.position_abbreviation, null),
        upper(trim(n.position)),
        upper(trim(s.position)),
        'UNK'
    )
        when 'QB'  then 'Quarterback'
        when 'RB'  then 'Running Back'
        when 'HB'  then 'Running Back'
        when 'FB'  then 'Fullback'
        when 'WR'  then 'Wide Receiver'
        when 'TE'  then 'Tight End'
        when 'C'   then 'Center'
        when 'G'   then 'Guard'
        when 'OG'  then 'Offensive Guard'
        when 'OT'  then 'Offensive Tackle'
        when 'T'   then 'Offensive Tackle'
        when 'OL'  then 'Offensive Lineman'
        when 'DE'  then 'Defensive End'
        when 'EDGE' then 'Defensive End'
        when 'DT'  then 'Defensive Tackle'
        when 'DL'  then 'Defensive Lineman'
        when 'NT'  then 'Nose Tackle'
        when 'LB'  then 'Linebacker'
        when 'ILB' then 'Linebacker'
        when 'MLB' then 'Linebacker'
        when 'OLB' then 'Linebacker'
        when 'WLB' then 'Weakside Linebacker'
        when 'CB'  then 'Cornerback'
        when 'LCB' then 'Left Cornerback'
        when 'S'   then 'Safety'
        when 'SAF' then 'Safety'
        when 'FS'  then 'Safety'
        when 'SS'  then 'Safety'
        when 'DB'  then 'Defensive Back'
        when 'PK'  then 'Place Kicker'
        when 'K'   then 'Place Kicker'
        when 'P'   then 'Punter'
        when 'LS'  then 'Long Snapper'
        when 'KR'  then 'Kick Returner'
        else 'Unknown'
    end                             as position_name,
    case coalesce(
        iff(p.position_abbreviation <> 'UNK', p.position_abbreviation, null),
        upper(trim(n.position)),
        upper(trim(s.position)),
        'UNK'
    )
        when 'QB'  then 'Offense - Skill'
        when 'RB'  then 'Offense - Skill'
        when 'HB'  then 'Offense - Skill'
        when 'FB'  then 'Offense - Skill'
        when 'WR'  then 'Offense - Skill'
        when 'TE'  then 'Offense - Skill'
        when 'C'   then 'Offense - Line'
        when 'G'   then 'Offense - Line'
        when 'OG'  then 'Offense - Line'
        when 'OT'  then 'Offense - Line'
        when 'T'   then 'Offense - Line'
        when 'OL'  then 'Offense - Line'
        when 'DE'  then 'Defense - Line'
        when 'EDGE' then 'Defense - Line'
        when 'DT'  then 'Defense - Line'
        when 'DL'  then 'Defense - Line'
        when 'NT'  then 'Defense - Line'
        when 'LB'  then 'Defense - Linebacker'
        when 'ILB' then 'Defense - Linebacker'
        when 'MLB' then 'Defense - Linebacker'
        when 'OLB' then 'Defense - Linebacker'
        when 'WLB' then 'Defense - Linebacker'
        when 'CB'  then 'Defense - Secondary'
        when 'LCB' then 'Defense - Secondary'
        when 'S'   then 'Defense - Secondary'
        when 'SAF' then 'Defense - Secondary'
        when 'FS'  then 'Defense - Secondary'
        when 'SS'  then 'Defense - Secondary'
        when 'DB'  then 'Defense - Secondary'
        when 'PK'  then 'Special Teams'
        when 'K'   then 'Special Teams'
        when 'P'   then 'Special Teams'
        when 'LS'  then 'Special Teams'
        when 'KR'  then 'Special Teams'
        else 'Unknown'
    end                             as position_group,
    -- reads off the REPAIRED position: a player nflverse identified is known
    (p.position_abbreviation <> 'UNK'
        or n.position is not null
        or s.position is not null)  as has_known_position,

    -- physical. BDL first, backfilled from nflverse where BDL never measured
    -- the player (9,715 rows) -- the doc-sanctioned coalesce besides position.
    coalesce(p.height_inches, n.height_inches)  as height_inches,
    coalesce(p.weight_lbs, n.weight_lbs)        as weight_lbs,
    p.age,
    p.seasons_experience,
    (p.seasons_experience = 1)      as is_rookie,

    -- background
    p.college,

    -- + nflverse: bio & draft (NULL = no bridge match, never a default)
    n.birth_date,
    n.draft_year,
    n.draft_round,
    n.draft_pick,
    n.draft_team,
    n.college_name,
    n.college_conference,
    n.rookie_season,
    n.last_season,
    n.years_of_experience,
    n.headshot_url,

    -- + nflverse: the vendor's own position read, kept under its own names
    -- so the repair above stays auditable
    n.position                      as nflverse_position,
    n.ngs_position,
    n.pff_position,
    n.status                        as nflverse_status,

    -- denormalized ids; bridge_player_ids stays authoritative
    b.gsis_id,
    n.esb_id,
    n.espn_id,
    n.pfr_id,
    n.pff_id,
    n.otc_id,
    b.sleeper_player_id,
    s.sportradar_id,
    s.yahoo_id,
    s.rotowire_id,
    s.kalshi_id,
    s.oddsjam_id,

    -- + Sleeper: live status. CURRENT STATE ONLY -- the dump is replaced
    -- daily, so these serve "as of now" reads; history lives on
    -- fact_injury_report and fact_depth_chart.
    s.injury_status,
    s.injury_body_part,
    s.injury_notes,
    s.practice_participation,
    s.practice_description,
    s.news_updated_at,
    s.depth_chart_position,
    s.depth_chart_order,
    s.search_rank,
    s.is_active,
    s.high_school,

    -- match flags: NULL above means "no match", these say so explicitly
    (n.gsis_id is not null)             as has_nflverse_match,
    (s.sleeper_player_id is not null)   as has_sleeper_match

from players p
left join bridge b
    on b.player_key = p.player_key
left join nflverse n
    on n.gsis_id = b.gsis_id
left join sleeper s
    on s.sleeper_player_id = b.sleeper_player_id
