-- app_play_log is fact_play row for row: the pbp graft, the three role
-- joins (the bridge view is one row per gsis by construction) and the drive
-- windows must not fan out or drop. A row here names the drift.

with counts as (

    select
        (select count(*) from {{ ref('app_play_log') }})  as log_rows,
        (select count(*) from {{ ref('fact_play') }})     as fact_rows

)

select *
from counts
where log_rows <> fact_rows
