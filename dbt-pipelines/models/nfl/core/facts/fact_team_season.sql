{{
    config(
        materialized='table'
    )
}}

/*
    fact_team_season -- final standings. Grain: team x season. 96 rows.

    32 teams x 3 seasons. Takes the current SCD2 version from the source.

    This is a snapshot fact: the measures are end-of-season states (final record,
    playoff seed) rather than events, which is why it is not additive across
    seasons. Summing wins here across seasons works; summing playoff_seed does
    not.

    Note the overlap with fact_team_game -- a team's record could be derived by
    aggregating win_count there. Both are kept because they answer different
    questions and can legitimately disagree: standings are the league's official
    record, while fact_team_game covers all season types and would need filtering
    to season_type = 2 to match. tests/assert_standings_reconcile_to_team_games.sql
    checks that they agree once that filter is applied.
*/

with standings as (

    select * from {{ ref('stg_nfl__standings') }}

)

select
    -- keys
    team_season_key,
    team_key,
    team_id,
    season,

    -- overall record
    wins,
    losses,
    ties,
    win_pct,
    wins + losses + ties            as games_played,

    -- scoring
    points_for,
    points_against,
    point_differential,

    -- per-game scoring, guarded against a zero-game season
    case
        when wins + losses + ties > 0
        then points_for::float / (wins + losses + ties)
    end                             as points_for_per_game,
    case
        when wins + losses + ties > 0
        then points_against::float / (wins + losses + ties)
    end                             as points_against_per_game,

    -- Split records. Ties are carried for each split, not just the overall
    -- record: "4-7-1" is 12 games, and dropping the tie makes any
    -- w/(w+l) rate calculation wrong.
    conference_wins,
    conference_losses,
    conference_ties,
    division_wins,
    division_losses,
    division_ties,
    home_wins,
    home_losses,
    home_ties,
    road_wins,
    road_losses,
    road_ties,

    -- postseason.
    --
    -- conference_rank is 1-16 and always populated -- it is what the source
    -- mislabels as playoff_seed. playoff_seed here is the real thing: the rank
    -- only where it is <= 7, NULL for teams that missed the postseason.
    conference_rank,
    playoff_seed,
    made_playoffs,
    win_streak

from standings
