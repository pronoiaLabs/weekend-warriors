{{
    config(
        materialized='view'
    )
}}

/*
    stg_nfl__news_articles -- scraped news articles. Grain: article URL.

    Landed hourly by the dlt `nfl_news` pipeline (Firecrawl over curated feeds).
    Each row is one URL: where it came from (feed), when the outlet says it was
    published, the page as markdown, and the raw JSON extraction when the feed's
    extract mode fired. The mentions the extraction produced live in
    stg_nfl__news_player_mentions; the JSON is kept here as-is for audit.

    published_at_effective is the timestamp to order news by: the outlet's own
    timestamp from the scrape when present, else the feed's, else the fetch time.
    All three are kept because the fallback chain is a data-quality signal.
*/

with source as (

    select * from {{ source('nfl_raw', 'news_articles') }}

),

renamed as (

    select
        {{ dbt_utils.generate_surrogate_key(['url']) }}         as article_key,
        url,

        -- provenance
        nullif(trim(feed), '')                                  as feed,
        nullif(trim(extract_mode), '')                          as extract_mode,
        coalesce(is_extracted, false)                           as is_extracted,
        matched_keywords,
        credits_used,

        -- content
        nullif(trim(title), '')                                 as title,
        nullif(trim(snippet), '')                               as snippet,
        markdown,
        feed_content,
        extraction,

        -- when
        feed_published_at,
        published_at,
        coalesce(published_at, feed_published_at, fetched_at)   as published_at_effective,
        coalesce(published_at, feed_published_at, fetched_at)::date
                                                                as published_date,
        fetched_at,

        -- dlt load lineage
        try_to_double(_dlt_load_id)                             as dlt_load_id_numeric,
        to_timestamp_tz(try_to_double(_dlt_load_id)::number)    as loaded_at

    from source

)

select * from renamed
