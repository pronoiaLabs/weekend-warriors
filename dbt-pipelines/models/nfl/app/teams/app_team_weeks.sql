{{
    config(
        materialized='table'
    )
}}

/*
    app_team_weeks -- a team's season, one row per game played, with the line.

    Grain: team x game x sportsbook; a game with no closing line keeps one row
    with vendor NULL, the same shape as app_game_slate, so the API picks the
    chosen book's row or blanks the line. Completed games only (the facts hold
    nothing else); the slate carries what is still to be played.

    Each row is the team's own box score (fact_team_game_offense), the opponent's
    (fact_team_game_defense, the "allowed" side), the result, running season
    counts (wins_to_date and friends, in game order within the season type), and
    the closing line read from the team's side: spread is THIS team's spread, so
    a favourite is negative whether home or away. spread_result and total_result
    are computed here against the final score: the closing fact leaves them
    NULL until its own evaluation lands.
*/

with offense as (

    select * from {{ ref('fact_team_game_offense') }}

),

defense as (

    select * from {{ ref('fact_team_game_defense') }}

),

games as (

    select * from {{ ref('dim_game') }}

),

teams as (

    select * from {{ ref('dim_team') }}

),

closing as (

    select * from {{ ref('fact_game_betting_odds_closing') }}

),

-- every (team game, vendor) pair, plus a vendor-less row when no line exists
team_vendor as (

    select o.team_game_key, c.vendor, c.game_vendor_odds_key
    from offense o
    inner join closing c
        on c.game_key = o.game_key
    union all
    select o.team_game_key, null, null
    from offense o
    where not exists (select 1 from closing c where c.game_key = o.game_key)

),

running as (

    select
        team_game_key,
        row_number() over (
            partition by team_key, season, season_type order by game_date, game_key
        )                                               as season_game_number,
        sum(win_count) over (
            partition by team_key, season, season_type order by game_date, game_key
            rows between unbounded preceding and current row
        )                                               as wins_to_date,
        sum(loss_count) over (
            partition by team_key, season, season_type order by game_date, game_key
            rows between unbounded preceding and current row
        )                                               as losses_to_date,
        sum(tie_count) over (
            partition by team_key, season, season_type order by game_date, game_key
            rows between unbounded preceding and current row
        )                                               as ties_to_date,
        sum(point_margin) over (
            partition by team_key, season, season_type order by game_date, game_key
            rows between unbounded preceding and current row
        )                                               as point_diff_to_date
    from offense

),

sided as (

    select
        tv.team_game_key,
        tv.vendor,
        tv.game_vendor_odds_key,
        iff(o.is_home, c.home_spread, c.away_spread)    as spread,
        iff(o.is_home, c.home_spread_odds, c.away_spread_odds)
                                                        as spread_odds,
        iff(o.is_home, c.home_moneyline_odds, c.away_moneyline_odds)
                                                        as moneyline_odds,
        iff(o.is_home, c.home_moneyline_devig_probability, c.away_moneyline_devig_probability)
                                                        as moneyline_devig_probability,
        iff(o.is_home, c.opening_home_spread, c.opening_away_spread)
                                                        as opening_spread,
        iff(o.is_home, c.home_spread_movement, c.away_spread_movement)
                                                        as spread_movement,
        c.total_line,
        c.opening_total_line,
        c.total_line_movement,
        c.over_odds,
        c.under_odds,
        iff(o.is_home, c.implied_home_team_total, c.implied_away_team_total)
                                                        as implied_team_total,
        c.selected_snapshot_at                          as line_selected_at
    from team_vendor tv
    inner join offense o
        on o.team_game_key = tv.team_game_key
    left join closing c
        on c.game_vendor_odds_key = tv.game_vendor_odds_key

)

select
    {{ dbt_utils.generate_surrogate_key(['o.team_game_key', "coalesce(s.vendor, 'none')"]) }}
                                                        as app_team_weeks_key,
    o.team_game_key,
    o.game_key,
    o.game_id,
    o.team_key,
    o.team_id,
    t.team_abbreviation                                 as team_label,
    t.team_full_name                                    as team_name,
    t.conference,
    t.division,
    o.opponent_team_key,
    ot.team_abbreviation                                as opponent_label,
    ot.team_full_name                                   as opponent_name,
    o.season,
    o.week,
    o.season_type,
    g.season_type_name,
    o.is_postseason,
    g.game_date,
    g.game_datetime_et,
    regexp_replace(to_char(g.game_datetime_et, 'DY HH12:MI AM'), ' 0', ' ')
                                                        as kickoff_slot_et,
    o.is_home,
    g.is_completed,
    o.went_to_overtime,
    case when o.is_win then 'W' when o.is_loss then 'L' when o.is_tie then 'T' end
                                                        as result,
    r.season_game_number,
    r.wins_to_date,
    r.losses_to_date,
    r.ties_to_date,
    r.point_diff_to_date,
    o.points_scored                                     as points_for,
    o.points_allowed                                    as points_against,
    o.point_margin,
    o.points_scored + o.points_allowed                  as total_points,
    o.points_q1, o.points_q2, o.points_q3, o.points_q4, o.points_ot,
    o.first_downs,
    o.total_yards,
    o.total_offensive_plays                             as plays,
    o.yards_per_play,
    o.net_passing_yards,
    o.passing_completions,
    o.passing_attempts,
    o.yards_per_pass,
    o.rushing_yards,
    o.rushing_attempts,
    o.yards_per_rush_attempt,
    o.third_down_conversions,
    o.third_down_attempts,
    iff(o.third_down_attempts > 0, round(o.third_down_conversions / o.third_down_attempts, 3), null)
                                                        as third_down_pct,
    o.fourth_down_conversions,
    o.fourth_down_attempts,
    o.red_zone_scores,
    o.red_zone_attempts,
    iff(o.red_zone_attempts > 0, round(o.red_zone_scores / o.red_zone_attempts, 3), null)
                                                        as red_zone_pct,
    o.total_drives,
    o.possession_time_seconds,
    o.turnovers,
    d.takeaways,
    coalesce(d.takeaways, 0) - coalesce(o.turnovers, 0) as turnover_margin,
    o.fumbles_lost,
    o.interceptions_thrown,
    o.sacks_allowed,
    d.sacks_recorded,
    o.penalties,
    o.penalty_yards,
    d.opp_total_yards,
    d.opp_yards_per_play,
    d.opp_net_passing_yards,
    d.opp_rushing_yards,
    d.opp_third_down_conversions,
    d.opp_third_down_attempts,
    d.opp_red_zone_scores,
    d.opp_red_zone_attempts,
    d.opp_turnovers,
    o.has_box_score,
    -- the line, from this team's side
    s.vendor,
    s.spread,
    s.spread_odds,
    s.moneyline_odds,
    s.moneyline_devig_probability,
    s.opening_spread,
    s.spread_movement,
    s.total_line,
    s.opening_total_line,
    s.total_line_movement,
    s.over_odds,
    s.under_odds,
    s.implied_team_total,
    s.line_selected_at,
    case
        when s.spread is null then null
        when o.point_margin + s.spread > 0 then 'cover'
        when o.point_margin + s.spread = 0 then 'push'
        else 'loss'
    end                                                 as spread_result,
    iff(s.spread is null, null, o.point_margin + s.spread)
                                                        as margin_vs_spread,
    case
        when s.total_line is null then null
        when o.points_scored + o.points_allowed > s.total_line then 'over'
        when o.points_scored + o.points_allowed = s.total_line then 'push'
        else 'under'
    end                                                 as total_result
from offense o
inner join sided s
    on s.team_game_key = o.team_game_key
inner join running r
    on r.team_game_key = o.team_game_key
inner join games g
    on g.game_key = o.game_key
inner join teams t
    on t.team_key = o.team_key
left join teams ot
    on ot.team_key = o.opponent_team_key
left join defense d
    on d.team_game_key = o.team_game_key
