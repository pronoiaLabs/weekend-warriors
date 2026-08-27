/*
    fact_team_game_situation writes every play twice -- an offense row for
    posteam and a defense row for defteam -- so each offense row must have
    exactly one mirror: the OPPONENT's defense row in the same game and the
    same situation cell, with identical plays and epa_sum. The one dimension
    that legitimately differs is game_script, which is from the row's team's
    perspective and therefore flips (leading <-> trailing, neutral stays).

    This is the test that would catch a broken unpivot or a side computed
    from the wrong team column. Full outer join: a row on either side without
    its mirror fails, as does a mirrored pair whose measures disagree.
    equal_null on the nullable buckets (two-point tries carry NULL down and
    distance) so a NULL cell still finds its NULL mirror.
*/

with offense as (

    select * from {{ ref('fact_team_game_situation') }}
    where side = 'offense'

),

defense as (

    select * from {{ ref('fact_team_game_situation') }}
    where side = 'defense'

)

select
    coalesce(o.game_id, d.game_id)                      as game_id,
    o.team_id                                           as offense_team_id,
    d.team_id                                           as defense_team_id,
    coalesce(o.down_bucket, d.down_bucket)              as down_bucket,
    coalesce(o.distance_bucket, d.distance_bucket)      as distance_bucket,
    coalesce(o.game_script, d.game_script)              as game_script,
    o.plays                                             as offense_plays,
    d.plays                                             as defense_plays,
    o.epa_sum                                           as offense_epa_sum,
    d.epa_sum                                           as defense_epa_sum
from offense o
full outer join defense d
    on  d.game_id = o.game_id
    and d.team_id = o.opponent_team_id
    and equal_null(d.down_bucket, o.down_bucket)
    and equal_null(d.distance_bucket, o.distance_bucket)
    and equal_null(d.field_zone, o.field_zone)
    and equal_null(d.play_family, o.play_family)
    and d.is_shotgun = o.is_shotgun
    and d.is_no_huddle = o.is_no_huddle
    and d.is_two_minute = o.is_two_minute
    and d.game_script = case o.game_script
                            when 'leading'  then 'trailing'
                            when 'trailing' then 'leading'
                            else                 'neutral'
                        end
where o.team_game_situation_key is null                 -- defense row with no offense mirror
   or d.team_game_situation_key is null                 -- offense row with no defense mirror
   or o.plays != d.plays
   or abs(o.epa_sum - d.epa_sum) > 0.001
