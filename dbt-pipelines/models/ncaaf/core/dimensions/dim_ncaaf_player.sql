{{
    config(
        materialized='table'
    )
}}

/*
    dim_ncaaf_player -- player biographical attributes. Grain: player,
    124,089 rows, SCD1: the largest dimension in the account.

    CARRIES A CURRENT TEAM (the WNBA deviation, for the same reason): the
    source has no season-team history, so current team and stat-line team
    can disagree across transfers. Prefer fact_ncaaf_player_game.team_key
    and fact_ncaaf_player_season.team_key wherever the grain allows; the
    current team here is for "who does X play for" questions only.

    height_text stays text (a display string); weight and jersey cast to
    integers in prep, NULL where the source predates the columns.
*/

select
    player_key,
    player_id,
    first_name,
    last_name,
    full_name,
    position_name,
    position_abbreviation,
    height_text,
    weight_lbs,
    jersey_number,
    current_team_key,
    current_team_id,
    current_team_college,
    current_team_abbreviation
from {{ ref('stg_ncaaf__players') }}
