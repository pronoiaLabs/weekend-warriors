-- home_record / away_record are windows over the split rows, so every row of
-- a team-season must carry exactly the record its 'home' / 'away' split row
-- spells out, and NULL exactly when that split row is absent (the team has
-- not played that venue yet). A row here means the denorm drifted.

with expected as (

    select
        team_key,
        season,
        season_type,
        max(iff(split = 'home',
            wins || '-' || losses || iff(ties > 0, '-' || ties, ''), null))
                                                        as home_record,
        max(iff(split = 'away',
            wins || '-' || losses || iff(ties > 0, '-' || ties, ''), null))
                                                        as away_record
    from {{ ref('app_team_standings') }}
    group by 1, 2, 3

)

select
    s.team_label,
    s.season,
    s.season_type,
    s.split,
    s.home_record,
    e.home_record                                       as expected_home,
    s.away_record,
    e.away_record                                       as expected_away
from {{ ref('app_team_standings') }} s
inner join expected e
    on e.team_key = s.team_key
   and e.season = s.season
   and e.season_type = s.season_type
where not equal_null(s.home_record, e.home_record)
   or not equal_null(s.away_record, e.away_record)
