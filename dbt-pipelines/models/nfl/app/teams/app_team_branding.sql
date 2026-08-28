{{
    config(
        materialized='table'
    )
}}

/*
    app_team_branding -- the 32 teams' visual identity, one fetch for the whole
    app. Grain: team.

    A straight slice of dim_team's nflverse branding block (colors, logos,
    wordmark) plus the labels every page joins on. Served by
    GET /api/{sport}/teams/branding, fetched once per session and joined
    client-side by team_key, which every mart carries -- so no other mart ever
    needs logo columns. color_primary is an accent behind a contrast check,
    logo_squared_url the safe mark on any background (per the assets plan in
    docs/nfl-app-screens-plan.html).
*/

select
    t.team_key                                          as app_team_branding_key,
    t.team_key,
    t.team_id,
    t.team_abbreviation                                 as team_label,
    t.team_full_name                                    as team_name,
    t.team_nickname,
    t.conference,
    t.division,
    t.nflverse_abbr,
    t.team_color_primary                                as color_primary,
    t.team_color_secondary                              as color_secondary,
    t.logo_url,
    t.logo_squared_url,
    t.wordmark_url
from {{ ref('dim_team') }} t
