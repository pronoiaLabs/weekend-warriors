{{ config(materialized='table') }}

{#
    bridge_game_ids -- dim_game's game_key beside the nflverse game id.

    nflverse keys a game as <season>_<week>_<away>_<home> (2025_01_DAL_PHI),
    BallDontLie with a number. Two differences to absorb, both measured:

      * abbreviations: LA/LAR and WAS/WSH (nfl_team_abbr_nflverse).
      * postseason weeks: BallDontLie numbers the playoffs 1, 2, 3, 5 (the
        Super Bowl sits at 5, there is no 4) where nflverse continues the
        season at 19, 20, 21, 22. Regular-season weeks agree.

    The id is taken from nflverse's own play-by-play when that game has been
    played (joined on season, both mapped abbreviations and the Eastern-time
    game date: 848 of 855 games 2023 to 2025), and composed from the rule
    above otherwise, so future games carry an id too. The composed form is
    always kept beside it; tests/nfl/assert_bridge_game_ids_agree_with_observed
    fails if the two ever disagree on a played game, which is the early
    warning for a vocabulary change. Preseason has no nflverse id (nflverse
    publishes no preseason play-by-play).

    Sleeper's game id is a different shape (season, type, week, game number)
    with no team in it; Sleeper rows resolve to a game through season, week
    and the team instead, so nothing here is needed for them.
#}

with games as (

    select
        g.game_key,
        g.game_id,
        g.season,
        g.week,
        g.season_type,
        g.season_type_name,
        g.is_postseason,
        g.game_datetime,
        g.game_datetime_et,
        g.game_date,
        g.is_completed,
        g.home_team_key,
        g.home_team_id,
        ht.team_abbreviation                            as home_abbr,
        g.away_team_key,
        g.away_team_id,
        at.team_abbreviation                            as away_abbr
    -- Staging, not dim_game/dim_team: dim_game now denormalizes
    -- nflverse_game_id FROM this bridge, so reading the dims here would be a
    -- dependency cycle. The columns are identical -- both dims pass them
    -- through from staging unchanged.
    from {{ ref('stg_nfl__games') }} g
    inner join {{ ref('stg_nfl__teams') }} ht
        on ht.team_key = g.home_team_key
    inner join {{ ref('stg_nfl__teams') }} at
        on at.team_key = g.away_team_key

),

mapped as (

    select
        *,
        {{ nfl_team_abbr_nflverse('home_abbr') }}       as home_abbr_nflverse,
        {{ nfl_team_abbr_nflverse('away_abbr') }}       as away_abbr_nflverse,
        game_datetime_et::date                          as game_date_et,
        case
            when season_type = 1 then null                 -- preseason: no nflverse coverage
            when is_postseason then iff(week = 5, 22, 18 + week)
            else week
        end                                             as nflverse_week_composed
    from games

),

observed as (

    select distinct
        nflverse_game_id,
        season,
        week,
        home_team,
        away_team,
        game_date
    from {{ ref('stg_nfl__nflverse_pbp') }}

),

joined as (

    select
        m.*,
        o.nflverse_game_id                              as observed_nflverse_game_id,
        o.week                                          as observed_week,
        iff(
            m.nflverse_week_composed is null,
            null,
            m.season || '_' || lpad(m.nflverse_week_composed, 2, '0')
                || '_' || m.away_abbr_nflverse || '_' || m.home_abbr_nflverse
        )                                               as nflverse_game_id_composed
    from mapped m
    left join observed o
        on  o.season    = m.season
        and o.home_team = m.home_abbr_nflverse
        and o.away_team = m.away_abbr_nflverse
        and o.game_date = m.game_date_et

)

select
    game_key,
    game_id,
    coalesce(observed_nflverse_game_id, nflverse_game_id_composed)  as nflverse_game_id,
    nflverse_game_id_composed,
    observed_nflverse_game_id is not null               as is_nflverse_observed,
    season,
    week,
    coalesce(observed_week, nflverse_week_composed)     as nflverse_week,
    season_type,
    season_type_name,
    is_postseason,
    game_datetime,
    game_date,
    game_date_et,
    is_completed,
    home_team_key,
    home_team_id,
    home_abbr,
    home_abbr_nflverse,
    away_team_key,
    away_team_id,
    away_abbr,
    away_abbr_nflverse
from joined
