/*
    Reconcile fact_player_news_mention back to prep.

    The fact's resolution chain is five left joins and two QUALIFY dedupes, and
    each one is a place where a mention could silently disappear or double. So:
    every prep mention must land in the fact exactly once, and nothing in the
    fact may lack a prep mention. Row counts alone would not catch a mention
    dropped on one side and duplicated on another.

    A mention whose article is missing from stg_nfl__news_articles surfaces here
    too (the fact inner-joins articles), which is correct: the source
    relationship test says that cannot happen, and this is the second witness.
*/

with prep as (

    select mention_key
    from {{ ref('stg_nfl__news_player_mentions') }}

),

fact as (

    select mention_key, count(*) as fact_rows
    from {{ ref('fact_player_news_mention') }}
    group by mention_key

)

-- full outer join so missing rows on either side surface, not just duplicates
select
    coalesce(p.mention_key, f.mention_key) as mention_key,
    f.fact_rows
from prep p
full outer join fact f
    on p.mention_key = f.mention_key
where p.mention_key is null        -- in fact, not in prep
   or f.mention_key is null        -- in prep, missing from fact
   or f.fact_rows <> 1             -- duplicated by a join
