{{
    config(
        materialized='table'
    )
}}

/*
    dim_game -- descriptive context for each game. Grain: game.

    THE ONLY PLACE THE FULL NFL SLATE IS READABLE. fact_team_game_offense filters to
    completed games (an unplayed game has no fact rows), so scheduled games
    exist solely here, flagged by is_completed. The schedule semantic view
    anchors on this table for exactly that reason.

    Scores live on fact_team_game_offense, not here. dim_game answers "when, where, who
    played, what kind of game was it"; the outcome is a measure and belongs in
    the fact. went_to_overtime is the exception -- it is a characteristic of the
    game rather than a quantity, so it sits here as a dimension attribute.

    home_team_key and away_team_key are kept as a convenience for questions
    phrased in home/away terms. fact_team_game_offense additionally exposes
    opponent_team_key, which is the easier path for most analysis.

    Enrichment: nflverse_game_id is denormalized from bridge_game_ids (the
    bridge stays authoritative; NULL for preseason, which nflverse does not
    cover). referee is the head official only -- the full crew is
    dim_game_official at game x official grain. is_division_game is derived
    from BDL's own team reference (same conference AND division), read from
    staging rather than dim_team because dim_team's stadium_key now reads
    THIS model.
*/

with games as (

    select * from {{ ref('stg_nfl__games') }}

),

venues as (

    select
        venue_name,
        stadium_id
    from {{ ref('seed_nfl_stadiums') }}

),

bridge as (

    select
        game_key,
        nflverse_game_id
    from {{ ref('bridge_game_ids') }}

),

-- head official only. The source spells crew roles out in full ('Referee',
-- 'Umpire', 'Back Judge' -- measured, NOT the R/U/BJ codes), and every
-- officiated game carries exactly one Referee row.
referees as (

    select
        nflverse_game_id,
        official_name                                   as referee
    from {{ ref('stg_nfl__nflverse_officials') }}
    where official_position = 'Referee'

),

divisions as (

    select
        team_key,
        conference,
        division
    from {{ ref('stg_nfl__teams') }}

)

select
    g.game_key,
    g.game_id,

    -- when. Both spellings of the same instant: UTC as loaded, and US
    -- Eastern for display. The schedule semantic view exposes only the ET one.
    g.game_datetime,
    g.game_datetime_et,
    g.game_date,
    {{ dbt_utils.generate_surrogate_key(['g.game_date']) }}                    as date_key,
    g.season,
    g.week,
    g.season_type,
    g.season_type_name,
    g.is_postseason,
    {{ dbt_utils.generate_surrogate_key(['g.season', 'g.week', 'g.season_type']) }} as season_week_key,

    -- where. venue is the feed string; stadium_key collapses aliases.
    g.venue,
    iff(
        v.stadium_id is not null,
        {{ dbt_utils.generate_surrogate_key(['v.stadium_id']) }},
        null
    )                                                                         as stadium_key,

    -- participants
    g.home_team_key,
    g.home_team_id,
    g.away_team_key,
    g.away_team_id,

    -- character of the game
    g.game_status,
    g.is_completed,
    g.went_to_overtime,
    g.game_summary,

    -- + nflverse: identity and officiating. NULL = no nflverse coverage
    -- (preseason), never a placeholder.
    b.nflverse_game_id,
    r.referee,

    -- derived from BDL's own data: both clubs share conference and division
    (hd.conference = ad.conference
        and hd.division = ad.division)                                        as is_division_game

from games g
left join venues v
    on g.venue = v.venue_name
left join bridge b
    on b.game_key = g.game_key
left join referees r
    on r.nflverse_game_id = b.nflverse_game_id
inner join divisions hd
    on hd.team_key = g.home_team_key
inner join divisions ad
    on ad.team_key = g.away_team_key
