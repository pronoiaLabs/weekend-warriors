{{
    config(
        materialized='table'
    )
}}

/*
    feat_team_game_rolling -- team x game on the full dim_game slate.

    Rest (rest_days, is_short_week) is computed on every team-game including
    preseason. Rolling windows are NOT: the ordered set is completed
    regular-season + postseason, plus unplayed stubs so a future row still
    carries a trailing snapshot. Preseason must not occupy frame rows.

    Every rate is a ratio-of-sums across _std / _l3 / _l5. The current game
    is never in the window (ROWS ... AND 1 PRECEDING).
*/

{% set windows = nfl_rolling_suffixes() %}
{% set part = 'team_key, season' %}

with games as (

    select * from {{ ref('dim_game') }}

),

slate as (

    select
        {{ dbt_utils.generate_surrogate_key(['g.game_id', 'g.home_team_id']) }} as team_game_key,
        g.game_key,
        g.game_id,
        g.game_datetime,
        g.game_date,
        g.date_key,
        g.season,
        g.week,
        g.season_type,
        g.season_type_name,
        g.is_postseason,
        g.season_week_key,
        g.stadium_key,
        g.home_team_key as team_key,
        g.home_team_id as team_id,
        g.away_team_key as opponent_team_key,
        g.away_team_id as opponent_team_id,
        true as is_home,
        g.is_completed
    from games g

    union all

    select
        {{ dbt_utils.generate_surrogate_key(['g.game_id', 'g.away_team_id']) }} as team_game_key,
        g.game_key,
        g.game_id,
        g.game_datetime,
        g.game_date,
        g.date_key,
        g.season,
        g.week,
        g.season_type,
        g.season_type_name,
        g.is_postseason,
        g.season_week_key,
        g.stadium_key,
        g.away_team_key as team_key,
        g.away_team_id as team_id,
        g.home_team_key as opponent_team_key,
        g.home_team_id as opponent_team_id,
        false as is_home,
        g.is_completed
    from games g

),

slate_rest as (

    select
        s.*,
        datediff(
            'day',
            lag(s.game_datetime) over (
                partition by s.team_key, s.season
                order by s.game_datetime, s.game_key
            ),
            s.game_datetime
        ) as rest_days
    from slate s

),

offense as (

    select * from {{ ref('fact_team_game_offense') }}

),

defense as (

    select * from {{ ref('fact_team_game_defense') }}

),

-- Completed RS/post carry facts. Unplayed rows sit in the ordered set with
-- NULL measures so week-1 / mid-slate upcoming games still get a trailing
-- window. Preseason completed games stay off this set.
window_base as (

    select
        s.team_game_key,
        s.game_key,
        s.game_id,
        s.game_datetime,
        s.team_key,
        s.season,
        (s.is_completed and s.season_type in (2, 3)) as is_rolling_source,

        o.points_scored,
        o.point_margin,
        o.win_count,
        o.has_box_score,
        o.total_yards,
        o.total_offensive_plays,
        o.net_passing_yards,
        o.passing_attempts,
        o.rushing_yards,
        o.rushing_attempts,
        o.possession_time_seconds,
        o.first_downs,
        o.first_downs_passing,
        o.first_downs_rushing,
        o.first_downs_penalty,
        o.third_down_conversions,
        o.third_down_attempts,
        o.fourth_down_conversions,
        o.fourth_down_attempts,
        o.red_zone_scores,
        o.red_zone_attempts,
        o.total_drives,
        iff(o.has_box_score, coalesce(o.sacks_allowed, 0), null) as sacks_taken,
        o.sack_yards_lost,
        o.turnovers,
        o.interceptions_thrown,
        o.fumbles_lost,
        o.penalty_yards,

        d.points_allowed,
        d.has_opp_box_score,
        d.has_player_defense,
        d.opp_total_yards,
        d.opp_total_offensive_plays,
        d.opp_net_passing_yards,
        d.opp_passing_attempts,
        d.opp_rushing_yards,
        d.opp_rushing_attempts,
        d.opp_third_down_conversions,
        d.opp_third_down_attempts,
        d.opp_red_zone_scores,
        d.opp_red_zone_attempts,
        d.opp_first_downs,
        d.opp_total_drives,
        d.takeaways,
        d.sacks_recorded,
        d.qb_hits,
        d.tackles_for_loss,
        d.passes_defended,
        d.interceptions_recorded,
        d.defensive_touchdowns_team_box,
        d.defensive_touchdowns_player_rollup,
        d.defenders_with_stats
    from slate_rest s
    left join offense o
        on s.team_game_key = o.team_game_key
    left join defense d
        on s.team_game_key = d.team_game_key
    where (s.is_completed and s.season_type in (2, 3))
       or (not s.is_completed)

),

windowed as (

    select
        team_game_key,
        game_key,
        team_key,
        season,

        {% for w in windows %}
        {{ nfl_roll('iff(is_rolling_source, 1, 0)', part, w) }} as n_games_played_{{ w }},
        {{ nfl_roll('iff(is_rolling_source and has_box_score, 1, 0)', part, w) }} as n_boxed_{{ w }},
        {{ nfl_roll('iff(is_rolling_source and has_opp_box_score, 1, 0)', part, w) }} as n_opp_boxed_{{ w }},
        {{ nfl_roll('iff(is_rolling_source and has_player_defense, 1, 0)', part, w) }} as n_player_def_{{ w }},

        {{ nfl_roll('iff(is_rolling_source, points_scored, null)', part, w) }} as points_scored_{{ w }},
        {{ nfl_roll('iff(is_rolling_source, point_margin, null)', part, w) }} as point_margin_{{ w }},
        {{ nfl_roll('iff(is_rolling_source, win_count, null)', part, w) }} as win_count_{{ w }},
        {{ nfl_roll('iff(is_rolling_source, points_allowed, null)', part, w) }} as points_allowed_{{ w }},

        {{ nfl_roll('iff(is_rolling_source and has_box_score, total_yards, null)', part, w) }} as total_yards_{{ w }},
        {{ nfl_roll('iff(is_rolling_source and has_box_score, total_offensive_plays, null)', part, w) }} as total_offensive_plays_{{ w }},
        {{ nfl_roll('iff(is_rolling_source and has_box_score, net_passing_yards, null)', part, w) }} as net_passing_yards_{{ w }},
        {{ nfl_roll('iff(is_rolling_source and has_box_score, passing_attempts, null)', part, w) }} as passing_attempts_{{ w }},
        {{ nfl_roll('iff(is_rolling_source and has_box_score, rushing_yards, null)', part, w) }} as rushing_yards_{{ w }},
        {{ nfl_roll('iff(is_rolling_source and has_box_score, rushing_attempts, null)', part, w) }} as rushing_attempts_{{ w }},
        {{ nfl_roll('iff(is_rolling_source and has_box_score, possession_time_seconds, null)', part, w) }} as possession_time_seconds_{{ w }},
        {{ nfl_roll('iff(is_rolling_source and has_box_score, first_downs, null)', part, w) }} as first_downs_{{ w }},
        {{ nfl_roll('iff(is_rolling_source and has_box_score, first_downs_passing, null)', part, w) }} as first_downs_passing_{{ w }},
        {{ nfl_roll('iff(is_rolling_source and has_box_score, first_downs_rushing, null)', part, w) }} as first_downs_rushing_{{ w }},
        {{ nfl_roll('iff(is_rolling_source and has_box_score, first_downs_penalty, null)', part, w) }} as first_downs_penalty_{{ w }},
        {{ nfl_roll('iff(is_rolling_source and has_box_score, third_down_conversions, null)', part, w) }} as third_down_conversions_{{ w }},
        {{ nfl_roll('iff(is_rolling_source and has_box_score, third_down_attempts, null)', part, w) }} as third_down_attempts_{{ w }},
        {{ nfl_roll('iff(is_rolling_source and has_box_score, fourth_down_conversions, null)', part, w) }} as fourth_down_conversions_{{ w }},
        {{ nfl_roll('iff(is_rolling_source and has_box_score, fourth_down_attempts, null)', part, w) }} as fourth_down_attempts_{{ w }},
        {{ nfl_roll('iff(is_rolling_source and has_box_score, red_zone_scores, null)', part, w) }} as red_zone_scores_{{ w }},
        {{ nfl_roll('iff(is_rolling_source and has_box_score, red_zone_attempts, null)', part, w) }} as red_zone_attempts_{{ w }},
        {{ nfl_roll('iff(is_rolling_source and has_box_score, total_drives, null)', part, w) }} as total_drives_{{ w }},
        {{ nfl_roll('iff(is_rolling_source and has_box_score, sacks_taken, null)', part, w) }} as sacks_taken_{{ w }},
        {{ nfl_roll('iff(is_rolling_source and has_box_score, sack_yards_lost, null)', part, w) }} as sack_yards_lost_{{ w }},
        {{ nfl_roll('iff(is_rolling_source and has_box_score, turnovers, null)', part, w) }} as turnovers_{{ w }},
        {{ nfl_roll('iff(is_rolling_source and has_box_score, interceptions_thrown, null)', part, w) }} as interceptions_thrown_{{ w }},
        {{ nfl_roll('iff(is_rolling_source and has_box_score, fumbles_lost, null)', part, w) }} as fumbles_lost_{{ w }},
        {{ nfl_roll('iff(is_rolling_source and has_box_score, penalty_yards, null)', part, w) }} as penalty_yards_{{ w }},

        {{ nfl_roll('iff(is_rolling_source and has_opp_box_score, opp_total_yards, null)', part, w) }} as opp_total_yards_{{ w }},
        {{ nfl_roll('iff(is_rolling_source and has_opp_box_score, opp_total_offensive_plays, null)', part, w) }} as opp_total_offensive_plays_{{ w }},
        {{ nfl_roll('iff(is_rolling_source and has_opp_box_score, opp_net_passing_yards, null)', part, w) }} as opp_net_passing_yards_{{ w }},
        {{ nfl_roll('iff(is_rolling_source and has_opp_box_score, opp_passing_attempts, null)', part, w) }} as opp_passing_attempts_{{ w }},
        {{ nfl_roll('iff(is_rolling_source and has_opp_box_score, opp_rushing_yards, null)', part, w) }} as opp_rushing_yards_{{ w }},
        {{ nfl_roll('iff(is_rolling_source and has_opp_box_score, opp_rushing_attempts, null)', part, w) }} as opp_rushing_attempts_{{ w }},
        {{ nfl_roll('iff(is_rolling_source and has_opp_box_score, opp_third_down_conversions, null)', part, w) }} as opp_third_down_conversions_{{ w }},
        {{ nfl_roll('iff(is_rolling_source and has_opp_box_score, opp_third_down_attempts, null)', part, w) }} as opp_third_down_attempts_{{ w }},
        {{ nfl_roll('iff(is_rolling_source and has_opp_box_score, opp_red_zone_scores, null)', part, w) }} as opp_red_zone_scores_{{ w }},
        {{ nfl_roll('iff(is_rolling_source and has_opp_box_score, opp_red_zone_attempts, null)', part, w) }} as opp_red_zone_attempts_{{ w }},
        {{ nfl_roll('iff(is_rolling_source and has_opp_box_score, opp_first_downs, null)', part, w) }} as opp_first_downs_{{ w }},
        {{ nfl_roll('iff(is_rolling_source and has_opp_box_score, opp_total_drives, null)', part, w) }} as opp_total_drives_{{ w }},
        {{ nfl_roll('iff(is_rolling_source, takeaways, null)', part, w) }} as takeaways_{{ w }},

        {{ nfl_roll('iff(is_rolling_source and has_player_defense, sacks_recorded, null)', part, w) }} as sacks_recorded_{{ w }},
        {{ nfl_roll('iff(is_rolling_source and has_player_defense, qb_hits, null)', part, w) }} as qb_hits_{{ w }},
        {{ nfl_roll('iff(is_rolling_source and has_player_defense, tackles_for_loss, null)', part, w) }} as tackles_for_loss_{{ w }},
        {{ nfl_roll('iff(is_rolling_source and has_player_defense, passes_defended, null)', part, w) }} as passes_defended_{{ w }},
        {{ nfl_roll('iff(is_rolling_source and has_player_defense, interceptions_recorded, null)', part, w) }} as interceptions_recorded_{{ w }},
        {{ nfl_roll('iff(is_rolling_source, defensive_touchdowns_team_box, null)', part, w) }} as defensive_touchdowns_team_box_{{ w }},
        {{ nfl_roll('iff(is_rolling_source and has_player_defense, defensive_touchdowns_player_rollup, null)', part, w) }} as defensive_touchdowns_player_rollup_{{ w }},
        {{ nfl_roll('iff(is_rolling_source and has_player_defense, defenders_with_stats, null)', part, w) }} as defenders_with_stats_{{ w }}{% if not loop.last %},{% endif %}
        {% endfor %}

    from window_base

)

select
    s.team_game_key,
    s.game_key,
    s.game_id,
    s.game_datetime,
    s.game_date,
    s.date_key,
    s.season,
    s.week,
    s.season_type,
    s.season_type_name,
    s.is_postseason,
    s.season_week_key,
    s.stadium_key,
    s.team_key,
    s.team_id,
    s.opponent_team_key,
    s.opponent_team_id,
    s.is_home,
    s.is_completed,
    s.rest_days,
    (s.rest_days <= 5) as is_short_week,

    {% for w in windows %}
    coalesce(w.n_games_played_{{ w }}, 0) as n_games_played_{{ w }},
    (coalesce(w.n_boxed_{{ w }}, 0) > 0) as has_box_score_window_{{ w }},
    (coalesce(w.n_opp_boxed_{{ w }}, 0) > 0) as has_opp_box_score_window_{{ w }},
    (coalesce(w.n_player_def_{{ w }}, 0) > 0) as has_player_defense_window_{{ w }},

    w.points_scored_{{ w }} / nullif(w.n_games_played_{{ w }}, 0) as points_per_game_{{ w }},
    w.point_margin_{{ w }} / nullif(w.n_games_played_{{ w }}, 0) as margin_per_game_{{ w }},
    w.win_count_{{ w }} / nullif(w.n_games_played_{{ w }}, 0) as win_rate_{{ w }},
    w.total_yards_{{ w }} / nullif(w.total_offensive_plays_{{ w }}, 0) as yards_per_play_{{ w }},
    w.net_passing_yards_{{ w }} / nullif(w.passing_attempts_{{ w }}, 0) as yards_per_pass_{{ w }},
    w.rushing_yards_{{ w }} / nullif(w.rushing_attempts_{{ w }}, 0) as yards_per_rush_{{ w }},
    w.passing_attempts_{{ w }} / nullif(w.passing_attempts_{{ w }} + w.rushing_attempts_{{ w }}, 0) as pass_rate_{{ w }},
    w.possession_time_seconds_{{ w }} / nullif(w.total_offensive_plays_{{ w }}, 0) as seconds_per_play_{{ w }},
    w.total_offensive_plays_{{ w }} / nullif(w.n_boxed_{{ w }}, 0) as plays_per_game_{{ w }},
    w.passing_attempts_{{ w }} / nullif(w.n_boxed_{{ w }}, 0) as pass_att_per_game_{{ w }},
    w.rushing_attempts_{{ w }} / nullif(w.n_boxed_{{ w }}, 0) as rush_att_per_game_{{ w }},
    w.net_passing_yards_{{ w }} / nullif(w.n_boxed_{{ w }}, 0) as net_pass_per_game_{{ w }},
    w.rushing_yards_{{ w }} / nullif(w.n_boxed_{{ w }}, 0) as rush_yds_per_game_{{ w }},
    w.first_downs_{{ w }} / nullif(w.n_boxed_{{ w }}, 0) as first_downs_per_game_{{ w }},
    w.third_down_conversions_{{ w }} / nullif(w.third_down_attempts_{{ w }}, 0) as third_down_rate_{{ w }},
    w.fourth_down_conversions_{{ w }} / nullif(w.fourth_down_attempts_{{ w }}, 0) as fourth_down_rate_{{ w }},
    w.red_zone_scores_{{ w }} / nullif(w.red_zone_attempts_{{ w }}, 0) as red_zone_td_rate_{{ w }},
    w.total_drives_{{ w }} / nullif(w.n_boxed_{{ w }}, 0) as drives_per_game_{{ w }},
    w.sacks_taken_{{ w }} / nullif(w.passing_attempts_{{ w }} + w.sacks_taken_{{ w }}, 0) as sack_rate_taken_{{ w }},
    w.sack_yards_lost_{{ w }} / nullif(w.n_boxed_{{ w }}, 0) as sack_yards_per_game_{{ w }},
    w.turnovers_{{ w }} / nullif(w.total_drives_{{ w }}, 0) as turnover_rate_{{ w }},
    w.interceptions_thrown_{{ w }} / nullif(w.passing_attempts_{{ w }}, 0) as int_rate_{{ w }},
    w.fumbles_lost_{{ w }} / nullif(w.n_boxed_{{ w }}, 0) as fumbles_lost_per_game_{{ w }},
    w.penalty_yards_{{ w }} / nullif(w.n_boxed_{{ w }}, 0) as penalty_yards_per_game_{{ w }},

    w.points_allowed_{{ w }} / nullif(w.n_games_played_{{ w }}, 0) as opp_points_per_game_{{ w }},
    w.opp_total_yards_{{ w }} / nullif(w.opp_total_offensive_plays_{{ w }}, 0) as opp_yards_per_play_{{ w }},
    w.opp_net_passing_yards_{{ w }} / nullif(w.opp_passing_attempts_{{ w }}, 0) as opp_yards_per_pass_{{ w }},
    w.opp_rushing_yards_{{ w }} / nullif(w.opp_rushing_attempts_{{ w }}, 0) as opp_yards_per_rush_{{ w }},
    w.opp_passing_attempts_{{ w }} / nullif(w.opp_passing_attempts_{{ w }} + w.opp_rushing_attempts_{{ w }}, 0) as opp_pass_rate_{{ w }},
    w.opp_third_down_conversions_{{ w }} / nullif(w.opp_third_down_attempts_{{ w }}, 0) as opp_third_down_rate_{{ w }},
    w.opp_red_zone_scores_{{ w }} / nullif(w.opp_red_zone_attempts_{{ w }}, 0) as opp_red_zone_td_rate_{{ w }},
    w.opp_first_downs_{{ w }} / nullif(w.n_opp_boxed_{{ w }}, 0) as opp_first_downs_per_game_{{ w }},
    w.takeaways_{{ w }} / nullif(w.opp_total_drives_{{ w }}, 0) as takeaways_per_drive_{{ w }},
    w.sacks_recorded_{{ w }} / nullif(w.n_player_def_{{ w }}, 0) as sacks_recorded_per_game_{{ w }},
    w.qb_hits_{{ w }} / nullif(w.n_player_def_{{ w }}, 0) as qb_hits_per_game_{{ w }},
    w.tackles_for_loss_{{ w }} / nullif(w.n_player_def_{{ w }}, 0) as tfl_per_game_{{ w }},
    w.passes_defended_{{ w }} / nullif(w.n_player_def_{{ w }}, 0) as passes_defended_per_game_{{ w }},
    w.interceptions_recorded_{{ w }} / nullif(w.n_player_def_{{ w }}, 0) as interceptions_per_game_{{ w }},
    w.defensive_touchdowns_team_box_{{ w }} / nullif(w.n_games_played_{{ w }}, 0) as def_td_team_box_per_game_{{ w }},
    w.defensive_touchdowns_player_rollup_{{ w }} / nullif(w.n_player_def_{{ w }}, 0) as def_td_player_rollup_per_game_{{ w }},
    w.defenders_with_stats_{{ w }} / nullif(w.n_player_def_{{ w }}, 0) as defenders_with_stats_per_game_{{ w }},

    w.passing_attempts_{{ w }} as passing_attempts_{{ w }},
    w.rushing_attempts_{{ w }} as rushing_attempts_{{ w }},
    w.net_passing_yards_{{ w }} as net_passing_yards_{{ w }},
    w.rushing_yards_{{ w }} as rushing_yards_{{ w }},
    w.points_scored_{{ w }} as points_scored_{{ w }},
    w.takeaways_{{ w }} as takeaways_{{ w }}{% if not loop.last %},{% endif %}
    {% endfor %}

from slate_rest s
left join windowed w
    on s.team_game_key = w.team_game_key
