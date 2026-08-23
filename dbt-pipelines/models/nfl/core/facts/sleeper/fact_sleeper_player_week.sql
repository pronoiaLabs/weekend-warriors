{{ config(materialized='table') }}

/*
    fact_sleeper_player_week -- Sleeper's weekly actuals with fantasy points.
    Grain: player x season x season_type x week (DEF team rows carried with
    is_team_defense = true and no player_key; their player id is the club).

    What the box score cannot give: the three fantasy scorings of the actual
    week, positional ranks per scoring, and snap counts with the team total
    beside them (snap_share here = off_snp / tm_off_snp). game_key resolves
    through the team's game that week, like the projection snapshots.
*/

with stats as (

    select
        s.*,
        {{ nfl_team_abbr_nflverse('s.team') }}          as team_nflverse
    from {{ ref('stg_nfl__sleeper_stats') }} s

),

games as (

    select
        game_key,
        game_id,
        season,
        week,
        nflverse_week,
        season_type,
        is_postseason,
        home_abbr_nflverse,
        home_team_key,
        away_abbr_nflverse,
        away_team_key
    from {{ ref('bridge_game_ids') }}

)

select
    {{ dbt_utils.generate_surrogate_key([
        's.sleeper_player_id', 's.season', 's.season_type', 's.week'
    ]) }}                                               as sleeper_player_week_key,
    p.player_key,
    p.gsis_id,
    s.sleeper_player_id,
    s.is_team_defense,
    g.game_key,
    g.game_id,
    case s.team_nflverse
        when g.home_abbr_nflverse then g.home_team_key
        when g.away_abbr_nflverse then g.away_team_key
    end                                                 as team_key,
    s.season,
    s.season_type,
    s.week,
    s.team,
    s.opponent,

    s.pts_std,
    s.pts_half_ppr,
    s.pts_ppr,
    s.pos_rank_std,
    s.pos_rank_half_ppr,
    s.pos_rank_ppr,

    s.gp,
    s.gs,
    s.off_snp,
    s.def_snp,
    s.st_snp,
    s.tm_off_snp,
    s.off_snp / nullif(s.tm_off_snp, 0)                 as off_snap_share,

    s.pass_att,
    s.pass_cmp,
    s.pass_yd,
    s.pass_td,
    s.pass_int,
    s.pass_sack,
    s.rush_att,
    s.rush_yd,
    s.rush_td,
    s.rec_tgt,
    s.rec,
    s.rec_yd,
    s.rec_td,
    s.rec_drop,
    s.rec_air_yd,
    s.fum,
    s.fum_lost,
    s.fgm,
    s.fga,
    s.xpm,
    s.xpa,

    s.idp_tkl,
    s.idp_sack,
    s.idp_int,
    s.pts_allow,
    s.yds_allow,

    s.fetched_at,
    s.loaded_at
from stats s
left join games g
    on  g.season = s.season
    and s.team_nflverse in (g.home_abbr_nflverse, g.away_abbr_nflverse)
    and case s.season_type
            when 'regular' then g.season_type = 2 and g.week = s.week
            when 'post'    then g.is_postseason and g.nflverse_week = s.week + 18
            when 'pre'     then g.season_type = 1 and g.week = s.week
        end
left join {{ ref('bridge_player_ids') }} p
    on p.sleeper_player_id = s.sleeper_player_id
