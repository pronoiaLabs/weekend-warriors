{{
    config(
        materialized='table'
    )
}}

/*
    dim_stadium -- one row per physical bowl.

    The seed is keyed on the RAW.GAMES.venue string so aliases stay queryable.
    This dimension collapses those strings onto stadium_id (GEHA Field and
    Arrowhead are one bowl; Highmark old vs new are not).
*/

with seed as (

    select * from {{ ref('seed_nfl_stadiums') }}

),

deduped as (

    select
        stadium_id,
        display_name,
        lat,
        lon,
        elevation_m,
        timezone,
        roof,
        surface,
        is_weather_relevant,
        is_international
    from seed
    qualify row_number() over (
        partition by stadium_id
        order by venue_name
    ) = 1

)

select
    {{ dbt_utils.generate_surrogate_key(['stadium_id']) }} as stadium_key,
    stadium_id,
    display_name,
    lat,
    lon,
    elevation_m,
    timezone,
    roof,
    surface,
    is_weather_relevant,
    is_international
from deduped
