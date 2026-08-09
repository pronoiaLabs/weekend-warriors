{{
    config(
        materialized='table'
    )
}}

/*
    dim_wnba_game -- descriptive context for each game, 333 rows. Grain: game.
    2026 season only, which is the whole coverage of the games source.

    NOT ALL 333 GAMES HAVE BEEN PLAYED, and that is the difference from
    dim_wnba_game on the NFL side. 240 rows are complete and 93 are still
    scheduled, through 2026-09-25. Of the 240 complete rows one is the
    postponed game 24935 on 2026-07-17, which carries STATUS 'post' with
    STATUS_STATE 'postponed' and no result.

    THE FINAL LINE IS CARRIED HERE. dim_wnba_game on the NFL side deliberately
    holds no scores, on the grounds that a score is a measure. This one does,
    because fact_wnba_team_game covers only the 239 games with a result: the 93
    scheduled rows and the postponed row have no fact at all, so dim_wnba_game is
    the only place a complete schedule can be read.

    THE POSTPONED ROW IS THE ONE TRAP IN THOSE SCORES. The 93 scheduled rows
    carry NULL, because stg_wnba__games nulls anything that is not STATUS
    'post' rather than passing through the source's fake 0-0. Game 24935 IS
    'post', so it keeps its 0-0 line and reads as a genuine scoreless draw.
    That is why has_result below is written over winner_team_id and not over
    the scores, and why anything aggregating home_team_score / away_team_score
    should filter on has_result first. Prefer fact_wnba_team_game for scoring
    analysis -- these columns answer "what is on the schedule and what has
    been played", not "who scores the most".

    winner_team_key is NULL for the 94 rows with no result. It is written as
    an explicit CASE rather than hashing winner_team_id directly, because
    generate_surrogate_key hashes a NULL into a real string and that value
    would fail the relationship to dim_wnba_team while looking like a team.

    season_type_name is a four-way classification derived upstream. Only
    'Regular Season' (332) and 'All-Star' (1) appear today; 'Postseason' and
    'Preseason' are legitimate members whose rows have not landed yet, so the
    accepted_values test lists all four.
*/

with games as (

    select * from {{ ref('stg_wnba__games') }}

)

select
    game_key,
    game_id,

    -- when. Both spellings of the same instant: UTC as loaded, and US
    -- Eastern for display. The schedule semantic view exposes only the ET one.
    game_datetime,
    game_datetime_et,
    game_date,
    {{ dbt_utils.generate_surrogate_key(['game_date']) }}    as date_key,
    season,
    season_type_name,
    is_postseason,

    -- state. game_status is the source's own label rather than a decoded
    -- enum, because a load can land while a game is in progress.
    game_status,
    game_state,
    is_completed,
    final_period,
    went_to_overtime,

    -- participants
    home_team_key,
    home_team_id,
    away_team_key,
    away_team_id,

    -- final line. NULL on the 93 scheduled rows; 0-0 on the postponed row,
    -- which is the source's line and not a real scoreless game.
    home_team_score,
    away_team_score,

    case
        when winner_team_id is null then null
        else {{ dbt_utils.generate_surrogate_key(['winner_team_id']) }}
    end                                                     as winner_team_key,
    winner_team_id,

    -- the filter fact_wnba_team_game applies, published so a consumer can line the
    -- two up without restating the rule
    (is_completed and winner_team_id is not null)           as has_result

from games
