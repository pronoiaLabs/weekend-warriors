{{
    config(
        materialized='view'
    )
}}

/*
    stg_nfl__news_player_mentions -- extracted player mentions.
    Grain: article URL x player name as the article wrote it.

    The extraction gives a name, the team the article associates with it, a
    context tag and a one-sentence detail. No ids: resolving the name to a
    player_key is fact_player_news_mention's job, and the normalized name here
    is the key it joins on. Both the raw text and the normalized form are kept,
    because the raw text is what a reader needs to see and the normalized form
    is what the match needs.
*/

with source as (

    select * from {{ source('nfl_raw', 'news_player_mentions') }}

),

renamed as (

    select
        {{ dbt_utils.generate_surrogate_key(['url', 'player_name']) }}
                                                                as mention_key,
        {{ dbt_utils.generate_surrogate_key(['url']) }}         as article_key,
        url,

        -- who, as written and as matched
        nullif(trim(player_name), '')                           as player_name_text,
        {{ nfl_normalize_player_name('player_name') }}          as player_name_normalized,
        nullif(trim(team), '')                                  as team_text,

        -- what
        nullif(lower(trim(context)), '')                        as context,
        nullif(trim(detail), '')                                as detail,
        nullif(trim(headline), '')                              as headline,

        -- when (the extraction's own publish timestamp, if it found one)
        published_at,

        -- dlt load lineage
        try_to_double(_dlt_load_id)                             as dlt_load_id_numeric,
        to_timestamp_tz(try_to_double(_dlt_load_id)::number)    as loaded_at

    from source

)

select * from renamed
