{{
    config(
        materialized='table'
    )
}}

/*
    app_team_standings -- the standings table, with home and away splits.

    Grain: team x season x season type x split, where split is 'all', 'home' or
    'away'. Derived from the team game facts so it is live during a season
    (fact_team_season is the league's end-of-season snapshot and only covers
    finished regular seasons; tests/nfl/assert_app_team_standings_reconcile_to_fact_team_season.sql
    keeps the two in agreement where they overlap).

    Rates are sum over sum across the games in the split, never an average of
    per-game rates. last_results is the split's most recent five results,
    newest first. Ranks are within (season, season type, split): overall, within
    the conference and within the division, by win pct then point differential.

    The EPA block comes from the team twins (the retired fact_team_game_epa's
    halves live on fact_team_game_offense / _defense): additive components plus
    ratio-of-sums rates, NULL for preseason where nflverse publishes no
    play-by-play. The EPA ranks are masked NULL on those rows so a preseason
    slice never collects trailing ranks. home_record / away_record denormalize
    the home and away split rows onto every row of the team-season via windows,
    NULL until the team has played that venue -- the standings table shows them
    as columns without a second query.
*/

with team_games as (

    select
        o.team_key,
        o.season,
        o.season_type,
        o.game_key,
        o.game_date,
        o.is_home,
        o.win_count,
        o.loss_count,
        o.tie_count,
        case when o.is_win then 'W' when o.is_loss then 'L' when o.is_tie then 'T' end
                                                        as result,
        o.points_scored,
        o.points_allowed,
        o.point_margin,
        o.total_yards,
        o.total_offensive_plays,
        o.net_passing_yards,
        o.rushing_yards,
        o.third_down_conversions,
        o.third_down_attempts,
        o.red_zone_scores,
        o.red_zone_attempts,
        o.turnovers,
        d.takeaways,
        o.sacks_allowed,
        d.sacks_recorded,
        d.opp_total_yards,
        d.opp_total_offensive_plays,
        d.opp_net_passing_yards,
        d.opp_rushing_yards,
        o.penalties,
        o.penalty_yards,
        o.off_plays,
        o.off_epa,
        o.success_plays,
        d.def_plays,
        d.def_epa,
        d.def_success_plays
    from {{ ref('fact_team_game_offense') }} o
    left join {{ ref('fact_team_game_defense') }} d
        on d.team_game_key = o.team_game_key

),

splits as (

    select 'all' as split, * from team_games
    union all
    select 'home', * from team_games where is_home
    union all
    select 'away', * from team_games where not is_home

),

agg as (

    select
        team_key,
        season,
        season_type,
        split,
        count(*)                                        as games,
        sum(win_count)                                  as wins,
        sum(loss_count)                                 as losses,
        sum(tie_count)                                  as ties,
        sum(points_scored)                              as points_for,
        sum(points_allowed)                             as points_against,
        sum(point_margin)                               as point_diff,
        sum(total_yards)                                as total_yards,
        sum(total_offensive_plays)                      as plays,
        sum(net_passing_yards)                          as net_passing_yards,
        sum(rushing_yards)                              as rushing_yards,
        sum(third_down_conversions)                     as third_down_conversions,
        sum(third_down_attempts)                        as third_down_attempts,
        sum(red_zone_scores)                            as red_zone_scores,
        sum(red_zone_attempts)                          as red_zone_attempts,
        sum(turnovers)                                  as turnovers,
        sum(takeaways)                                  as takeaways,
        sum(sacks_allowed)                              as sacks_allowed,
        sum(sacks_recorded)                             as sacks_recorded,
        sum(opp_total_yards)                            as opp_total_yards,
        sum(opp_total_offensive_plays)                  as opp_plays,
        sum(opp_net_passing_yards)                      as opp_net_passing_yards,
        sum(opp_rushing_yards)                          as opp_rushing_yards,
        sum(penalties)                                  as penalties,
        sum(penalty_yards)                              as penalty_yards,
        sum(off_plays)                                  as off_plays,
        sum(off_epa)                                    as off_epa,
        sum(success_plays)                              as success_plays,
        sum(def_plays)                                  as def_plays,
        sum(def_epa)                                    as def_epa,
        sum(def_success_plays)                          as def_success_plays,
        max(game_date)                                  as last_game_date,
        array_slice(
            array_agg(result) within group (order by game_date desc, game_key desc), 0, 5
        )                                               as last_results
    from splits
    group by 1, 2, 3, 4

),

season_types as (

    select distinct season_type, season_type_name, is_postseason
    from {{ ref('dim_season_week') }}

),

with_rates as (

    select
        a.*,
        {{ nfl_win_pct('a.wins', 'a.losses', 'a.ties') }} as win_pct,
        round(a.points_for / a.games, 1)                as points_for_per_game,
        round(a.points_against / a.games, 1)            as points_against_per_game,
        round(a.point_diff / a.games, 1)                as point_diff_per_game,
        iff(a.plays > 0, round(a.total_yards / a.plays, 2), null)
                                                        as yards_per_play,
        iff(a.opp_plays > 0, round(a.opp_total_yards / a.opp_plays, 2), null)
                                                        as opp_yards_per_play,
        iff(a.third_down_attempts > 0, round(a.third_down_conversions / a.third_down_attempts, 3), null)
                                                        as third_down_pct,
        iff(a.red_zone_attempts > 0, round(a.red_zone_scores / a.red_zone_attempts, 3), null)
                                                        as red_zone_pct,
        coalesce(a.takeaways, 0) - coalesce(a.turnovers, 0)
                                                        as turnover_margin,
        round(a.total_yards / a.games, 1)               as yards_per_game,
        round(a.opp_total_yards / a.games, 1)           as opp_yards_per_game,
        iff(a.off_plays > 0, round(a.off_epa / a.off_plays, 3), null)
                                                        as off_epa_per_play,
        iff(a.off_plays > 0, round(a.success_plays / a.off_plays, 3), null)
                                                        as success_rate,
        iff(a.def_plays > 0, round(a.def_epa / a.def_plays, 3), null)
                                                        as def_epa_per_play,
        iff(a.def_plays > 0, round(a.def_success_plays / a.def_plays, 3), null)
                                                        as success_rate_allowed
    from agg a

)

select
    {{ dbt_utils.generate_surrogate_key(['w.team_key', 'w.season', 'w.season_type', 'w.split']) }}
                                                        as app_team_standings_key,
    w.team_key,
    t.team_id,
    t.team_abbreviation                                 as team_label,
    t.team_full_name                                    as team_name,
    t.conference,
    t.division,
    w.season,
    w.season_type,
    st.season_type_name,
    st.is_postseason,
    w.split,
    w.games,
    w.wins,
    w.losses,
    w.ties,
    w.win_pct,
    w.points_for,
    w.points_against,
    w.point_diff,
    w.points_for_per_game,
    w.points_against_per_game,
    w.point_diff_per_game,
    w.total_yards,
    w.plays,
    w.yards_per_play,
    w.yards_per_game,
    w.net_passing_yards,
    w.rushing_yards,
    w.third_down_conversions,
    w.third_down_attempts,
    w.third_down_pct,
    w.red_zone_scores,
    w.red_zone_attempts,
    w.red_zone_pct,
    w.turnovers,
    w.takeaways,
    w.turnover_margin,
    w.sacks_allowed,
    w.sacks_recorded,
    w.opp_total_yards,
    w.opp_plays,
    w.opp_yards_per_play,
    w.opp_yards_per_game,
    w.opp_net_passing_yards,
    w.opp_rushing_yards,
    w.penalties,
    w.penalty_yards,
    w.last_game_date,
    w.last_results,
    w.off_plays,
    w.off_epa,
    w.off_epa_per_play,
    w.success_plays,
    w.success_rate,
    w.def_plays,
    w.def_epa,
    w.def_epa_per_play,
    w.def_success_plays,
    w.success_rate_allowed,
    -- masked so preseason rows (no pbp) never collect trailing ranks;
    -- nulls last is mandatory, Snowflake sorts NULLs first on desc
    iff(w.off_plays is null, null, rank() over (
        partition by w.season, w.season_type, w.split
        order by w.off_epa / nullif(w.off_plays, 0) desc nulls last
    ))                                                  as off_epa_per_play_rank,
    iff(w.def_plays is null, null, rank() over (
        partition by w.season, w.season_type, w.split
        order by w.def_epa / nullif(w.def_plays, 0) asc nulls last
    ))                                                  as def_epa_per_play_rank,
    -- the home and away split rows, denormalized onto every row of the
    -- team-season so the standings table shows them as columns
    max(iff(w.split = 'home',
        w.wins || '-' || w.losses || iff(w.ties > 0, '-' || w.ties, ''), null))
        over (partition by w.team_key, w.season, w.season_type)
                                                        as home_record,
    max(iff(w.split = 'away',
        w.wins || '-' || w.losses || iff(w.ties > 0, '-' || w.ties, ''), null))
        over (partition by w.team_key, w.season, w.season_type)
                                                        as away_record,
    rank() over (
        partition by w.season, w.season_type, w.split
        order by w.win_pct desc, w.point_diff desc, w.points_for desc
    )                                                   as rank_overall,
    rank() over (
        partition by w.season, w.season_type, w.split, t.conference
        order by w.win_pct desc, w.point_diff desc, w.points_for desc
    )                                                   as rank_conference,
    rank() over (
        partition by w.season, w.season_type, w.split, t.conference, t.division
        order by w.win_pct desc, w.point_diff desc, w.points_for desc
    )                                                   as rank_division
from with_rates w
inner join {{ ref('dim_team') }} t
    on t.team_key = w.team_key
left join season_types st
    on st.season_type = w.season_type
