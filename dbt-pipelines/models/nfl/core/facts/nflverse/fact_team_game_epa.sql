{{ config(materialized='table') }}

/*
    fact_team_game_epa -- the play-by-play file rolled up to team x game.
    Grain: team x game, team_game_key = surrogate(game_id, team_id), the
    SAME key as fact_team_game_offense, so the two join 1:1 and the EPA
    columns bolt straight onto the box score.

    Scrimmage plays only: play_type in (pass, run) with a non-NULL EPA
    (measured 2025: 34,632 of 48,771 rows; qb_dropback adds nothing beyond
    those two types). Special teams, penalties-only and no-plays are out.
    The def_* columns are the same plays read from the defense's side
    (defteam = team), so a team's off_epa is its opponent's def_epa by
    construction; tests/nfl/assert_team_game_epa_mirrors holds it.

    Rates are computed here from this fact's own sums (they cannot be
    re-aggregated); anything at another grain should go back to the sums.
    proe is pass rate over expected: mean(pass - xpass) on scrimmage plays.

    Play-level detail deliberately stays in RAW.NFLVERSE_PBP (372 columns is
    an archive, not a model); this is the modeling surface.
*/

with plays as (

    select
        game_id                                         as nflverse_game_id,
        posteam,
        defteam,
        epa,
        success,
        yards_gained,
        pass,
        rush,
        down,
        cpoe,
        xpass
    from {{ source('nfl_raw', 'nflverse_pbp') }}
    where play_type in ('pass', 'run')
      and epa is not null
      and posteam is not null

),

offense as (

    select
        nflverse_game_id,
        posteam                                         as team,
        count(*)                                        as off_plays,
        sum(epa)                                        as off_epa,
        sum(epa) / count(*)                             as off_epa_per_play,
        sum(success) / count(*)                         as off_success_rate,
        sum(iff(down in (1, 2), success, 0))
            / nullif(count_if(down in (1, 2)), 0)       as off_early_down_success_rate,
        count_if(pass = 1)                              as off_dropbacks,
        sum(iff(pass = 1, epa, 0))                      as off_pass_epa,
        sum(iff(pass = 1, epa, 0))
            / nullif(count_if(pass = 1), 0)             as off_pass_epa_per_dropback,
        count_if(rush = 1)                              as off_carries,
        sum(iff(rush = 1, epa, 0))                      as off_rush_epa,
        sum(iff(rush = 1, epa, 0))
            / nullif(count_if(rush = 1), 0)             as off_rush_epa_per_carry,
        count_if((pass = 1 and yards_gained >= 20) or (rush = 1 and yards_gained >= 10))
            / count(*)                                  as off_explosive_rate,
        avg(cpoe)                                       as off_cpoe,
        count_if(pass = 1) / count(*)                   as off_pass_rate,
        avg(pass - xpass)                               as off_proe
    from plays
    group by 1, 2

),

defense as (

    select
        nflverse_game_id,
        defteam                                         as team,
        count(*)                                        as def_plays,
        sum(epa)                                        as def_epa,
        sum(epa) / count(*)                             as def_epa_per_play,
        sum(success) / count(*)                         as def_success_rate_allowed,
        count_if(pass = 1)                              as def_dropbacks_faced,
        sum(iff(pass = 1, epa, 0))
            / nullif(count_if(pass = 1), 0)             as def_pass_epa_per_dropback,
        count_if(rush = 1)                              as def_carries_faced,
        sum(iff(rush = 1, epa, 0))
            / nullif(count_if(rush = 1), 0)             as def_rush_epa_per_carry,
        count_if((pass = 1 and yards_gained >= 20) or (rush = 1 and yards_gained >= 10))
            / count(*)                                  as def_explosive_rate_allowed
    from plays
    group by 1, 2

),

games as (

    select
        nflverse_game_id,
        game_key,
        game_id,
        season,
        week,
        season_type,
        season_type_name,
        game_date,
        home_abbr_nflverse,
        home_team_key,
        home_team_id,
        away_abbr_nflverse,
        away_team_key,
        away_team_id
    from {{ ref('bridge_game_ids') }}
    where nflverse_game_id is not null

)

select
    {{ dbt_utils.generate_surrogate_key([
        'g.game_id',
        "iff(o.team = g.home_abbr_nflverse, g.home_team_id, g.away_team_id)"
    ]) }}                                               as team_game_key,
    g.game_key,
    g.game_id,
    iff(o.team = g.home_abbr_nflverse, g.home_team_key, g.away_team_key)
                                                        as team_key,
    iff(o.team = g.home_abbr_nflverse, g.home_team_id, g.away_team_id)
                                                        as team_id,
    iff(o.team = g.home_abbr_nflverse, g.away_team_key, g.home_team_key)
                                                        as opponent_team_key,
    o.team                                              as team_abbr_nflverse,
    o.nflverse_game_id,
    g.season,
    g.week,
    g.season_type,
    g.season_type_name,
    g.game_date,
    o.team = g.home_abbr_nflverse                       as is_home,

    o.off_plays,
    o.off_epa,
    o.off_epa_per_play,
    o.off_success_rate,
    o.off_early_down_success_rate,
    o.off_dropbacks,
    o.off_pass_epa,
    o.off_pass_epa_per_dropback,
    o.off_carries,
    o.off_rush_epa,
    o.off_rush_epa_per_carry,
    o.off_explosive_rate,
    o.off_cpoe,
    o.off_pass_rate,
    o.off_proe,

    d.def_plays,
    d.def_epa,
    d.def_epa_per_play,
    d.def_success_rate_allowed,
    d.def_dropbacks_faced,
    d.def_pass_epa_per_dropback,
    d.def_carries_faced,
    d.def_rush_epa_per_carry,
    d.def_explosive_rate_allowed

from offense o
inner join defense d
    on d.nflverse_game_id = o.nflverse_game_id
   and d.team = o.team
inner join games g
    on g.nflverse_game_id = o.nflverse_game_id
