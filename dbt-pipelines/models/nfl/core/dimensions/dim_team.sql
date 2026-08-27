{{
    config(
        materialized='table'
    )
}}

/*
    dim_team -- the 32 NFL teams. Grain: team.

    A pure SCD1 dimension over static reference data. Teams do relocate and
    rebrand in reality, but this source carries only current names and covers
    only 2023-2025, so there is no history to track.

    Enrichment: nflverse_abbr materializes the vocabulary mapping (LAR -> LA,
    WSH -> WAS) so no nflverse join ever re-derives it per query; branding
    (colors, logos, wordmark) comes from stg_nfl__nflverse_teams on that
    abbreviation. stadium_key is the club's home bowl, observed as the most
    frequent stadium across its home games in dim_game -- international
    stadiums are excluded so a London "home" game can never claim the slot.
    Sleeper adds nothing at team level, deliberately.
*/

with teams as (

    select * from {{ ref('stg_nfl__teams') }}

),

branding as (

    select * from {{ ref('stg_nfl__nflverse_teams') }}

),

-- home bowl, observed rather than seeded: the stadium this team's home games
-- are actually played in, majority vote across dim_game. Excludes
-- international venues (Jacksonville plays London "home" games) and keeps the
-- most recent bowl on a tie, which is what a relocation would produce.
home_stadiums as (

    select
        g.home_team_key                                 as team_key,
        g.stadium_key,
        count(*)                                        as home_games,
        max(g.game_date)                                as last_home_game
    from {{ ref('dim_game') }} g
    inner join {{ ref('dim_stadium') }} s
        on s.stadium_key = g.stadium_key
    where not s.is_international
    group by 1, 2
    qualify row_number() over (
        partition by g.home_team_key
        order by count(*) desc, max(g.game_date) desc
    ) = 1

)

select
    t.team_key,
    t.team_id,

    t.team_abbreviation,
    t.team_full_name,
    t.team_location,
    t.team_nickname,

    t.conference,
    t.division,
    t.conference_division,

    -- + nflverse: join convenience and branding
    {{ nfl_team_abbr_nflverse('t.team_abbreviation') }} as nflverse_abbr,
    b.team_color_primary,
    b.team_color_secondary,
    b.logo_url,
    b.logo_squared_url,
    b.wordmark_url,

    -- home venue: FK to dim_stadium, roof / surface / weather one hop away
    hs.stadium_key

from teams t
left join branding b
    on b.team_abbr = {{ nfl_team_abbr_nflverse('t.team_abbreviation') }}
left join home_stadiums hs
    on hs.team_key = t.team_key
