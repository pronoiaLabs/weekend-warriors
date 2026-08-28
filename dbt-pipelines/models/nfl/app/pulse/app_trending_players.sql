{{
    config(
        materialized='table'
    )
}}

/*
    app_trending_players -- the Pulse's trending zone: Sleeper's add/drop
    leaderboard, latest fetch only, with identity and the player's next game.

    Grain: player x direction on the latest fetch per direction. The fact
    appends every six hours; this mart keeps only the freshest board (the
    movement history stays on fact_sleeper_trending). move_count_24h is the
    fact's move_count over its lookback_hours window (24 today -- the column
    rides along so the caption is data, not assumption).

    Unbridged players (no player_key) are dropped: the page needs a name and a
    headshot, and the top-100 boards bridge nearly completely; the drop count
    is visible by comparing against the fact. Team comes from the latest depth-chart
    appearance (dim_player deliberately has no team); NULL team renders as a
    dash and the next-game block is NULL with it.
*/

with latest as (

    select *
    from {{ ref('fact_sleeper_trending') }}
    qualify fetched_at = max(fetched_at) over (partition by direction)

),

players as (

    select * from {{ ref('dim_player') }}

),

teams as (

    select * from {{ ref('dim_team') }}

),

latest_chart_team as (

    select
        d.player_key,
        d.team_key
    from {{ ref('fact_depth_chart') }} d
    inner join {{ ref('dim_game') }} g
        on g.game_key = d.game_key
    where d.player_key is not null
    qualify row_number() over (
        partition by d.player_key
        order by g.game_datetime desc, d.chart_as_of desc nulls last
    ) = 1

),

next_game as (

    select
        t.team_key,
        g.game_key,
        g.game_datetime_et,
        iff(g.home_team_key = t.team_key, g.away_team_key, g.home_team_key)
                                                        as opponent_team_key,
        g.home_team_key = t.team_key                    as is_home
    from teams t
    inner join {{ ref('dim_game') }} g
        on (g.home_team_key = t.team_key or g.away_team_key = t.team_key)
       and not g.is_completed
    qualify row_number() over (partition by t.team_key order by g.game_datetime) = 1

)

select
    {{ dbt_utils.generate_surrogate_key(['l.direction', 'l.sleeper_player_id']) }}
                                                        as app_trending_players_key,
    l.player_key,
    p.player_id,
    l.sleeper_player_id,
    p.full_name                                         as player_name,
    p.position_abbreviation                             as position,
    p.position_name,
    p.position_group,
    p.headshot_url,

    lct.team_key,
    t.team_abbreviation                                 as team_label,
    t.team_full_name                                    as team_name,

    l.direction,
    l.move_count                                        as move_count_24h,
    l.board_rank,
    l.lookback_hours,
    l.fetched_at,
    l.trend_date,
    l.state_season,
    l.state_week,

    ng.game_key                                         as next_game_key,
    ng.game_datetime_et                                 as next_game_datetime_et,
    ng.opponent_team_key                                as next_opponent_team_key,
    ot.team_abbreviation                                as next_opponent_label,
    ng.is_home                                          as next_game_is_home

from latest l
inner join players p
    on p.player_key = l.player_key
left join latest_chart_team lct
    on lct.player_key = l.player_key
left join teams t
    on t.team_key = lct.team_key
left join next_game ng
    on ng.team_key = lct.team_key
left join teams ot
    on ot.team_key = ng.opponent_team_key
