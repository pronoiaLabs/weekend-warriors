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

    Note the overlap with fact_team_game_offense -- a team's record could be derived by
    aggregating win_count there. Both are kept because they answer different
    questions and can legitimately disagree: standings are the league's official
    record, while fact_team_game_offense covers all season types and would need filtering
    to season_type = 2 to match. tests/assert_standings_reconcile_to_team_games.sql
    checks that they agree once that filter is applied.

    bye_week is derived from dim_game, not a source column: the missing week
    in the team's regular-season slate. Verified exact -- every season yields
    precisely 32 byes, one per team, weeks 5-14, each landing on an existing
    row here. Because dim_game holds the full slate including future games,
    an upcoming season's byes are already populated before a snap is played.
*/

with standings as (

    select * from {{ ref('stg_nfl__standings') }}

),

-- Regular-season slate flattened to team x week, then the bye falls out as
-- the week the team does not appear in.
team_weeks as (

    select season, week, home_team_key as team_key
    from {{ ref('dim_game') }}
    where season_type = 2
    union
    select season, week, away_team_key
    from {{ ref('dim_game') }}
    where season_type = 2

),

byes as (

    select
        t.season,
        t.team_key,
        min(w.week)                                     as bye_week
    from (select distinct season, team_key from team_weeks) t
    inner join (select distinct season, week from team_weeks) w
        on w.season = t.season
    left join team_weeks tw
        on  tw.season   = t.season
        and tw.team_key = t.team_key
        and tw.week     = w.week
    where tw.team_key is null
    group by 1, 2

)

select
    -- keys
    s.team_season_key,
    s.team_key,
    s.team_id,
    s.season,

    -- overall record
    s.wins,
    s.losses,
    s.ties,
    s.win_pct,
    s.wins + s.losses + s.ties      as games_played,

    -- scoring
    s.points_for,
    s.points_against,
    s.point_differential,

    -- per-game scoring, guarded against a zero-game season
    case
        when s.wins + s.losses + s.ties > 0
        then s.points_for::float / (s.wins + s.losses + s.ties)
    end                             as points_for_per_game,
    case
        when s.wins + s.losses + s.ties > 0
        then s.points_against::float / (s.wins + s.losses + s.ties)
    end                             as points_against_per_game,

    -- Split records. Ties are carried for each split, not just the overall
    -- record: "4-7-1" is 12 games, and dropping the tie makes any
    -- w/(w+l) rate calculation wrong.
    s.conference_wins,
    s.conference_losses,
    s.conference_ties,
    s.division_wins,
    s.division_losses,
    s.division_ties,
    s.home_wins,
    s.home_losses,
    s.home_ties,
    s.road_wins,
    s.road_losses,
    s.road_ties,

    -- postseason.
    --
    -- conference_rank is 1-16 and always populated -- it is what the source
    -- mislabels as playoff_seed. playoff_seed here is the real thing: the rank
    -- only where it is <= 7, NULL for teams that missed the postseason.
    s.conference_rank,
    s.playoff_seed,
    s.made_playoffs,
    s.win_streak,

    -- the missing week in the team's regular-season slate (see header)
    b.bye_week

from standings s
left join byes b
    on  b.team_key = s.team_key
    and b.season   = s.season
