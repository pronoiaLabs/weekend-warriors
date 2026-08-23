{#
    assert_fact_nflverse_player_week_reconciles_to_raw -- nothing lost, nothing
    invented between RAW and the fact.

    Per season and season_type, the fact's row count must equal RAW minus the
    NULL-key rows the ingestion already logs (dropped in prep's WHERE). The
    union-both-directions shape of the other reconciliation tests collapsed
    to counts because the grain is identical: any mismatch means prep or the
    fact grew a filter it should not have.
#}

with raw_counts as (

    select season, season_type, count(*) as n_raw
    from {{ source('nfl_raw', 'nflverse_player_stats') }}
    where player_id is not null
    group by 1, 2

),

fact_counts as (

    select season, season_type, count(*) as n_fact
    from {{ ref('fact_nflverse_player_week') }}
    group by 1, 2

)

select
    coalesce(r.season, f.season)                        as season,
    coalesce(r.season_type, f.season_type)              as season_type,
    coalesce(r.n_raw, 0)                                as n_raw,
    coalesce(f.n_fact, 0)                               as n_fact
from raw_counts r
full outer join fact_counts f
    on f.season = r.season and f.season_type = r.season_type
where coalesce(r.n_raw, 0) != coalesce(f.n_fact, 0)
