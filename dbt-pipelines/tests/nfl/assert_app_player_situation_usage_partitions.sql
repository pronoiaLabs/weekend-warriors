-- app_player_situation_usage's three bucket types cut the SAME pass-play set,
-- so per player-season-type the target totals must agree: field_zone and
-- script both partition every play (their sums are equal), while the down cut
-- drops the NULL-down two-point tries (its sum can only be smaller). A row
-- here is a player-season whose cuts disagree -- the bucket CASEs drifted.

with sums as (

    select
        player_key,
        season,
        season_type,
        bucket_type,
        sum(targets)                                    as targets_total
    from {{ ref('app_player_situation_usage') }}
    group by 1, 2, 3, 4

),

pivoted as (

    select
        player_key,
        season,
        season_type,
        max(iff(bucket_type = 'down', targets_total, null))
                                                        as down_targets,
        max(iff(bucket_type = 'field_zone', targets_total, null))
                                                        as field_zone_targets,
        max(iff(bucket_type = 'script', targets_total, null))
                                                        as script_targets
    from sums
    group by 1, 2, 3

)

select *
from pivoted
where field_zone_targets <> script_targets
   or coalesce(down_targets, 0) > script_targets
