{{ config(materialized='table') }}

/*
    fact_sleeper_projection_snapshot -- the path each weekly projection took.
    Grain: player x season x season_type x week x snapshot, consecutive
    identical observations collapsed so a row means the projection MOVED,
    the same construction as fact_player_prop_snapshot.

    Collapse compares the headline scorings and the volume projections
    (pts_*, targets, receptions, yards, touchdowns, attempts); a snapshot
    that only wiggled a longtail column does not count as movement. DEF team
    rows are excluded (they have no player); game_key resolves through the
    team's game that week, NULL when Sleeper's clock and the schedule
    disagree. is_pre_kickoff rather than a hard filter: post-kickoff
    revisions exist and FEATURES applies its own leakage rule.
*/

with eligible as (

    select
        s.*,
        {{ nfl_team_abbr_nflverse('s.team') }}          as team_nflverse
    from {{ ref('stg_nfl__sleeper_projections') }} s
    where not s.is_team_defense

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
        game_datetime,
        home_abbr_nflverse,
        home_team_key,
        away_abbr_nflverse,
        away_team_key
    from {{ ref('bridge_game_ids') }}

),

located as (

    select
        e.*,
        g.game_key,
        g.game_id,
        g.game_datetime,
        case e.team_nflverse
            when g.home_abbr_nflverse then g.home_team_key
            when g.away_abbr_nflverse then g.away_team_key
        end                                             as team_key
    from eligible e
    left join games g
        on  g.season = e.season
        and e.team_nflverse in (g.home_abbr_nflverse, g.away_abbr_nflverse)
        and case e.season_type
                when 'regular' then g.season_type = 2 and g.week = e.week
                when 'post'    then g.is_postseason and g.nflverse_week = e.week + 18
                when 'pre'     then g.season_type = 1 and g.week = e.week
            end

),

ordered as (

    select
        *,
        {% set collapse_cols = [
            'pts_ppr', 'pts_half_ppr', 'pts_std', 'rec_tgt', 'rec', 'rec_yd', 'rec_td',
            'rush_att', 'rush_yd', 'rush_td', 'pass_att', 'pass_yd', 'pass_td', 'pass_int'
        ] %}
        {% for c in collapse_cols %}
        lag({{ c }}) over (
            partition by sleeper_player_id, season, season_type, week
            order by fetched_at
        )                                               as prev_{{ c }},
        {% endfor %}
        row_number() over (
            partition by sleeper_player_id, season, season_type, week
            order by fetched_at
        )                                               as raw_number
    from located

),

changed as (

    select *
    from ordered
    where raw_number = 1
    {% for c in collapse_cols %}
       or {{ c }} is distinct from prev_{{ c }}
    {% endfor %}

),

numbered as (

    select
        *,
        row_number() over (
            partition by sleeper_player_id, season, season_type, week
            order by fetched_at
        )                                               as snapshot_number,
        count(*) over (
            partition by sleeper_player_id, season, season_type, week
        )                                               as snapshots_total,
        lag(fetched_at) over (
            partition by sleeper_player_id, season, season_type, week
            order by fetched_at
        )                                               as prev_fetched_at
    from changed

)

select
    {{ dbt_utils.generate_surrogate_key([
        'n.sleeper_player_id', 'n.season', 'n.season_type', 'n.week', 'n.snapshot_number'
    ]) }}                                               as projection_snapshot_key,
    p.player_key,
    p.gsis_id,
    n.sleeper_player_id,
    n.game_key,
    n.game_id,
    n.team_key,
    n.season,
    n.season_type,
    n.week,
    n.team,
    n.opponent,
    n.snapshot_number,
    n.snapshots_total,
    n.snapshot_number = 1                               as is_opening,
    n.snapshot_number = n.snapshots_total               as is_latest,
    n.fetched_at,
    n.prev_fetched_at,
    iff(n.game_datetime is null, null, n.fetched_at < n.game_datetime)
                                                        as is_pre_kickoff,
    n.pts_ppr,
    n.pts_half_ppr,
    n.pts_std,
    n.pts_ppr - n.prev_pts_ppr                          as pts_ppr_change,
    n.rec_tgt,
    n.rec,
    n.rec_yd,
    n.rec_td,
    n.rush_att,
    n.rush_yd,
    n.rush_td,
    n.pass_att,
    n.pass_yd,
    n.pass_td,
    n.pass_int,
    n.fgm,
    n.fga,
    n.adp_dd_ppr,
    n.pos_adp_dd_ppr,
    n.last_modified_at
from numbered n
left join {{ ref('bridge_player_ids') }} p
    on p.sleeper_player_id = n.sleeper_player_id
