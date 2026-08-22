{{ config(severity='warn') }}

/*
    Watch the name-resolution rate.

    Over the last seven days of mentions, at least 75% of the ones that are
    actually about a person (team-name extractions excluded) should resolve to
    a player_key through alias, exact or exact_team. The first day of data
    resolved 78 of 86 by normalization alone, so 75% leaves room for a noisy
    extraction day without paging.

    WARN, never error: prod runs `dbt build`, and a bad day of extraction must
    not take the whole NFL build down with it. When this fires, the rows it
    returns are the rate and the most frequent unresolved names, which is the
    input to seeds/nfl/seed_nfl_player_aliases.csv: real nicknames get a row,
    coaches and retired players do not.
*/

with recent as (

    select resolution_method, player_name_text
    from {{ ref('fact_player_news_mention') }}
    where published_date >= current_date - 7
      and resolution_method <> 'team_not_player'

),

rate as (

    select
        count(*)                                                        as mentions,
        count_if(resolution_method in ('alias', 'exact', 'exact_team')) as resolved,
        count_if(resolution_method in ('alias', 'exact', 'exact_team'))
            / nullif(count(*), 0)                                       as resolved_share
    from recent

),

misses as (

    select player_name_text, count(*) as mention_count
    from recent
    where resolution_method in ('ambiguous', 'unresolved')
    group by player_name_text
    order by mention_count desc
    limit 20

)

select
    r.mentions,
    r.resolved,
    round(r.resolved_share, 3)  as resolved_share,
    m.player_name_text          as unresolved_name,
    m.mention_count
from rate r
left join misses m
    on true
where r.mentions > 0
  and r.resolved_share < 0.75
