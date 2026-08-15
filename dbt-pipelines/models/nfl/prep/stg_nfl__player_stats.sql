{{
    config(
        materialized='view'
    )
}}

/*
    stg_nfl__player_stats -- player box score, one row per player per game.

    The widest source in the set: 116 columns spanning six phases of play.
    67,191 rows. Most columns are NULL for most rows -- a punter's row has
    nothing in the passing columns. fact_player_game_* splits this by phase.

    Two jobs here.

    1. Strip the flattened payload. dlt copied the entire game record, both
       teams, AND the player record into every row. Only game_id, team_id and
       player_id survive; the rest lives on the dimensions.

    2. Coalesce the dlt variant columns. Where the API returned an integer for
       some rows and a decimal for others (a half-sack, say), dlt split the
       field into <name> (NUMBER) and <name>__v_double (FLOAT). Verified
       mutually exclusive -- zero rows populate both -- so coalesce is
       lossless. Affects 5 fields; defensive_sacks alone has 41,233 integer
       rows and 1,032 decimal rows.

    team_id here is the team the player appeared for in THIS game, which makes
    it the only historically accurate team affiliation in the whole source.
*/

with source as (

    select * from {{ source('nfl_raw', 'stats') }}

),

renamed as (

    select
        -- grain: player x game
        {{ dbt_utils.generate_surrogate_key(['game__id', 'player__id']) }} as player_game_key,
        {{ dbt_utils.generate_surrogate_key(['game__id']) }}               as game_key,
        game__id                                                          as game_id,
        {{ dbt_utils.generate_surrogate_key(['player__id']) }}             as player_key,
        player__id                                                        as player_id,
        {{ dbt_utils.generate_surrogate_key(['team__id']) }}               as team_key,
        team__id                                                          as team_id,

        -- ---------------------------------------------------------------
        -- passing
        -- ---------------------------------------------------------------
        passing_completions,
        passing_attempts,
        passing_yards,
        coalesce(yards_per_pass_attempt::float, yards_per_pass_attempt__v_double)
                                                                          as yards_per_pass_attempt,
        passing_touchdowns,
        passing_interceptions,
        sacks                                                             as times_sacked,
        sacks_loss                                                        as sack_yards_lost,
        qb_rating,
        qbr,

        -- ---------------------------------------------------------------
        -- rushing
        -- ---------------------------------------------------------------
        rushing_attempts,
        rushing_yards,
        yards_per_rush_attempt,
        rushing_touchdowns,
        long_rushing,

        -- ---------------------------------------------------------------
        -- receiving
        -- ---------------------------------------------------------------
        receiving_targets,
        receptions,
        receiving_yards,
        coalesce(yards_per_reception::float, yards_per_reception__v_double)
                                                                          as yards_per_reception,
        receiving_touchdowns,
        long_reception,

        -- ---------------------------------------------------------------
        -- fumbles (offensive, but tracked for every phase)
        -- ---------------------------------------------------------------
        fumbles,
        fumbles_lost,
        fumbles_recovered,
        fumbles_touchdowns,

        -- ---------------------------------------------------------------
        -- defense
        -- ---------------------------------------------------------------
        total_tackles,
        solo_tackles,
        tackles_for_loss,
        coalesce(defensive_sacks::float, defensive_sacks__v_double)
                                                                          as defensive_sacks,
        qb_hits,
        passes_defended,
        defensive_interceptions,
        interception_yards,
        interception_touchdowns,

        -- ---------------------------------------------------------------
        -- kicking
        -- ---------------------------------------------------------------
        field_goal_attempts,
        field_goals_made,
        field_goal_pct,
        long_field_goal_made,
        extra_points_made,
        total_points                                                      as kicking_total_points,

        -- ---------------------------------------------------------------
        -- punting
        -- ---------------------------------------------------------------
        punts,
        punt_yards,
        gross_avg_punt_yards,
        touchbacks,
        punts_inside_20,
        long_punt,

        -- ---------------------------------------------------------------
        -- returns
        -- ---------------------------------------------------------------
        kick_returns,
        kick_return_yards,
        coalesce(yards_per_kick_return::float, yards_per_kick_return__v_double)
                                                                          as yards_per_kick_return,
        long_kick_return,
        kick_return_touchdowns,
        punt_returns,
        punt_return_yards,
        coalesce(yards_per_punt_return::float, yards_per_punt_return__v_double)
                                                                          as yards_per_punt_return,
        long_punt_return,
        punt_return_touchdowns,

        -- carried through so the fact_player_game_* phase facts can build
        -- incrementally
        _dlt_load_id

    from source

)

select * from renamed
