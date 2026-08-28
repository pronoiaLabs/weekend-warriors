{{ config(materialized='view') }}

{#
    stg_nfl__nflverse_teams -- franchise branding and structure.
    Grain: team_abbr (36 rows: 32 current + LA/OAK/SD/STL legacy).

    The legacy abbreviations are the point, not noise: they are what lets
    history join cleanly across relocations. dim_team enriches from the
    current 32 via nfl_team_abbr_nflverse(); readers that touch old seasons
    keep the legacy rows available here.

    Colors are hex strings; the logo/wordmark columns are public CDN URLs
    (ESPN, nflverse-hosted) served as-is to the dashboard.
#}

with source as (

    select * from {{ source('nfl_raw', 'nflverse_teams') }}

)

select
    team_abbr,
    team_name,
    team_id,
    team_nick,
    team_conf                                           as team_conference,
    team_division,
    team_color                                          as team_color_primary,
    team_color2                                         as team_color_secondary,
    team_color3                                         as team_color_tertiary,
    team_color4                                         as team_color_quaternary,
    team_logo_espn                                      as logo_url,
    team_logo_squared                                   as logo_squared_url,
    team_logo_wikipedia                                 as logo_wikipedia_url,
    team_wordmark                                       as wordmark_url,
    team_conference_logo                                as conference_logo_url,
    team_league_logo                                    as league_logo_url,
    to_timestamp_tz(_dlt_load_id::float::number)        as loaded_at
from source
