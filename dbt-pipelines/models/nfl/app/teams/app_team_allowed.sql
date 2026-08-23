{{
    config(
        materialized='table'
    )
}}

/*
    app_team_allowed -- what each defense gives up, by position and stat.

    Grain: defense team x season x season type x position x stat. One row says
    "this defense allows N <stat> per game to <position>s, ranking R of T, where
    rank 1 allows the most". The game prop board and the team page both read it,
    so a prop's matchup column and the team page's "allowed" table agree by
    construction (the prop board used to carry its own copy of this logic).

    The stat comes from the opposing players' box scores (fact_player_game_offense)
    attributed to the defense they faced, so it is a player-position rollup, not
    the team box score: the RB row is rushing yards by RBs, not all rushing yards.
    Positions are the player's position from dim_player. The pairs below are the
    ones props are written on; adding a pair is one line in position_stats.

    Season types are kept apart (preseason defenses are not regular-season
    defenses); the rank partitions on season, season type, position and stat.
*/

with offense as (

    select
        o.game_key,
        o.player_key,
        o.team_key,
        o.season,
        o.season_type,
        iff(o.team_key = g.home_team_key, g.away_team_key, g.home_team_key)
                                                        as defense_team_key,
        o.passing_yards,
        o.passing_touchdowns,
        o.rushing_yards,
        o.receiving_yards,
        o.receptions,
        coalesce(o.rushing_touchdowns, 0) + coalesce(o.receiving_touchdowns, 0)
                                                        as scoring_touchdowns
    from {{ ref('fact_player_game_offense') }} o
    inner join {{ ref('dim_game') }} g
        on g.game_key = o.game_key

),

players as (

    select
        player_key,
        position_abbreviation                           as position
    from {{ ref('dim_player') }}
    where position_abbreviation is not null

),

-- the (position, stat) pairs a defense is measured on
position_stats as (

    select 'QB' as position, 'passing_yards'      as stat_key union all
    select 'QB',             'passing_touchdowns'           union all
    select 'RB',             'rushing_yards'                union all
    select 'RB',             'receiving_yards'              union all
    select 'RB',             'scoring_touchdowns'           union all
    select 'WR',             'receiving_yards'              union all
    select 'WR',             'receptions'                   union all
    select 'WR',             'scoring_touchdowns'           union all
    select 'TE',             'receiving_yards'              union all
    select 'TE',             'receptions'                   union all
    select 'TE',             'scoring_touchdowns'

),

-- one row per player-game-stat
offense_long as (

    {% set stats = ['passing_yards', 'passing_touchdowns', 'rushing_yards', 'receiving_yards', 'receptions', 'scoring_touchdowns'] %}
    {% for stat in stats %}
    select
        game_key, player_key, defense_team_key, season, season_type,
        '{{ stat }}'                                    as stat_key,
        {{ stat }}                                      as stat_value
    from offense
    {% if not loop.last %}union all{% endif %}
    {% endfor %}

),

allowed as (

    select
        ol.defense_team_key,
        ol.season,
        ol.season_type,
        ps.position,
        ps.stat_key,
        sum(coalesce(ol.stat_value, 0))                 as allowed_total,
        count(distinct ol.game_key)                     as defense_games,
        sum(coalesce(ol.stat_value, 0)) / count(distinct ol.game_key)
                                                        as allowed_per_game
    from offense_long ol
    inner join players pl
        on pl.player_key = ol.player_key
    inner join position_stats ps
        on ps.position = pl.position
       and ps.stat_key = ol.stat_key
    group by 1, 2, 3, 4, 5

),

ranked as (

    select
        *,
        rank() over (
            partition by season, season_type, position, stat_key
            order by allowed_per_game desc
        )                                               as allowed_rank,
        count(*) over (partition by season, season_type, position, stat_key)
                                                        as teams_ranked,
        avg(allowed_per_game) over (partition by season, season_type, position, stat_key)
                                                        as league_avg_per_game
    from allowed

),

season_types as (

    select distinct season_type, season_type_name, is_postseason
    from {{ ref('dim_season_week') }}

)

select
    {{ dbt_utils.generate_surrogate_key(['r.defense_team_key', 'r.season', 'r.season_type', 'r.position', 'r.stat_key']) }}
                                                        as app_team_allowed_key,
    r.defense_team_key                                  as team_key,
    t.team_id,
    t.team_abbreviation                                 as team_label,
    t.team_full_name                                    as team_name,
    t.conference,
    t.division,
    r.season,
    r.season_type,
    st.season_type_name,
    st.is_postseason,
    r.position,
    r.stat_key,
    r.defense_games,
    r.allowed_total,
    round(r.allowed_per_game, 2)                        as allowed_per_game,
    round(r.league_avg_per_game, 2)                     as league_avg_per_game,
    round(r.allowed_per_game - r.league_avg_per_game, 2)
                                                        as allowed_vs_league,
    r.allowed_rank,
    r.teams_ranked
from ranked r
inner join {{ ref('dim_team') }} t
    on t.team_key = r.defense_team_key
left join season_types st
    on st.season_type = r.season_type
