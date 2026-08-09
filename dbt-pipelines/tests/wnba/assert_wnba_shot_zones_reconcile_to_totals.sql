/*
    Guard the shot-location unpivots.

    fact_wnba_team_season_shooting and fact_wnba_player_season_shooting each turn a wide,
    pivoted source into one row per location, and each drops the source's
    CORNER_3 column on the way because it is LEFT_CORNER_3 + RIGHT_CORNER_3
    rather than an eighth zone. Two things can go wrong and neither changes the
    row count: a location can be omitted from the UNION ALL, and corner_3 can
    be left in. Both show up as a wrong total attempt count, so that is what is
    checked.

    CHECK 1: THE TWO SCHEMES MUST AGREE WITH EACH OTHER.

    'zone' cuts the season's shots by court region and 'distance_5ft' cuts the
    same shots by feet from the basket. They are two views of one population,
    so their attempt totals must be identical per entity per season. Measured
    read-only: identical for all 15 teams and all 223 players, to the attempt.
    This is the check that catches a dropped location, since dropping one from
    either scheme breaks the equality. It also catches corner_3 surviving,
    which would inflate the zone scheme by the number of corner threes.

    CHECK 2: THE PLAYER ZONE TOTAL MUST EQUAL THE SEASON TOTAL FGA.

    fact_wnba_player_season_advanced.field_goals_attempted is a true season total
    from a different endpoint, and it equals the zone sum exactly for all 223
    players. That is an external anchor rather than an internal identity, so it
    catches an error the two schemes could share -- both being built from the
    same misread source row, for instance.

    WHY THERE IS NO EQUIVALENT ANCHOR FOR TEAMS, which is the honest answer to
    "compare against the season stats source". There is none to compare
    against. stg_wnba__team_season_advanced carries no FGA column at all, and
    stg_wnba__team_season_stats carries only a PER-GAME average rounded to one
    decimal place. Reconstructing a total from it is doubly unsafe: the
    rounding alone allows a few attempts of drift, and worse, that endpoint's
    games_played disagrees with the advanced family on 4 of 15 teams, so for
    teams 7 and 8 the reconstructed total is off by a whole game -- 76 and 68
    attempts respectively. Asserting on that would encode a snapshot timing
    difference as a shooting error. Teams therefore get check 1 only, which is
    exact, and the reason is recorded here so the gap reads as a decision
    rather than an oversight.

    POPULATION. Check 2 is an inner join on (player_id, season) and covers 223
    of the 224 players in the advanced fact. The missing one has no
    shot-location row at all, which is source coverage rather than a join loss,
    so it is out of scope here instead of being a permanent failure. Coverage
    of the advanced family itself is guarded by
    assert_wnba_advanced_family_is_complete.
*/

with team_by_scheme as (

    select
        team_id,
        season,
        sum(case when zone_scheme = 'zone'         then fga end) as zone_fga,
        sum(case when zone_scheme = 'distance_5ft' then fga end) as distance_fga
    from {{ ref('fact_wnba_team_season_shooting') }}
    group by team_id, season

),

player_by_scheme as (

    select
        player_id,
        season,
        sum(case when zone_scheme = 'zone'         then fga end) as zone_fga,
        sum(case when zone_scheme = 'distance_5ft' then fga end) as distance_fga
    from {{ ref('fact_wnba_player_season_shooting') }}
    group by player_id, season

),

scheme_failures as (

    select
        'schemes_disagree'          as issue,
        'team'                      as entity_type,
        team_id                     as entity_id,
        season,
        zone_fga,
        distance_fga                as comparison_fga
    from team_by_scheme
    where zone_fga is distinct from distance_fga

    union all

    select
        'schemes_disagree',
        'player',
        player_id,
        season,
        zone_fga,
        distance_fga
    from player_by_scheme
    where zone_fga is distinct from distance_fga

),

player_total_failures as (

    select
        'zone_total_disagrees_with_season_fga'  as issue,
        'player'                                as entity_type,
        p.player_id                             as entity_id,
        p.season,
        p.zone_fga,
        a.field_goals_attempted                 as comparison_fga
    from player_by_scheme p
    inner join {{ ref('fact_wnba_player_season_advanced') }} a
        on  p.player_id = a.player_id
       and  p.season    = a.season
    where p.zone_fga is distinct from a.field_goals_attempted

)

select * from scheme_failures
union all
select * from player_total_failures
