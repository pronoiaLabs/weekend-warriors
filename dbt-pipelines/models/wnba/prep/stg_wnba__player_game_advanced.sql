{{
    config(
        materialized='view'
    )
}}

/*
    stg_wnba__player_game_advanced -- advanced player box score.

    Grain: player x game. 5,569 rows, 124 source columns.

    The source nests every metric under one of five group prefixes:
    STATS__FOUR_FACTORS__, STATS__ADVANCED__, STATS__SCORING__,
    STATS__USAGE__, STATS__MISC__. The prefixes are an artifact of the API
    response shape, not a business distinction, so they are stripped here and
    74 metric columns come out flat. PERCENTAGE / _PCT endings normalize to a
    _pct suffix.

    THREE NAME COLLISIONS BETWEEN GROUPS. Each was resolved by measuring
    agreement first, not by assuming the groups repeat themselves.

    1. MINUTES appears in all five groups. Verified byte-identical across all
       four pairs on all 5,569 rows, so one column survives. It is 'MM:SS'
       text upstream and is parsed to fractional minutes here.

    2. OFFENSIVE_REBOUND_PERCENTAGE appears under FOUR_FACTORS and ADVANCED.
       Verified identical on all 5,569 rows once both variant twins are
       folded, so the ADVANCED copy survives as offensive_rebound_pct and the
       FOUR_FACTORS duplicate (and its twin) is dropped.

    3. EFFECTIVE_FIELD_GOAL_PERCENTAGE appears under FOUR_FACTORS and
       ADVANCED and they are NOT the same number: they differ on 4,469 of
       5,569 rows, both non-null throughout. The FOUR_FACTORS value also
       fails to match this player's team row in team_game_advanced_stats
       (44 of 5,569 match), so it is neither the player's own rate nor a
       copied team total -- it is the four-factors context around the player,
       consistent with the OPP_* columns sitting beside it in that group.
       Both are kept and the FOUR_FACTORS one keeps its group qualifier.

    PERIOD is 0 on every row (whole game, no quarter splits) and is dropped
    as a constant. ID is a per-row load artifact with no business meaning and
    is dropped too. The GAME__ / TEAM__ / PLAYER__ payloads dlt flattened into
    every row are stripped to their keys, plus game_date and season as
    degenerate attributes.

    Variant twins: sources.yml registers 15. Fourteen are folded below; the
    fifteenth belongs to the dropped FOUR_FACTORS rebound duplicate above.
*/

with source as (

    select * from {{ source('wnba_raw', 'player_game_advanced_stats') }}

),

renamed as (

    select
        -- grain: player x game
        {{ dbt_utils.generate_surrogate_key(['game__id', 'player__id']) }}
                                                            as player_game_advanced_key,
        {{ dbt_utils.generate_surrogate_key(['game__id']) }} as game_key,
        game__id                                            as game_id,
        {{ dbt_utils.generate_surrogate_key(['player__id']) }}
                                                            as player_key,
        player__id                                          as player_id,
        {{ dbt_utils.generate_surrogate_key(['team__id']) }} as team_key,
        team__id                                            as team_id,

        -- degenerate game attributes, carried so this model can be read alone
        game__date::date                                    as game_date,
        game__season                                        as season,

        -- 'MM:SS' upstream, identical in all five stat groups
        {{ wnba_parse_minutes('stats__advanced__minutes') }}
                                                            as minutes_played,

        -- ---------------------------------------------------------------
        -- four factors -- context around the player, including the
        -- opponent's side. See header note 3 on the eFG qualifier.
        -- ---------------------------------------------------------------
        stats__four_factors__free_throw_attempt_rate        as free_throw_attempt_rate,
        stats__four_factors__team_turnover_percentage       as team_turnover_pct,
        stats__four_factors__effective_field_goal_percentage
                                                            as four_factors_effective_field_goal_pct,
        stats__four_factors__opp_free_throw_attempt_rate    as opp_free_throw_attempt_rate,
        stats__four_factors__opp_team_turnover_percentage   as opp_team_turnover_pct,
        stats__four_factors__opp_offensive_rebound_percentage
                                                            as opp_offensive_rebound_pct,
        stats__four_factors__opp_effective_field_goal_percentage
                                                            as opp_effective_field_goal_pct,

        -- ---------------------------------------------------------------
        -- advanced -- the player's own efficiency and rate stats
        -- ---------------------------------------------------------------
        stats__advanced__pie                                as pie,
        stats__advanced__pace                               as pace,
        stats__advanced__pace_per40                         as pace_per40,
        stats__advanced__estimated_pace                     as estimated_pace,
        stats__advanced__possessions                        as possessions,
        stats__advanced__offensive_rating                   as offensive_rating,
        stats__advanced__defensive_rating                   as defensive_rating,
        {{ wnba_coalesce_variant('stats__advanced__net_rating') }}
                                                            as net_rating,
        stats__advanced__estimated_offensive_rating         as estimated_offensive_rating,
        stats__advanced__estimated_defensive_rating         as estimated_defensive_rating,
        {{ wnba_coalesce_variant('stats__advanced__estimated_net_rating') }}
                                                            as estimated_net_rating,
        stats__advanced__assist_ratio                       as assist_ratio,
        stats__advanced__assist_percentage                  as assist_pct,
        {{ wnba_coalesce_variant('stats__advanced__assist_to_turnover') }}
                                                            as assist_to_turnover,
        stats__advanced__turnover_ratio                     as turnover_ratio,
        stats__advanced__rebound_percentage                 as rebound_pct,
        stats__advanced__defensive_rebound_percentage       as defensive_rebound_pct,
        {{ wnba_coalesce_variant('stats__advanced__offensive_rebound_percentage') }}
                                                            as offensive_rebound_pct,
        stats__advanced__usage_percentage                   as usage_pct,
        stats__advanced__estimated_usage_percentage         as estimated_usage_pct,
        stats__advanced__true_shooting_percentage           as true_shooting_pct,
        stats__advanced__effective_field_goal_percentage    as effective_field_goal_pct,

        -- ---------------------------------------------------------------
        -- scoring -- how the player's points and shots were distributed
        -- ---------------------------------------------------------------
        stats__scoring__percentage_points2pt                as points_2pt_pct,
        {{ wnba_coalesce_variant('stats__scoring__percentage_points3pt') }}
                                                            as points_3pt_pct,
        stats__scoring__percentage_points_paint             as points_paint_pct,
        stats__scoring__percentage_points_midrange2pt       as points_midrange_2pt_pct,
        stats__scoring__percentage_points_free_throw        as points_free_throw_pct,
        {{ wnba_coalesce_variant('stats__scoring__percentage_points_fast_break') }}
                                                            as points_fast_break_pct,
        stats__scoring__percentage_points_off_turnovers     as points_off_turnovers_pct,
        stats__scoring__percentage_assisted2pt              as assisted_2pt_pct,
        {{ wnba_coalesce_variant('stats__scoring__percentage_assisted3pt') }}
                                                            as assisted_3pt_pct,
        stats__scoring__percentage_assisted_fgm             as assisted_fgm_pct,
        stats__scoring__percentage_unassisted2pt            as unassisted_2pt_pct,
        {{ wnba_coalesce_variant('stats__scoring__percentage_unassisted3pt') }}
                                                            as unassisted_3pt_pct,
        stats__scoring__percentage_unassisted_fgm           as unassisted_fgm_pct,
        stats__scoring__percentage_field_goals_attempted2pt as field_goals_attempted_2pt_pct,
        stats__scoring__percentage_field_goals_attempted3pt as field_goals_attempted_3pt_pct,

        -- ---------------------------------------------------------------
        -- usage -- the player's share of the team's activity.
        -- USAGE_PERCENTAGE is dropped here: verified identical to
        -- STATS__ADVANCED__USAGE_PERCENTAGE on all 5,569 rows.
        -- ---------------------------------------------------------------
        stats__usage__percentage_points                     as points_pct,
        stats__usage__percentage_assists                    as assists_pct,
        stats__usage__percentage_turnovers                  as turnovers_pct,
        {{ wnba_coalesce_variant('stats__usage__percentage_steals') }}
                                                            as steals_pct,
        {{ wnba_coalesce_variant('stats__usage__percentage_blocks') }}
                                                            as blocks_pct,
        {{ wnba_coalesce_variant('stats__usage__percentage_blocks_allowed') }}
                                                            as blocks_allowed_pct,
        {{ wnba_coalesce_variant('stats__usage__percentage_personal_fouls') }}
                                                            as personal_fouls_pct,
        stats__usage__percentage_personal_fouls_drawn       as personal_fouls_drawn_pct,
        stats__usage__percentage_rebounds_total             as rebounds_total_pct,
        stats__usage__percentage_rebounds_defensive         as rebounds_defensive_pct,
        {{ wnba_coalesce_variant('stats__usage__percentage_rebounds_offensive') }}
                                                            as rebounds_offensive_pct,
        stats__usage__percentage_field_goals_made           as field_goals_made_pct,
        stats__usage__percentage_field_goals_attempted      as field_goals_attempted_pct,
        stats__usage__percentage_free_throws_made           as free_throws_made_pct,
        stats__usage__percentage_free_throws_attempted      as free_throws_attempted_pct,
        {{ wnba_coalesce_variant('stats__usage__percentage_three_pointers_made') }}
                                                            as three_pointers_made_pct,
        stats__usage__percentage_three_pointers_attempted   as three_pointers_attempted_pct,

        -- ---------------------------------------------------------------
        -- misc -- counting stats the basic box score does not carry
        -- ---------------------------------------------------------------
        stats__misc__blocks                                 as blocks,
        stats__misc__blocks_against                         as blocks_against,
        stats__misc__fouls_personal                         as fouls_personal,
        stats__misc__fouls_drawn                            as fouls_drawn,
        stats__misc__points_paint                           as points_paint,
        stats__misc__points_fast_break                      as points_fast_break,
        stats__misc__points_off_turnovers                   as points_off_turnovers,
        stats__misc__points_second_chance                   as points_second_chance,
        stats__misc__opp_points_paint                       as opp_points_paint,
        stats__misc__opp_points_fast_break                  as opp_points_fast_break,
        stats__misc__opp_points_off_turnovers               as opp_points_off_turnovers,
        stats__misc__opp_points_second_chance               as opp_points_second_chance

    from source

)

select * from renamed
