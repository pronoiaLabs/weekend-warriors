{{
    config(
        materialized='table'
    )
}}

/*
    fact_team_game_situation -- situational splits from nflverse play-by-play
    (physical table TEAM_GAME_SITUATION). Grain: team x game x side x
    situation, where the situation is the full combination of the six
    dimensions below. Built from prep regardless of the play-level match
    rate -- prong 2 of the pbp strategy (docs/nfl-core-connection-strategy.html
    section 6): the prop-pattern surface ("this defense collapses on
    third-and-long dropbacks").

    SIDE, NOT COLUMN PAIRS. The doc's field list names each measure once
    ("measures + allowed mirror"), and a team's offensive situations and the
    situations its defense faced are different play sets, so off_/def_ column
    pairs would make almost every row half-NULL. Instead every play lands
    twice: once for posteam with side = 'offense', once for defteam with
    side = 'defense'. A defense row IS the allowed reading -- its epa is EPA
    allowed, its pass_rate the pass rate faced. The unpivot is a UNION ALL,
    so it cannot fan out, and offense rows reconcile 1:1 against the
    opponent's defense rows (tests/nfl/assert_fact_team_game_situation_mirrors).

    game_script is from the ROW's team's perspective, so it flips on the
    defense side: a defense row with game_script = 'leading' means the
    DEFENDING team was ahead. Every other dimension describes the play
    itself and is shared by both rows.

    Base filter mirrors the team twins' EPA fold exactly (play_type in
    (pass, run), non-NULL EPA, a possessing team), so summing plays over a
    team-game-side reproduces off_plays on fact_team_game_offense --
    team_game_key is the same surrogate and joins the twins directly.
    Two-point tries survive the filter with no down; they keep NULL
    down/distance buckets rather than being dropped, so the reconciliation
    holds.

    THE FACT STAYS ADDITIVE. Counts and sums are the contract -- FEATURES /
    APP roll season-to-date and rolling windows from them. The rates beside
    them are this grain's own convenience division and must never be
    re-averaged across rows.
*/

with plays as (

    select
        nflverse_game_id,
        posteam,
        defteam,
        down,
        ydstogo,
        yardline_100,
        score_differential,
        half_seconds_remaining,
        shotgun,
        no_huddle,
        pass,
        rush,
        epa,
        success,
        yards_gained,
        first_down,
        xpass
    from {{ ref('stg_nfl__nflverse_pbp') }}
    where play_type in ('pass', 'run')          -- the twins' EPA fold filter, exactly
      and epa is not null
      and posteam is not null

),

-- ---------------------------------------------------------------------------
-- Unpivot: each play once per side. UNION ALL, so no fan-out is possible.
-- game_script flips with the side; everything else describes the play.
-- ---------------------------------------------------------------------------
sided as (

    select 'offense' as side, posteam as team, defteam as opponent,
           score_differential as team_score_differential, *
    from plays
    union all
    select 'defense' as side, defteam as team, posteam as opponent,
           -score_differential as team_score_differential, *
    from plays

),

situations as (

    select
        nflverse_game_id,
        side,
        team,
        opponent,

        -- situation dimensions. NULL buckets are real (two-point tries have
        -- no down), kept so plays reconcile with the twins' EPA fold.
        case
            when down = 1          then '1st'
            when down = 2          then '2nd'
            when down in (3, 4)    then '3rd_4th'
        end                                             as down_bucket,
        case
            when ydstogo <= 3                  then 'short'
            when ydstogo between 4 and 7       then 'medium'
            when ydstogo >= 8                  then 'long'
        end                                             as distance_bucket,
        case
            when yardline_100 <= 20            then 'red_zone'
            when yardline_100 <= 50            then 'mid'
            else                                    'own'
        end                                             as field_zone,
        case
            when pass = 1                      then 'dropback'
            when rush = 1                      then 'designed_run'
        end                                             as play_family,
        (shotgun = 1)                                   as is_shotgun,
        (no_huddle = 1)                                 as is_no_huddle,
        case
            when team_score_differential > 0   then 'leading'
            when team_score_differential < 0   then 'trailing'
            else                                    'neutral'
        end                                             as game_script,
        (half_seconds_remaining <= 120)                 as is_two_minute,

        -- play-level measures the aggregation folds
        epa,
        success,
        yards_gained,
        first_down,
        pass,
        rush,
        xpass
    from sided

),

aggregated as (

    select
        nflverse_game_id,
        side,
        team,
        opponent,
        down_bucket,
        distance_bucket,
        field_zone,
        play_family,
        is_shotgun,
        is_no_huddle,
        game_script,
        is_two_minute,

        -- additive components: the re-aggregation contract
        count(*)                                        as plays,
        sum(epa)                                        as epa_sum,
        count_if(success = 1)                           as success_plays,
        count_if((pass = 1 and yards_gained >= 20)
              or (rush = 1 and yards_gained >= 10))     as explosive_plays,
        count_if(pass = 1)                              as dropbacks,
        count_if(rush = 1)                              as carries,
        sum(yards_gained)                               as yards_sum,
        count_if(first_down = 1)                        as first_downs,
        sum(iff(xpass is not null, pass - xpass, null)) as pass_over_expected_sum,
        count_if(xpass is not null)                     as xpass_plays,

        -- convenience rates: this grain's own division, never re-average
        sum(epa) / count(*)                             as epa_per_play,
        count_if(success = 1) / count(*)                as success_rate,
        count_if((pass = 1 and yards_gained >= 20)
              or (rush = 1 and yards_gained >= 10))
            / count(*)                                  as explosive_rate,
        count_if(pass = 1) / count(*)                   as pass_rate,
        sum(iff(xpass is not null, pass - xpass, null))
            / nullif(count_if(xpass is not null), 0)    as proe,
        sum(yards_gained) / count(*)                    as yards_per_play,
        count_if(first_down = 1) / count(*)             as first_down_rate

    from situations
    group by all

),

-- ---------------------------------------------------------------------------
-- Bridge to the BDL keys: same pattern as the twins' EPA fold -- the nflverse
-- abbreviation resolves to home or away through bridge_game_ids.
-- ---------------------------------------------------------------------------
bridged as (

    select
        a.* exclude (nflverse_game_id, team, opponent),
        g.game_key,
        g.game_id,
        iff(a.team = g.home_abbr_nflverse, g.home_team_key, g.away_team_key)
                                                        as team_key,
        iff(a.team = g.home_abbr_nflverse, g.home_team_id, g.away_team_id)
                                                        as team_id,
        iff(a.team = g.home_abbr_nflverse, g.away_team_key, g.home_team_key)
                                                        as opponent_team_key,
        iff(a.team = g.home_abbr_nflverse, g.away_team_id, g.home_team_id)
                                                        as opponent_team_id,
        g.season,
        g.week,
        g.season_type,
        g.is_postseason
    from aggregated a
    inner join {{ ref('bridge_game_ids') }} g
        on g.nflverse_game_id = a.nflverse_game_id

)

select
    -- ---------------------------------------------------------------
    -- keys. team_game_key is the twins' surrogate (game_id x team_id),
    -- so a situation row joins its wide team-game row directly.
    -- ---------------------------------------------------------------
    {{ dbt_utils.generate_surrogate_key([
        'game_id', 'team_id', 'side',
        'down_bucket', 'distance_bucket', 'field_zone', 'play_family',
        'is_shotgun', 'is_no_huddle', 'game_script', 'is_two_minute'
    ]) }}                                               as team_game_situation_key,
    {{ dbt_utils.generate_surrogate_key(['game_id', 'team_id']) }}
                                                        as team_game_key,
    game_key,
    game_id,
    team_key,
    team_id,
    opponent_team_key,
    opponent_team_id,

    -- ---------------------------------------------------------------
    -- context
    -- ---------------------------------------------------------------
    season,
    week,
    season_type,
    is_postseason,

    -- ---------------------------------------------------------------
    -- the situation
    -- ---------------------------------------------------------------
    side,
    down_bucket,
    distance_bucket,
    field_zone,
    play_family,
    is_shotgun,
    is_no_huddle,
    game_script,
    is_two_minute,

    -- ---------------------------------------------------------------
    -- measures (see header: components additive, rates convenience)
    -- ---------------------------------------------------------------
    plays,
    epa_sum,
    success_plays,
    explosive_plays,
    dropbacks,
    carries,
    yards_sum,
    first_downs,
    pass_over_expected_sum,
    xpass_plays,

    epa_per_play,
    success_rate,
    explosive_rate,
    pass_rate,
    proe,
    yards_per_play,
    first_down_rate

from bridged
