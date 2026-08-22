{{
    config(
        materialized='table'
    )
}}

/*
    feat_player_game_rolling -- player x game.

    Completed games: players with a fact_player_game_offense row that game.
    Unplayed: players whose last box-score team_key (any season) matches
    home or away. dim_player has no team; do not explode the 13k-player dim.

    Same window contract as the team mart: completed RS/post only in the
    ordered set, plus unplayed stubs. Usage share is player window sum /
    team window sum, never a share of the current box.
*/

{% set windows = nfl_rolling_suffixes() %}
{% set part = 'player_key, season' %}

with games as (

    select * from {{ ref('dim_game') }}

),

offense as (

    select * from {{ ref('fact_player_game_offense') }}

),

last_team as (

    select
        o.player_key,
        o.player_id,
        o.team_key,
        o.team_id
    from offense o
    inner join games g
        on o.game_key = g.game_key
    qualify row_number() over (
        partition by o.player_key
        order by g.game_datetime desc, o.player_game_key desc
    ) = 1

),

completed_rows as (

    select
        o.player_game_key,
        o.game_key,
        o.game_id,
        g.game_datetime,
        g.game_date,
        g.date_key,
        g.season,
        g.week,
        g.season_type,
        g.season_week_key,
        o.player_key,
        o.player_id,
        o.team_key,
        o.team_id,
        (o.team_key = g.home_team_key) as is_home,
        g.is_completed,
        (g.is_completed and g.season_type in (2, 3)) as is_rolling_source,
        o.has_passing,
        o.has_rushing,
        o.has_receiving,
        o.passing_attempts,
        o.passing_completions,
        o.passing_yards,
        o.passing_touchdowns,
        o.passing_interceptions,
        o.times_sacked,
        o.rushing_attempts,
        o.rushing_yards,
        o.rushing_touchdowns,
        o.receiving_targets,
        o.receptions,
        o.receiving_yards,
        o.receiving_touchdowns,
        o.scrimmage_yards,
        o.touches
    from offense o
    inner join games g
        on o.game_key = g.game_key
    where g.is_completed
      and g.season_type in (2, 3)

),

unplayed_rows as (

    select
        {{ dbt_utils.generate_surrogate_key(['g.game_id', 'p.player_id']) }} as player_game_key,
        g.game_key,
        g.game_id,
        g.game_datetime,
        g.game_date,
        g.date_key,
        g.season,
        g.week,
        g.season_type,
        g.season_week_key,
        p.player_key,
        p.player_id,
        p.team_key,
        p.team_id,
        (p.team_key = g.home_team_key) as is_home,
        g.is_completed,
        false as is_rolling_source,
        false as has_passing,
        false as has_rushing,
        false as has_receiving,
        cast(null as number) as passing_attempts,
        cast(null as number) as passing_completions,
        cast(null as number) as passing_yards,
        cast(null as number) as passing_touchdowns,
        cast(null as number) as passing_interceptions,
        cast(null as number) as times_sacked,
        cast(null as number) as rushing_attempts,
        cast(null as number) as rushing_yards,
        cast(null as number) as rushing_touchdowns,
        cast(null as number) as receiving_targets,
        cast(null as number) as receptions,
        cast(null as number) as receiving_yards,
        cast(null as number) as receiving_touchdowns,
        cast(null as number) as scrimmage_yards,
        cast(null as number) as touches
    from games g
    inner join last_team p
        on p.team_key in (g.home_team_key, g.away_team_key)
    where not g.is_completed

),

window_base as (

    select * from completed_rows
    union all
    select * from unplayed_rows

),

windowed as (

    select
        player_game_key,
        game_key,
        player_key,
        season,

        {% for w in windows %}
        {{ nfl_roll('iff(is_rolling_source, 1, 0)', part, w) }} as n_games_played_{{ w }},
        {{ nfl_roll('iff(is_rolling_source and has_passing, 1, 0)', part, w) }} as n_passing_{{ w }},
        {{ nfl_roll('iff(is_rolling_source and has_rushing, 1, 0)', part, w) }} as n_rushing_{{ w }},
        {{ nfl_roll('iff(is_rolling_source and has_receiving, 1, 0)', part, w) }} as n_receiving_{{ w }},

        {{ nfl_roll('iff(is_rolling_source, passing_attempts, null)', part, w) }} as passing_attempts_{{ w }},
        {{ nfl_roll('iff(is_rolling_source, passing_completions, null)', part, w) }} as passing_completions_{{ w }},
        {{ nfl_roll('iff(is_rolling_source, passing_yards, null)', part, w) }} as passing_yards_{{ w }},
        {{ nfl_roll('iff(is_rolling_source, passing_touchdowns, null)', part, w) }} as passing_touchdowns_{{ w }},
        {{ nfl_roll('iff(is_rolling_source, passing_interceptions, null)', part, w) }} as passing_interceptions_{{ w }},
        {{ nfl_roll('iff(is_rolling_source, times_sacked, null)', part, w) }} as times_sacked_{{ w }},
        {{ nfl_roll('iff(is_rolling_source, rushing_attempts, null)', part, w) }} as rushing_attempts_{{ w }},
        {{ nfl_roll('iff(is_rolling_source, rushing_yards, null)', part, w) }} as rushing_yards_{{ w }},
        {{ nfl_roll('iff(is_rolling_source, rushing_touchdowns, null)', part, w) }} as rushing_touchdowns_{{ w }},
        {{ nfl_roll('iff(is_rolling_source, receiving_targets, null)', part, w) }} as receiving_targets_{{ w }},
        {{ nfl_roll('iff(is_rolling_source, receptions, null)', part, w) }} as receptions_{{ w }},
        {{ nfl_roll('iff(is_rolling_source, receiving_yards, null)', part, w) }} as receiving_yards_{{ w }},
        {{ nfl_roll('iff(is_rolling_source, receiving_touchdowns, null)', part, w) }} as receiving_touchdowns_{{ w }},
        {{ nfl_roll('iff(is_rolling_source, scrimmage_yards, null)', part, w) }} as scrimmage_yards_{{ w }},
        {{ nfl_roll('iff(is_rolling_source, touches, null)', part, w) }} as touches_{{ w }}{% if not loop.last %},{% endif %}
        {% endfor %}

    from window_base

),

team_roll as (

    select
        team_key,
        game_key,
        {% for w in windows %}
        passing_attempts_{{ w }} as team_passing_attempts_{{ w }},
        rushing_attempts_{{ w }} as team_rushing_attempts_{{ w }},
        net_passing_yards_{{ w }} as team_net_passing_yards_{{ w }}{% if not loop.last %},{% endif %}
        {% endfor %}
    from {{ ref('feat_team_game_rolling') }}

)

select
    b.player_game_key,
    b.game_key,
    b.game_id,
    b.game_datetime,
    b.game_date,
    b.date_key,
    b.season,
    b.week,
    b.season_type,
    b.season_week_key,
    b.player_key,
    b.player_id,
    b.team_key,
    b.team_id,
    b.is_home,
    b.is_completed,

    {% for w in windows %}
    coalesce(w.n_games_played_{{ w }}, 0) as n_games_played_{{ w }},
    coalesce(w.n_passing_{{ w }}, 0) as n_passing_{{ w }},
    coalesce(w.n_rushing_{{ w }}, 0) as n_rushing_{{ w }},
    coalesce(w.n_receiving_{{ w }}, 0) as n_receiving_{{ w }},

    w.passing_yards_{{ w }} / nullif(w.n_passing_{{ w }}, 0) as pass_yds_per_game_{{ w }},
    w.passing_attempts_{{ w }} / nullif(w.n_passing_{{ w }}, 0) as pass_att_per_game_{{ w }},
    w.passing_touchdowns_{{ w }} / nullif(w.n_passing_{{ w }}, 0) as pass_td_per_game_{{ w }},
    w.passing_yards_{{ w }} / nullif(w.passing_attempts_{{ w }}, 0) as ypa_{{ w }},
    w.passing_completions_{{ w }} / nullif(w.passing_attempts_{{ w }}, 0) as completion_rate_{{ w }},
    w.passing_interceptions_{{ w }} / nullif(w.passing_attempts_{{ w }}, 0) as int_rate_{{ w }},
    w.times_sacked_{{ w }} / nullif(w.passing_attempts_{{ w }}, 0) as sack_rate_{{ w }},
    w.passing_attempts_{{ w }} / nullif(t.team_passing_attempts_{{ w }}, 0) as team_pass_share_{{ w }},

    w.rushing_yards_{{ w }} / nullif(w.n_rushing_{{ w }}, 0) as rush_yds_per_game_{{ w }},
    w.rushing_attempts_{{ w }} / nullif(w.n_rushing_{{ w }}, 0) as rush_att_per_game_{{ w }},
    w.rushing_touchdowns_{{ w }} / nullif(w.n_rushing_{{ w }}, 0) as rush_td_per_game_{{ w }},
    w.rushing_yards_{{ w }} / nullif(w.rushing_attempts_{{ w }}, 0) as ypc_{{ w }},
    w.rushing_attempts_{{ w }} / nullif(t.team_rushing_attempts_{{ w }}, 0) as team_rush_share_{{ w }},

    w.receiving_yards_{{ w }} / nullif(w.n_receiving_{{ w }}, 0) as rec_yds_per_game_{{ w }},
    w.receiving_targets_{{ w }} / nullif(w.n_receiving_{{ w }}, 0) as targets_per_game_{{ w }},
    w.receptions_{{ w }} / nullif(w.n_receiving_{{ w }}, 0) as rec_per_game_{{ w }},
    w.receiving_touchdowns_{{ w }} / nullif(w.n_receiving_{{ w }}, 0) as rec_td_per_game_{{ w }},
    w.receiving_targets_{{ w }} / nullif(t.team_passing_attempts_{{ w }}, 0) as team_target_share_{{ w }},

    w.scrimmage_yards_{{ w }} / nullif(w.n_games_played_{{ w }}, 0) as scrimmage_yds_per_game_{{ w }},
    w.touches_{{ w }} / nullif(w.n_games_played_{{ w }}, 0) as touches_per_game_{{ w }},
    w.passing_yards_{{ w }} as passing_yards_{{ w }},
    w.rushing_yards_{{ w }} as rushing_yards_{{ w }},
    w.receiving_yards_{{ w }} as receiving_yards_{{ w }},
    w.touches_{{ w }} as touches_{{ w }}{% if not loop.last %},{% endif %}
    {% endfor %}

from window_base b
left join windowed w
    on b.player_game_key = w.player_game_key
left join team_roll t
    on  b.team_key = t.team_key
    and b.game_key = t.game_key
