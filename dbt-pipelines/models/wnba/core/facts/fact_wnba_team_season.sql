{{
    config(
        materialized='table'
    )
}}

/*
    fact_wnba_team_season -- final standings. Grain: team x season. 235 rows.

    THIS IS THE ONLY MULTI-YEAR FACT IN THE WNBA SET. 17 franchises across the
    19 seasons from 2008 to 2026; every other WNBA source is 2026 only. It is
    therefore the one place a year-over-year question can be answered at all,
    and the reason the defunct Monarchs and Comets survive in dim_wnba_team. Row
    counts per season are uneven (12 teams in 2024, 13 in 2025, 15 in 2026)
    because the league expanded, so a "per team" average has to divide by that
    season's team count and not by 15.

    A snapshot fact, exactly like the NFL one: the measures are the state of
    the record at the moment the standings endpoint was read, not events. Wins
    sums across seasons; playoff_seed does not.

    THE 2026 ROW IS MID-SEASON AND TRAILS THE GAME LOG. The snapshot was taken
    at 2026-08-08 23:59 UTC, while games keep landing daily, so aggregating
    fact_wnba_team_game gives a team up to two more decided games than this fact
    reports. That gap is expected, bounded and measured in
    tests/wnba/assert_wnba_standings_reconcile_to_team_games.sql, which is the
    place to look before treating a disagreement as a bug.

    NO POINTS FOR OR AGAINST. The NFL standings source carries them and this
    one does not, so the NFL fact's points_for / points_against /
    point_differential columns have no counterpart here. Scoring at season
    grain comes from fact_wnba_team_season_advanced (2026 only) or by aggregating
    fact_wnba_team_game.

    win_pct is the source's own value, three decimal places, passed through so
    the source stays authoritative on its rounding. win_pct_computed is the
    same ratio at full precision from the components. Both are 0-1 fractions,
    matching NFL fact_wnba_team_season.win_pct and every other rate in the WNBA
    core layer.

    NO made_playoffs FLAG, deliberately. playoff_seed here is a real conference
    seed running 1 to 8 and populated on every row, unlike the NFL source's
    column of the same name -- so unlike NFL there is nothing to repair. But
    deriving qualification from it would need a cutoff, and the WNBA has
    changed the size and shape of its playoff field several times over the 19
    seasons covered. A single hardcoded threshold would be wrong for most of
    them, so the seed is published and the cutoff is left to the caller.

    The split records are already parsed out of their "11-6" text by
    wnba_parse_record in prep. Basketball has no ties, so unlike the NFL fact
    there is no third component to carry.
*/

with standings as (

    select * from {{ ref('stg_wnba__standings') }}

)

select
    -- keys
    team_season_key,
    team_key,
    team_id,
    season,

    -- where the team sat in the league that season. Historically accurate:
    -- prep takes the conference from the standings row, not from dim_wnba_team,
    -- which knows only the current one.
    conference,

    -- overall record
    wins,
    losses,
    games_played,

    -- The source's own three-decimal value, renamed from win_percentage to
    -- match NFL fact_wnba_team_season. Already a 0-1 fraction.
    win_percentage                      as win_pct,
    win_pct_computed,

    -- Split records. No tie component -- see header.
    home_wins,
    home_losses,
    away_wins,
    away_losses,
    conference_wins,
    conference_losses,

    -- position
    --
    -- playoff_seed is a conference seed, 1-8, populated for every row. It is
    -- NOT a qualification flag; see the header on why none is derived.
    playoff_seed,
    games_behind

from standings
