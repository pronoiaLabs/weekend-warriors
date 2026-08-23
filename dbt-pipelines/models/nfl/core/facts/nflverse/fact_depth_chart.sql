{{ config(materialized='table') }}

/*
    fact_depth_chart -- the chart in effect at kickoff, one row per slot.
    Grain: game x team x chart_source x formation x position x slot x rank x
    player (the player closes the key: the 2023-24 weekly file legitimately
    lists two players at the same formation, position and rank).

    Two source shapes, one game-anchored fact:

      weekly (2023-24)  the league's weekly chart, mapped to that team's game
                        in the same season and week. formation is the coarse
                        unit (Offense, Defense, Special Teams), position the
                        specific slot (LCB, RG), depth_rank the depth.
      daily (2025-)     daily snapshots; each team-game takes the LAST
                        snapshot on or before the game's Eastern date, at
                        most 14 days old. formation is the package the chart
                        is drawn for ("3WR 1TE", "Base 3-4 D"), position the
                        slot within it, depth_slot separates the three WR
                        spots, depth_rank the depth within the slot.

    Postseason weeks in the weekly file are normalized onto nflverse's
    continuous numbering (19 to 22) before the join, the same rule
    bridge_game_ids composes with. The file also DOUBLE-LISTS playoff weeks
    (measured: 2023 week 19 appears as game_type REG and again as WC, same
    players, same ranks), so the join is game_type-aware: a postseason game
    takes only playoff-coded rows, a regular-season game only REG rows.
*/

with games as (

    select
        game_key,
        game_id,
        season,
        nflverse_week,
        is_postseason,
        game_date_et,
        home_team_key                                   as team_key,
        home_abbr_nflverse                              as team_abbr_nflverse
    from {{ ref('bridge_game_ids') }}
    where nflverse_game_id is not null

    union all

    select
        game_key,
        game_id,
        season,
        nflverse_week,
        is_postseason,
        game_date_et,
        away_team_key,
        away_abbr_nflverse
    from {{ ref('bridge_game_ids') }}
    where nflverse_game_id is not null

),

weekly as (

    select
        g.game_key,
        g.game_id,
        g.team_key,
        g.team_abbr_nflverse,
        'weekly'                                        as chart_source,
        w.formation,
        w.depth_position                                as position,
        cast(null as number)                            as depth_slot,
        w.depth_rank,
        w.gsis_id,
        w.full_name                                     as player_name,
        cast(null as date)                              as chart_as_of
    from {{ ref('stg_nfl__nflverse_depth_charts_weekly') }} w
    inner join games g
        on  g.season = w.season
        and g.nflverse_week = iff(w.week >= 19 or w.game_type = 'REG', w.week, w.week + 18)
        and g.team_abbr_nflverse = w.team
        -- the file double-lists playoff weeks under REG and the playoff code
        and iff(g.is_postseason, w.game_type != 'REG', w.game_type = 'REG')

),

daily as (

    select
        g.game_key,
        g.game_id,
        g.team_key,
        g.team_abbr_nflverse,
        'daily'                                         as chart_source,
        d.formation,
        d.position,
        d.depth_slot,
        d.depth_rank,
        d.gsis_id,
        d.player_name,
        d.chart_date                                    as chart_as_of
    from {{ ref('stg_nfl__nflverse_depth_charts') }} d
    inner join games g
        on  g.team_abbr_nflverse = d.team
        and d.chart_date <= g.game_date_et
        and d.chart_date > dateadd(day, -14, g.game_date_et)
    qualify d.chart_date = max(d.chart_date) over (partition by g.game_key, g.team_key)

),

unified as (

    select * from weekly
    union all
    select * from daily

)

select
    {{ dbt_utils.generate_surrogate_key([
        'u.game_key', 'u.team_key', 'u.chart_source', 'u.formation', 'u.position',
        "coalesce(u.depth_slot, -1)", 'u.depth_rank', "coalesce(u.gsis_id, u.player_name)"
    ]) }}                                               as depth_chart_key,
    p.player_key,
    u.*
from unified u
left join {{ ref('bridge_player_ids') }} p
    on p.gsis_id = u.gsis_id
