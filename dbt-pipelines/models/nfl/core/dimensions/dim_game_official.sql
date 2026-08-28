{{
    config(
        materialized='table'
    )
}}

/*
    dim_game_official -- the officiating crew, per game. Grain: game x
    official. Physical name GAME_OFFICIAL.

    Reference data for who worked each game; crew rotation feeds penalty-rate
    priors. official_position is the crew role, spelled out in full by the
    source ('Referee', 'Umpire', 'Back Judge', 'Down Judge' ... -- measured,
    NOT the R/U/BJ codes), plus alternates and replay officials on some games.
    The referee (exactly one per officiated game, measured) also denormalizes
    onto dim_game as its referee column.

    INNER join through bridge_game_ids on purpose: a crew row that resolves to
    no BDL game (nflverse covers seasons BDL does not carry) has no game_key
    to anchor on and would violate the grain's meaning here. The season / week
    block rides in from the bridge so it speaks BDL's numbering (postseason
    weeks 1, 2, 3, 5), consistent with the sibling dimensions.
*/

with officials as (

    select * from {{ ref('stg_nfl__nflverse_officials') }}

),

bridge as (

    select
        game_key,
        nflverse_game_id,
        season,
        week,
        season_type,
        season_type_name,
        is_postseason
    from {{ ref('bridge_game_ids') }}
    where nflverse_game_id is not null

)

select
    b.game_key,
    b.nflverse_game_id,

    o.official_id,
    o.official_name,
    o.official_position,
    o.jersey_number,

    -- when, in BDL's vocabulary (from the bridge, not nflverse's own columns)
    b.season,
    b.week,
    b.season_type,
    b.season_type_name,
    b.is_postseason,
    {{ dbt_utils.generate_surrogate_key(['b.season', 'b.week', 'b.season_type']) }} as season_week_key

from officials o
inner join bridge b
    on b.nflverse_game_id = o.nflverse_game_id
