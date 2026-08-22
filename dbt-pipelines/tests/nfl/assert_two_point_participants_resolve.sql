{{ config(severity='warn') }}

/*
    Watch the two-point name-resolution rate.

    A parsed participant that does not resolve to a player_key earns nobody
    the 2 points. The candidate set is the roster that appeared in that game
    for that team, so "initial + last name" should resolve nearly always; the
    first build is the baseline and 95% is the floor.

    WARN, never error: prod runs `dbt build`, and a provider spelling quirk
    must not take the NFL build down. The rows returned are the misses with
    their play text, which is the input to seeds/nfl/seed_nfl_player_aliases.csv
    or to a new regex case in fact_two_point_conversion.
*/

with participants as (

    select resolution_method, participant_text, team_id, game_id, play_description
    from {{ ref('fact_two_point_conversion') }}
    where is_success
      and role <> 'unparsed'

),

rate as (

    select
        count(*)                                                            as participants,
        count_if(resolution_method in ('exact', 'exact_role', 'alias', 'team_roster'))
                                                                            as resolved,
        count_if(resolution_method in ('exact', 'exact_role', 'alias', 'team_roster'))
            / nullif(count(*), 0)                                           as resolved_share
    from participants

),

misses as (

    select participant_text, team_id, game_id, resolution_method, play_description
    from participants
    where resolution_method in ('ambiguous', 'unresolved')

)

select
    r.participants,
    r.resolved,
    round(r.resolved_share, 3)  as resolved_share,
    m.participant_text,
    m.resolution_method,
    m.team_id,
    m.game_id,
    m.play_description
from rate r
left join misses m
    on true
where r.participants > 0
  and r.resolved_share < 0.95
