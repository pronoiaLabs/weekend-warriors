{{
    config(
        materialized='table'
    )
}}

/*
    app_play_log -- the play feed: every play at the grain where patterns live.

    Grain: one row per BDL play (fact_play's grain, ALL rows kept -- admin and
    preseason included; play_category filters them out where a page wants
    scrimmage only). ~182k rows, growing ~2.8k a week in season. The Play Log
    page and the Explorer's plays sheet both read this; the page rolls nothing
    up -- drive aggregates ride on every row.

    The spine is BDL (fact_play): situation, description, outcome on every
    row. The nflverse graft rides the fact's match (~99.7% of matchable
    plays): EPA/WPA/success, the call detail, the drive ids and the role
    players. Unmatched and unmatchable rows (preseason foremost) keep NULL
    analytics, roles and drive columns -- visible, never imputed;
    has_nflverse says which. Role gsis ids resolve to player_key through
    bridge_player_ids -- a plain VIEW read, nothing re-decides.

    The situation vocabulary (down_bucket / distance_bucket / field_zone /
    game_script / play_family) is copied VERBATIM from
    fact_team_game_situation so the app speaks one situational language --
    with one addition the fact never needs: zero-valued BDL inputs (kickoffs
    and clock events carry distance 0) bucket to NULL instead of leaking
    into 'short'; the fact's base filter excludes those plays, so on
    is_epa_play rows the CASEs agree exactly;
    tests/nfl/assert_app_play_log_situation_vocabulary_reconciles.sql pins
    the copy. is_epa_play is that fact's base filter, the flag that makes
    the reconciliation exact. drive_yards sums this mart's own matched rows,
    so the ~0.3% unmatched plays can undercount a drive by a play -- the
    nflverse drive_play_count beside it is the file's own total.

    game_script and score_differential are the POSSESSION team's perspective
    (nflfastR's posteam framing), matching the fact's side = 'offense' rows.

    team_key is BDL's possession attribution, which disagrees with nflverse's
    posteam on a small share of plays (measured: at full coverage the game's
    dropback/carry totals reconcile exactly with fact_team_game_situation
    while per-team totals can shift by a few plays between the two teams).
    The reconciliation test therefore pins classification at game level; a
    team-filtered read here follows BDL's ruling.
*/

with plays as (

    select * from {{ ref('fact_play') }}

),

pbp as (

    select
        nflverse_game_id,
        play_id,
        posteam,
        play_type                                       as nv_play_type,
        pass,
        rush,
        shotgun,
        no_huddle,
        score_differential,
        half_seconds_remaining,
        fixed_drive,
        fixed_drive_result,
        series_result,
        drive_play_count,
        drive_time_of_possession,
        pass_length,
        pass_location,
        run_location,
        run_gap,
        passer_player_id,
        rusher_player_id,
        receiver_player_id
    from {{ ref('stg_nfl__nflverse_pbp') }}

),

games as (

    select game_key, game_date, home_team_key, away_team_key
    from {{ ref('dim_game') }}

),

types as (

    select play_type_key, play_type_slug, play_type_text, play_category
    from {{ ref('dim_play_type') }}

),

-- gsis -> player_key (a read of the bridge view; nothing re-decides)
gsis_players as (

    select b.gsis_id, b.player_key, p.full_name
    from {{ ref('bridge_player_ids') }} b
    inner join {{ ref('dim_player') }} p
        on p.player_key = b.player_key
    where b.player_key is not null

),

season_types as (

    select distinct season_type, season_type_name
    from {{ ref('dim_season_week') }}

),

joined as (

    select
        p.*,
        g.game_date,
        iff(p.is_home_possession is null, null,
            iff(p.is_home_possession, g.away_team_key, g.home_team_key))
                                                        as opponent_team_key,
        t.play_type_slug,
        t.play_type_text,
        t.play_category,
        nv.posteam,
        nv.nv_play_type,
        nv.pass,
        nv.rush,
        nv.shotgun,
        nv.no_huddle,
        nv.score_differential,
        nv.half_seconds_remaining,
        nv.fixed_drive,
        nv.fixed_drive_result,
        nv.series_result,
        nv.drive_play_count,
        nv.drive_time_of_possession,
        nv.pass_length,
        nv.pass_location,
        nv.run_location,
        nv.run_gap,
        nv.passer_player_id,
        nv.rusher_player_id,
        nv.receiver_player_id
    from plays p
    inner join games g
        on g.game_key = p.game_key
    left join types t
        on t.play_type_key = p.play_type_key
    left join pbp nv
        on nv.nflverse_game_id = p.nflverse_game_id
       and nv.play_id = p.nflverse_play_id

)

select
    j.play_key                                          as app_play_log_key,
    j.play_key,
    j.game_key,
    j.team_key,
    j.opponent_team_key,
    j.season,
    j.week,
    j.season_type,
    st.season_type_name,
    j.is_postseason,
    j.game_date,
    tm.team_abbreviation                                as team_label,
    ot.team_abbreviation                                as opponent_label,
    j.is_home_possession,

    -- sequence
    j.period                                            as quarter,
    j.clock_display,
    j.clock_seconds_remaining,
    j.score_differential,
    case
        when j.score_differential > 0                  then 'leading'
        when j.score_differential < 0                  then 'trailing'
        when j.score_differential is not null          then 'neutral'
    end                                                 as game_script,
    j.home_score_after_play,
    j.away_score_after_play,

    -- drive (nflverse; NULL on unmatched rows, masked windows likewise)
    j.fixed_drive                                       as drive_number,
    iff(j.fixed_drive is null, null, row_number() over (
        partition by j.nflverse_game_id, j.fixed_drive
        order by j.nflverse_play_id
    ))                                                  as play_in_drive,
    j.series_result,
    j.drive_play_count,
    iff(j.fixed_drive is null, null, sum(j.yards_gained) over (
        partition by j.game_key, j.fixed_drive
    ))                                                  as drive_yards,
    j.drive_time_of_possession,
    j.fixed_drive_result                                as drive_result,

    -- situation; the bucket CASEs mirror fact_team_game_situation
    j.start_down                                        as down,
    j.start_distance                                    as distance,
    j.start_yards_to_endzone                            as yards_to_endzone,
    case
        when j.start_down = 1          then '1st'
        when j.start_down = 2          then '2nd'
        when j.start_down in (3, 4)    then '3rd_4th'
    end                                                 as down_bucket,
    case
        when j.start_distance <= 0                 then null
        when j.start_distance <= 3                 then 'short'
        when j.start_distance between 4 and 7      then 'medium'
        when j.start_distance >= 8                 then 'long'
    end                                                 as distance_bucket,
    case
        when j.start_yards_to_endzone <= 0         then null
        when j.start_yards_to_endzone <= 20        then 'red_zone'
        when j.start_yards_to_endzone <= 50        then 'mid'
        else                                            'own'
    end                                                 as field_zone,
    j.is_red_zone,
    j.is_third_down,
    j.is_fourth_down,
    (j.half_seconds_remaining <= 120)                   as is_two_minute,
    (j.shotgun = 1)                                     as shotgun,
    (j.no_huddle = 1)                                   as no_huddle,

    -- the call
    j.play_type_text                                    as play_type,
    j.play_category,
    case
        when j.pass = 1                            then 'dropback'
        when j.rush = 1                            then 'designed_run'
        when j.nv_play_type in ('kickoff', 'punt', 'field_goal', 'extra_point')
                                                   then 'special'
    end                                                 as play_family,
    j.pass_length,
    j.pass_location,
    j.run_location,
    j.run_gap,

    -- who: NULL when unmatched or unbridged, never imputed
    ps.player_key                                       as passer_player_key,
    ps.full_name                                        as passer_name,
    ru.player_key                                       as rusher_player_key,
    ru.full_name                                        as rusher_name,
    rc.player_key                                       as receiver_player_key,
    rc.full_name                                        as receiver_name,

    -- outcome
    j.yards_gained,
    j.epa,
    j.wpa,
    (j.success = 1)                                     as success,
    j.achieved_first_down,
    lower(coalesce(j.play_type_slug, '')) like '%touchdown%'
                                                        as is_touchdown,
    j.is_scoring_play,
    j.air_yards,
    j.yards_after_catch,
    j.play_description,

    -- plumbing
    (j.match_tier is not null)                          as has_nflverse,
    (j.nv_play_type in ('pass', 'run') and j.epa is not null and j.posteam is not null)
                                                        as is_epa_play
from joined j
left join season_types st
    on st.season_type = j.season_type
left join {{ ref('dim_team') }} tm
    on tm.team_key = j.team_key
left join {{ ref('dim_team') }} ot
    on ot.team_key = j.opponent_team_key
left join gsis_players ps
    on ps.gsis_id = j.passer_player_id
left join gsis_players ru
    on ru.gsis_id = j.rusher_player_id
left join gsis_players rc
    on rc.gsis_id = j.receiver_player_id
