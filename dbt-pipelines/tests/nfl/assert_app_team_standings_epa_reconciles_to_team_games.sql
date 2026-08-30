-- The standings' EPA block must be exactly the team twins summed: for every
-- 'all'-split row, off_plays/off_epa equal the offense fact's sums and
-- def_plays/def_epa the defense twin's, per (team, season, season type).
-- A row here means the standings aggregation drifted from its source.

with fact_side as (

    select
        o.team_key,
        o.season,
        o.season_type,
        sum(o.off_plays)                                as off_plays,
        round(sum(o.off_epa), 4)                        as off_epa,
        sum(d.def_plays)                                as def_plays,
        round(sum(d.def_epa), 4)                        as def_epa
    from {{ ref('fact_team_game_offense') }} o
    left join {{ ref('fact_team_game_defense') }} d
        on d.team_game_key = o.team_game_key
    group by 1, 2, 3

)

select
    s.team_label,
    s.season,
    s.season_type,
    s.off_plays                                         as standings_off_plays,
    f.off_plays                                         as fact_off_plays,
    round(s.off_epa, 4)                                 as standings_off_epa,
    f.off_epa                                           as fact_off_epa,
    s.def_plays                                         as standings_def_plays,
    f.def_plays                                         as fact_def_plays
from {{ ref('app_team_standings') }} s
inner join fact_side f
    on f.team_key = s.team_key
   and f.season = s.season
   and f.season_type = s.season_type
where s.split = 'all'
  and (
       not equal_null(s.off_plays, f.off_plays)
    or not equal_null(round(s.off_epa, 4), f.off_epa)
    or not equal_null(s.def_plays, f.def_plays)
    or not equal_null(round(s.def_epa, 4), f.def_epa)
  )
