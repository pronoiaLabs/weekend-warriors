/*
    Guard the five-way inner join behind fact_wnba_player_season_advanced.

    That fact joins stg_wnba__player_season_{advanced, misc, scoring, usage,
    defense} on (player_id, season) with INNER joins, which is only honest
    because all five cover an identical population: 224 rows each, and a
    five-way inner join returning 224. Verified in prod before the fact was
    written, and true of every one of the five pairwise overlaps. It is the
    same 100% overlap that lets sv_wnba_player_advanced ship enabled where its
    NFL counterpart could not.

    THE FAILURE MODE THIS EXISTS FOR IS SILENT. If a future load leaves one of
    the five short a player -- a rookie signed after that endpoint was read, a
    traded player the defense feed has not caught up with -- the inner join
    simply returns fewer rows. Nothing errors. No column goes NULL. The fact
    just quietly stops describing a player who is present in four of her five
    sources, and every downstream count is off by one with no signal.

    A left join from advanced would trade that for a different silence: the
    player would survive with a block of NULL columns, and an AVG over her
    would be computed on a smaller population than the one it claims. The inner
    join plus this test is the version that makes the problem loud, and this
    test is the price of choosing it.

    The row count of stg_wnba__player_season_advanced is the reference, since
    advanced is the spine of the join. The other four are checked against it
    too, so a failure names WHICH endpoint fell behind rather than only that
    one did. Deliberately asserted as equality in both directions: a source
    growing past the fact matters as much as one shrinking below it.
*/

with source_counts as (

    select 'player_season_advanced' as source_model, count(*) as n
    from {{ ref('stg_wnba__player_season_advanced') }}
    union all
    select 'player_season_misc',     count(*)
    from {{ ref('stg_wnba__player_season_misc') }}
    union all
    select 'player_season_scoring',  count(*)
    from {{ ref('stg_wnba__player_season_scoring') }}
    union all
    select 'player_season_usage',    count(*)
    from {{ ref('stg_wnba__player_season_usage') }}
    union all
    select 'player_season_defense',  count(*)
    from {{ ref('stg_wnba__player_season_defense') }}

),

fact_count as (

    select count(*) as n from {{ ref('fact_wnba_player_season_advanced') }}

)

select
    s.source_model,
    s.n         as source_rows,
    f.n         as fact_rows,
    s.n - f.n   as rows_lost_by_the_inner_join
from source_counts s
cross join fact_count f
where s.n <> f.n
