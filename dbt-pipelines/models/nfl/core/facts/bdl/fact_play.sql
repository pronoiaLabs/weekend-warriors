{{
    config(
        materialized='table',
        cluster_by=['season', 'week']
    )
}}

/*
    fact_play -- play-by-play (physical table PLAY_LOG). Grain: play. ~182k rows.

    BallDontLie is the spine; where a play can be located in nflverse
    play-by-play, that row's analytics ride along (epa, wpa, success, the
    passing-model outputs) plus the nflverse play id for drill-through into
    everything else the 372-column pbp file carries. Formerly the project's
    template incremental model; converted to a plain table when the graft
    landed -- the whole table is recomputed because a match can improve
    retroactively (a late pbp backfill). The merge-on-watermark pattern lives
    on in fact_ncaaf_player_game.

    THE MATCH CASCADE (measured; docs/nfl-enrichment-columns.html has the
    trial queries and per-tier counts). A play is matchable when its type is
    non-administrative (dim_play_type.is_matchable), its game is
    bridge-observed in nflverse pbp, and it is not preseason -- is_matchable
    on the row records that verdict. Matchable plays then match in tiers,
    first match wins, each tier one-to-one in BOTH directions (an nflverse
    play is consumed by at most one BDL play; ambiguity resolves by nearest
    clock then play_id):

      T1  exact on game + quarter + clock + down + distance + yardline (74.6%)
      T2  clock tolerance +/-15s for entry drift, yardline kept   (cum. 85.2%)
      T3  yardline dropped, +/-15s, and the play-FAMILY must agree: the
          nflverse row's called play_type must be one dim_play_type's
          nflverse mapping allows for the BDL type            (cum. ~99.7%)

    match_tier says which tier landed the match; NULL means unmatched (the
    ~0.3% residual) or not matchable at all. Unmatched plays keep NULL
    analytics -- never imputed.

    Asymmetries the match documents rather than hides (see dim_play_type):
      * XP kicks exist only on the nflverse side (BDL omits PATs) -- by
        design never matched; XP stats arrive via fact_player_game_special.
      * kneels and spikes are distinct nflverse types buried inside BDL's
        Rush and Pass Incompletion; the T3 family check admits them.
      * ~27k BDL administrative rows and all preseason games sit outside the
        match denominator (is_matchable = false).

    fact_play_match_audit aggregates the outcome per game and
    tests/nfl/assert_play_match_rate_above_floor watches the rate.

    Two source characteristics carried through deliberately:
      * team_key is NULLABLE -- 126 plays are neutral events (kickoffs and the
        like) with no possessing team. The dimension join must tolerate it.
      * 18 games have no plays, so this fact does NOT cover all games.
        Do not use it as a game spine.

    Clustered on (season, week) since essentially every query filters by them.
    play_description holds the natural-language text and is the obvious candidate
    for a Cortex Search service later ("find plays where X happened").
*/

with plays as (

    select * from {{ ref('stg_nfl__plays') }}

),

games as (

    select
        game_key,
        date_key,
        season_week_key,
        season,
        week,
        season_type,
        is_postseason,
        home_team_key,
        away_team_key
    from {{ ref('dim_game') }}

),

-- ---------------------------------------------------------------------------
-- Match scaffolding: the bridge scopes each play to its nflverse game, the
-- play-type dimension supplies matchability and the called-play mapping.
-- ---------------------------------------------------------------------------
bridge as (

    select
        game_key,
        nflverse_game_id
    from {{ ref('bridge_game_ids') }}
    where nflverse_game_id is not null
      and is_nflverse_observed

),

play_types as (

    select
        play_type_key,
        nflverse_play_type,
        is_matchable
    from {{ ref('dim_play_type') }}

),

matchable as (

    select
        p.play_key,
        br.nflverse_game_id,
        p.period,
        p.clock_seconds_remaining,
        p.start_down,
        p.start_distance,
        p.start_yards_to_endzone,
        pt.nflverse_play_type                           as expected_play_type
    from plays p
    inner join games g
        on g.game_key = p.game_key
    inner join bridge br
        on br.game_key = p.game_key
    inner join play_types pt
        on pt.play_type_key = p.play_type_key
    where g.season_type != 1                            -- nflverse has no preseason pbp
      and pt.is_matchable

),

nflverse_plays as (

    select
        nflverse_game_id,
        play_id,
        qtr,
        quarter_seconds_remaining,
        down,
        ydstogo,
        yardline_100,
        play_type,
        epa,
        wpa,
        success,
        cpoe,
        cp,
        xpass,
        pass_oe,
        air_yards,
        yards_after_catch,
        qb_epa
    from {{ ref('stg_nfl__nflverse_pbp') }}
    -- clock/bookkeeping rows that are not plays on the BDL side either
    where play_type_nfl not in ('END_QUARTER', 'END_GAME', 'GAME_START', 'COMMENT', 'TIMEOUT')

),

-- ---------------------------------------------------------------------------
-- The cascade. Each tier: candidate pairs by predicate, then a mutual
-- first-choice qualify -- a pair survives only when each side is the other's
-- best candidate (nearest clock, then play_id / play_key as the deterministic
-- tiebreak). Later tiers exclude both sides of every earlier match, so a
-- play matches at most once and an nflverse row is never consumed twice.
-- ---------------------------------------------------------------------------
t1 as (

    select
        b.play_key,
        n.nflverse_game_id,
        n.play_id
    from matchable b
    inner join nflverse_plays n
        on  n.nflverse_game_id = b.nflverse_game_id
        and n.qtr = b.period
        and n.quarter_seconds_remaining = b.clock_seconds_remaining
        and coalesce(n.down, 0)          = coalesce(b.start_down, 0)
        and coalesce(n.ydstogo, 0)       = coalesce(b.start_distance, 0)
        and coalesce(n.yardline_100, -1) = coalesce(b.start_yards_to_endzone, -1)
    qualify row_number() over (partition by b.play_key order by n.play_id) = 1
        and row_number() over (partition by n.nflverse_game_id, n.play_id order by b.play_key) = 1

),

t2 as (

    select
        b.play_key,
        n.nflverse_game_id,
        n.play_id
    from matchable b
    inner join nflverse_plays n
        on  n.nflverse_game_id = b.nflverse_game_id
        and n.qtr = b.period
        and abs(coalesce(n.quarter_seconds_remaining, -999)
              - coalesce(b.clock_seconds_remaining, -999)) <= 15
        and coalesce(n.down, 0)          = coalesce(b.start_down, 0)
        and coalesce(n.ydstogo, 0)       = coalesce(b.start_distance, 0)
        and coalesce(n.yardline_100, -1) = coalesce(b.start_yards_to_endzone, -1)
    where b.play_key not in (select play_key from t1)
      and (n.nflverse_game_id, n.play_id) not in (
              select nflverse_game_id, play_id from t1
          )
    qualify row_number() over (
                partition by b.play_key
                order by abs(n.quarter_seconds_remaining - b.clock_seconds_remaining), n.play_id
            ) = 1
        and row_number() over (
                partition by n.nflverse_game_id, n.play_id
                order by abs(n.quarter_seconds_remaining - b.clock_seconds_remaining), b.play_key
            ) = 1

),

t3 as (

    select
        b.play_key,
        n.nflverse_game_id,
        n.play_id
    from matchable b
    inner join nflverse_plays n
        on  n.nflverse_game_id = b.nflverse_game_id
        and n.qtr = b.period
        and abs(coalesce(n.quarter_seconds_remaining, -999)
              - coalesce(b.clock_seconds_remaining, -999)) <= 15
        and coalesce(n.down, 0)    = coalesce(b.start_down, 0)
        and coalesce(n.ydstogo, 0) = coalesce(b.start_distance, 0)
        -- yardline dropped, so the play FAMILY must agree: the nflverse
        -- called play must be one the BDL type's mapping allows
        -- ('run or qb_kneel' admits both run and qb_kneel, and so on)
        and array_contains(n.play_type::variant, split(b.expected_play_type, ' or '))
    where b.play_key not in (
              select play_key from t1
              union all
              select play_key from t2
          )
      and (n.nflverse_game_id, n.play_id) not in (
              select nflverse_game_id, play_id from t1
              union all
              select nflverse_game_id, play_id from t2
          )
    qualify row_number() over (
                partition by b.play_key
                order by abs(n.quarter_seconds_remaining - b.clock_seconds_remaining), n.play_id
            ) = 1
        and row_number() over (
                partition by n.nflverse_game_id, n.play_id
                order by abs(n.quarter_seconds_remaining - b.clock_seconds_remaining), b.play_key
            ) = 1

),

matched as (

    select play_key, nflverse_game_id, play_id, 'T1' as match_tier from t1
    union all
    select play_key, nflverse_game_id, play_id, 'T2' as match_tier from t2
    union all
    select play_key, nflverse_game_id, play_id, 'T3' as match_tier from t3

)

select
    -- ---------------------------------------------------------------
    -- keys
    -- ---------------------------------------------------------------
    p.play_key,
    p.play_id,
    p.game_key,
    p.game_id,

    -- nullable: neutral-event plays have no possessing team
    p.team_key,
    p.team_id,

    p.play_type_key,
    g.date_key,
    g.season_week_key,

    -- ---------------------------------------------------------------
    -- context
    -- ---------------------------------------------------------------
    g.season,
    g.week,
    g.season_type,
    g.is_postseason,

    -- which side had the ball, useful without joining back to the game
    case
        when p.team_key = g.home_team_key then true
        when p.team_key = g.away_team_key then false
    end                                             as is_home_possession,

    -- ---------------------------------------------------------------
    -- situation
    -- ---------------------------------------------------------------
    p.period,
    p.clock_display,
    p.clock_seconds_remaining,
    p.start_down,
    p.start_distance,
    p.start_yard_line,
    p.start_yards_to_endzone,

    p.end_down,
    p.end_distance,
    p.end_yard_line,
    p.end_yards_to_endzone,
    p.end_down_distance_text,
    p.end_possession_text,

    p.is_third_down,
    p.is_fourth_down,
    p.is_red_zone,

    -- ---------------------------------------------------------------
    -- outcome
    -- ---------------------------------------------------------------
    p.yards_gained,
    p.is_scoring_play,
    p.home_score_after_play,
    p.away_score_after_play,
    p.home_win_probability,

    -- derived: did this play gain enough for a first down.
    --
    -- The down guard is load-bearing. Kickoffs and clock events carry
    -- start_down = 0 and start_distance = 0, so a guard that only checks for
    -- NULLs lets `0 >= 0` through and flags them as first downs -- 1,612 of
    -- them, including every "End of Game" play in the table. Requiring a live
    -- down (1-4) and a real distance to gain restricts this to scrimmage plays.
    --
    -- NULL rather than false when the situation is unknown, so an unmeasurable
    -- play is not silently counted as a failed conversion.
    case
        when p.start_down between 1 and 4
         and p.start_distance > 0
         and p.yards_gained is not null
        then p.yards_gained >= p.start_distance
    end                                             as achieved_first_down,

    -- ---------------------------------------------------------------
    -- description (Cortex Search candidate)
    -- ---------------------------------------------------------------
    p.play_description,
    p.play_description_short,

    p.play_wallclock,

    -- ---------------------------------------------------------------
    -- nflverse match + graft (see header). NULL analytics on unmatched
    -- and unmatchable rows alike; match_tier separates the two only in
    -- combination with is_matchable.
    -- ---------------------------------------------------------------
    (mb.play_key is not null)                       as is_matchable,
    m.match_tier,
    m.nflverse_game_id,
    m.play_id                                       as nflverse_play_id,

    nv.epa,
    nv.wpa,
    nv.success,
    nv.cpoe,
    nv.cp,
    nv.xpass,
    nv.pass_oe,
    nv.air_yards,
    nv.yards_after_catch,
    nv.qb_epa

from plays p
inner join games g
    on p.game_key = g.game_key
left join matchable mb
    on mb.play_key = p.play_key
left join matched m
    on m.play_key = p.play_key
left join nflverse_plays nv
    on  nv.nflverse_game_id = m.nflverse_game_id
    and nv.play_id = m.play_id
