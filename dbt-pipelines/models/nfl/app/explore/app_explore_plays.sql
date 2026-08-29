{{
    config(
        materialized='table'
    )
}}

/*
    app_explore_plays -- the Explorer's play sheet, the v1 play log.

    One row per play from app_play_log, the flat twin of the Play Log page:
    situation, the call, the involved players by name, EPA and the outcome,
    with drive context on matched plays. The play-by-play escape hatch --
    it stays as the page's flat twin after the pattern room ships. Largest
    sheet by far (~182k rows); the page seeds a current-season filter chip.
*/

select
    play_key                                            as row_id,
    season,
    season_type_name                                    as season_type,
    week,
    game_date,
    team_label                                          as team,
    opponent_label                                      as opponent,
    is_home_possession                                  as is_home,
    quarter,
    clock_display                                       as clock,
    down,
    distance,
    yards_to_endzone,
    down_bucket,
    distance_bucket,
    field_zone,
    game_script                                         as script,
    is_red_zone,
    is_third_down,
    is_two_minute,
    shotgun,
    no_huddle,
    play_type,
    play_category,
    play_family,
    pass_length,
    pass_location,
    run_gap,
    passer_name                                         as passer,
    rusher_name                                         as rusher,
    receiver_name                                       as receiver,
    yards_gained,
    epa,
    wpa,
    success,
    achieved_first_down                                 as first_down,
    is_touchdown,
    is_scoring_play,
    drive_number,
    play_in_drive,
    drive_result,
    play_description                                    as description,
    has_nflverse
from {{ ref('app_play_log') }}
