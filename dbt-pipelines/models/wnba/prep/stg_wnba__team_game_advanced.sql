{{
    config(
        materialized='view'
    )
}}

/*
    stg_wnba__team_game_advanced -- advanced team box score.

    Grain: team x game. 466 rows, 94 source columns, flattened to 74 metrics.

    Same five-group nesting as stg_wnba__player_game_advanced
    (STATS__FOUR_FACTORS__ / __ADVANCED__ / __SCORING__ / __USAGE__ /
    __MISC__), stripped the same way, so the two models share a vocabulary
    and the core layer can compare a player against her team without a
    translation table.

    THE COLLISIONS RESOLVE DIFFERENTLY HERE, which is the reason to check
    rather than copy the player model's decisions:

      * MINUTES, in all five groups, identical on all 466 rows. One column,
        parsed. It reads '199:48' at the team level (five players on the
        floor), not '34:48', and wnba_parse_minutes handles both.
      * OFFENSIVE_REBOUND_PERCENTAGE (FOUR_FACTORS and ADVANCED): identical
        on all 466 rows, so the FOUR_FACTORS copy is dropped.
      * EFFECTIVE_FIELD_GOAL_PERCENTAGE (FOUR_FACTORS and ADVANCED):
        identical on all 466 rows, so the FOUR_FACTORS copy is dropped. On
        the PLAYER table these two disagree on 4,469 of 5,569 rows and both
        had to be kept. A team has no on-court context distinct from itself,
        which is why the duplication collapses at this grain.
      * USAGE_PERCENTAGE (ADVANCED and USAGE): identical on all 466 rows,
        so the USAGE copy is dropped.

    TEAM_TURNOVER_PERCENTAGE (FOUR_FACTORS) and
    ESTIMATED_TEAM_TURNOVER_PERCENTAGE (ADVANCED) look like a fourth
    collision and are not one: they differ on all 466 rows, which is what
    "estimated" is supposed to mean. Both are kept.

    No variant twins: sources.yml lists none and INFORMATION_SCHEMA confirms
    zero __V_DOUBLE columns on this table, so nothing is folded.

    PERIOD is 0 on every row and ID is a load artifact; both are dropped, as
    is the flattened GAME__ / TEAM__ payload beyond its keys.
*/

with source as (

    select * from {{ source('wnba_raw', 'team_game_advanced_stats') }}

),

renamed as (

    select
        -- grain: team x game
        {{ dbt_utils.generate_surrogate_key(['game__id', 'team__id']) }}
                                                            as team_game_advanced_key,
        {{ dbt_utils.generate_surrogate_key(['game__id']) }} as game_key,
        game__id                                            as game_id,
        {{ dbt_utils.generate_surrogate_key(['team__id']) }} as team_key,
        team__id                                            as team_id,

        -- degenerate game attributes, carried so this model can be read alone
        game__date::date                                    as game_date,
        game__season                                        as season,

        -- 'MMM:SS' upstream, identical in all five stat groups
        {{ wnba_parse_minutes('stats__advanced__minutes') }}
                                                            as minutes_played,

        -- ---------------------------------------------------------------
        -- four factors -- the team's own rates plus the opponent's.
        -- eFG and offensive rebound rate live in the advanced block below.
        -- ---------------------------------------------------------------
        stats__four_factors__free_throw_attempt_rate        as free_throw_attempt_rate,
        stats__four_factors__team_turnover_percentage       as team_turnover_pct,
        stats__four_factors__opp_free_throw_attempt_rate    as opp_free_throw_attempt_rate,
        stats__four_factors__opp_team_turnover_percentage   as opp_team_turnover_pct,
        stats__four_factors__opp_offensive_rebound_percentage
                                                            as opp_offensive_rebound_pct,
        stats__four_factors__opp_effective_field_goal_percentage
                                                            as opp_effective_field_goal_pct,

        -- ---------------------------------------------------------------
        -- advanced
        -- ---------------------------------------------------------------
        stats__advanced__pie                                as pie,
        stats__advanced__pace                               as pace,
        stats__advanced__pace_per40                         as pace_per40,
        stats__advanced__estimated_pace                     as estimated_pace,
        stats__advanced__possessions                        as possessions,
        stats__advanced__offensive_rating                   as offensive_rating,
        stats__advanced__defensive_rating                   as defensive_rating,
        stats__advanced__net_rating                         as net_rating,
        stats__advanced__estimated_offensive_rating         as estimated_offensive_rating,
        stats__advanced__estimated_defensive_rating         as estimated_defensive_rating,
        stats__advanced__estimated_net_rating               as estimated_net_rating,
        stats__advanced__assist_ratio                       as assist_ratio,
        stats__advanced__assist_percentage                  as assist_pct,
        stats__advanced__assist_to_turnover                 as assist_to_turnover,
        stats__advanced__turnover_ratio                     as turnover_ratio,
        stats__advanced__estimated_team_turnover_percentage as estimated_team_turnover_pct,
        stats__advanced__rebound_percentage                 as rebound_pct,
        stats__advanced__defensive_rebound_percentage       as defensive_rebound_pct,
        stats__advanced__offensive_rebound_percentage       as offensive_rebound_pct,
        stats__advanced__usage_percentage                   as usage_pct,
        stats__advanced__estimated_usage_percentage         as estimated_usage_pct,
        stats__advanced__true_shooting_percentage           as true_shooting_pct,
        stats__advanced__effective_field_goal_percentage    as effective_field_goal_pct,

        -- ---------------------------------------------------------------
        -- scoring
        -- ---------------------------------------------------------------
        stats__scoring__percentage_points2pt                as points_2pt_pct,
        stats__scoring__percentage_points3pt                as points_3pt_pct,
        stats__scoring__percentage_points_paint             as points_paint_pct,
        stats__scoring__percentage_points_midrange2pt       as points_midrange_2pt_pct,
        stats__scoring__percentage_points_free_throw        as points_free_throw_pct,
        stats__scoring__percentage_points_fast_break        as points_fast_break_pct,
        stats__scoring__percentage_points_off_turnovers     as points_off_turnovers_pct,
        stats__scoring__percentage_assisted2pt              as assisted_2pt_pct,
        stats__scoring__percentage_assisted3pt              as assisted_3pt_pct,
        stats__scoring__percentage_assisted_fgm             as assisted_fgm_pct,
        stats__scoring__percentage_unassisted2pt            as unassisted_2pt_pct,
        stats__scoring__percentage_unassisted3pt            as unassisted_3pt_pct,
        stats__scoring__percentage_unassisted_fgm           as unassisted_fgm_pct,
        stats__scoring__percentage_field_goals_attempted2pt as field_goals_attempted_2pt_pct,
        stats__scoring__percentage_field_goals_attempted3pt as field_goals_attempted_3pt_pct,

        -- ---------------------------------------------------------------
        -- usage -- shares that sum to the team, so every value here is
        -- near 1 at this grain. Kept for symmetry with the player model.
        -- ---------------------------------------------------------------
        stats__usage__percentage_points                     as points_pct,
        stats__usage__percentage_assists                    as assists_pct,
        stats__usage__percentage_turnovers                  as turnovers_pct,
        stats__usage__percentage_steals                     as steals_pct,
        stats__usage__percentage_blocks                     as blocks_pct,
        stats__usage__percentage_blocks_allowed             as blocks_allowed_pct,
        stats__usage__percentage_personal_fouls             as personal_fouls_pct,
        stats__usage__percentage_personal_fouls_drawn       as personal_fouls_drawn_pct,
        stats__usage__percentage_rebounds_total             as rebounds_total_pct,
        stats__usage__percentage_rebounds_defensive         as rebounds_defensive_pct,
        stats__usage__percentage_rebounds_offensive         as rebounds_offensive_pct,
        stats__usage__percentage_field_goals_made           as field_goals_made_pct,
        stats__usage__percentage_field_goals_attempted      as field_goals_attempted_pct,
        stats__usage__percentage_free_throws_made           as free_throws_made_pct,
        stats__usage__percentage_free_throws_attempted      as free_throws_attempted_pct,
        stats__usage__percentage_three_pointers_made        as three_pointers_made_pct,
        stats__usage__percentage_three_pointers_attempted   as three_pointers_attempted_pct,

        -- ---------------------------------------------------------------
        -- misc
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
