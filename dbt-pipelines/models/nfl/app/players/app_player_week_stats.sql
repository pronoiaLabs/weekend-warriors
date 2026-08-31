{{
    config(
        materialized='table'
    )
}}

/*
    app_player_week_stats -- one stat per row, with the comparisons a chart needs.

    Grain: player x game x stat. The long form of app_player_weeks for the stats
    a page plots or a prop is written on. Each row carries, for that stat:

      value                       this game
      trailing3_avg               this game and the two before it, same season type
      season_avg_through          season type average through this game (inclusive)
      season_total_through        running total through this game
      prior_season_same_week      the same stat in the same week and season type
                                  one season earlier, NULL if he did not play
      prior_season_avg            his per-game average for the stat one season
                                  earlier (same season type), NULL if no games
      prior_season_games          games behind that average

    The prior-season columns are the year-over-year view: "how was he trending
    at this point last season". They compare the player to himself, whichever
    team he was on. Stats with no value in a game (a WR's passing yards) are 0,
    not NULL, because the box score reports them as 0; a player-game row exists
    only when he appeared, so averages divide by games played.

    Vendor stats are the exception to the zero-fill rule: NULL means the
    vendor did not match that player-game, never zero, so their rows keep the
    NULL and every window average is an average over matched games only
    (values_through counts the observations behind it; games_through counts
    rows). For the share stats those averages are the display convention --
    an average of per-game shares, not a ratio of sums; the sanctioned
    ratio-of-sums aggregates live on app_player_leaders. A "season total" of
    a share is nonsense, so season_total_through is NULL on share rows.
*/

{# box-score stats: reported as 0 when a position does not accumulate them #}
{% set stats = [
    'passing_attempts', 'passing_completions', 'passing_yards', 'passing_touchdowns',
    'passing_interceptions', 'rushing_attempts', 'rushing_yards', 'rushing_touchdowns',
    'receiving_targets', 'receptions', 'receiving_yards', 'receiving_touchdowns',
    'scrimmage_yards', 'scrimmage_touchdowns', 'scoring_touchdowns', 'touches',
    'fumbles_lost', 'fanduel_points', 'draftkings_points',
] %}

{# vendor stats: NULL = no vendor match, kept NULL; additive, totals are real #}
{% set vendor_stats = ['receiving_epa', 'rushing_epa', 'passing_epa', 'ppr_points'] %}

{# share stats: NULL = no vendor match, kept NULL; NOT additive, no totals #}
{% set share_stats = ['target_share', 'air_yards_share', 'snap_pct'] %}

with weeks as (

    select * from {{ ref('app_player_weeks') }}

),

long as (

    {% for stat in stats %}
    select
        player_game_key, game_key, player_key, player_name, position, team_key, team_label,
        season, week, season_type, season_type_name, game_date,
        '{{ stat }}'                                    as stat_key,
        coalesce({{ stat }}, 0)                         as value
    from weeks
    union all
    {% endfor %}
    {% for stat in vendor_stats + share_stats %}
    select
        player_game_key, game_key, player_key, player_name, position, team_key, team_label,
        season, week, season_type, season_type_name, game_date,
        '{{ stat }}'                                    as stat_key,
        {{ stat }}                                      as value
    from weeks
    {% if not loop.last %}union all{% endif %}
    {% endfor %}

),

windows as (

    select
        *,
        avg(value) over (
            partition by player_key, season, season_type, stat_key
            order by game_date, game_key
            rows between 2 preceding and current row
        )                                               as trailing3_avg,
        avg(value) over (
            partition by player_key, season, season_type, stat_key
            order by game_date, game_key
            rows between unbounded preceding and current row
        )                                               as season_avg_through,
        sum(value) over (
            partition by player_key, season, season_type, stat_key
            order by game_date, game_key
            rows between unbounded preceding and current row
        )                                               as season_total_through,
        count(*) over (
            partition by player_key, season, season_type, stat_key
            order by game_date, game_key
            rows between unbounded preceding and current row
        )                                               as games_through,
        count(value) over (
            partition by player_key, season, season_type, stat_key
            order by game_date, game_key
            rows between unbounded preceding and current row
        )                                               as values_through
    from long

),

prior_season as (

    select
        player_key,
        season + 1                                      as season,
        season_type,
        stat_key,
        avg(value)                                      as prior_season_avg,
        count(value)                                    as prior_season_games
    from long
    group by 1, 2, 3, 4

),

prior_same_week as (

    select
        player_key,
        season + 1                                      as season,
        season_type,
        week,
        stat_key,
        max(value)                                      as prior_season_same_week
    from long
    group by 1, 2, 3, 4, 5

)

select
    {{ dbt_utils.generate_surrogate_key(['w.player_game_key', 'w.stat_key']) }}
                                                        as app_player_week_stats_key,
    w.player_game_key,
    w.game_key,
    w.player_key,
    w.player_name,
    w.position,
    w.team_key,
    w.team_label,
    w.season,
    w.week,
    w.season_type,
    w.season_type_name,
    w.game_date,
    w.stat_key,
    w.value,
    w.games_through,
    w.values_through,
    {% set share_keys %}{% for stat in share_stats %}'{{ stat }}'{% if not loop.last %}, {% endif %}{% endfor %}{% endset %}
    -- shares live on 0-1 and need the third decimal (28.7%, not 29%)
    round(w.trailing3_avg, iff(w.stat_key in ({{ share_keys }}), 3, 2))
                                                        as trailing3_avg,
    round(w.season_avg_through, iff(w.stat_key in ({{ share_keys }}), 3, 2))
                                                        as season_avg_through,
    iff(w.stat_key in ({{ share_keys }}), null, w.season_total_through)
                                                        as season_total_through,
    psw.prior_season_same_week,
    round(ps.prior_season_avg, iff(w.stat_key in ({{ share_keys }}), 3, 2))
                                                        as prior_season_avg,
    ps.prior_season_games,
    iff(ps.prior_season_avg is not null,
        round(w.season_avg_through - ps.prior_season_avg, iff(w.stat_key in ({{ share_keys }}), 3, 2)),
        null)                                           as avg_vs_prior_season
from windows w
left join prior_season ps
    on ps.player_key = w.player_key
   and ps.season = w.season
   and ps.season_type = w.season_type
   and ps.stat_key = w.stat_key
left join prior_same_week psw
    on psw.player_key = w.player_key
   and psw.season = w.season
   and psw.season_type = w.season_type
   and psw.week = w.week
   and psw.stat_key = w.stat_key
