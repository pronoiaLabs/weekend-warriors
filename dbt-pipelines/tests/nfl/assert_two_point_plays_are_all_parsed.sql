/*
    Every successful two-point conversion in the play text is parsed.

    fact_two_point_conversion turns free text into credited players with two
    regex families (GSIS and ESPN formats). A phrasing the patterns do not
    know would not error; it would land as role 'unparsed' and the conversion
    would silently leave fanduel_points. This test makes that loud: every play
    whose text says the attempt succeeded must have at least one parsed
    participant row.

    Success is decided by the shared nfl_two_point_success macro, the same
    expression the fact uses, so the fact and this guard cannot drift apart;
    it reads the OFFENSIVE attempt only (a defensive two-point return also ends
    "ATTEMPT SUCCEEDS" and credits nobody on offense). The flip side: a new
    third text format would be invisible to both. If the provider changes the
    text, widen the macro.
*/

with scoring_plays as (

    select play_key, play_description
    from {{ ref('stg_nfl__plays') }}
    where {{ nfl_two_point_success('play_description') }}

),

parsed as (

    select play_key, count_if(role <> 'unparsed') as parsed_rows
    from {{ ref('fact_two_point_conversion') }}
    where is_success
    group by play_key

)

select
    s.play_key,
    s.play_description,
    coalesce(p.parsed_rows, 0) as parsed_rows
from scoring_plays s
left join parsed p
    on s.play_key = p.play_key
where coalesce(p.parsed_rows, 0) = 0
