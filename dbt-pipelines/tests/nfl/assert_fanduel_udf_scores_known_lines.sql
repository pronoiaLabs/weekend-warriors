/*
    The FanDuel UDF scores known stat lines to the hand-computed value.

    NFL_FANDUEL_POINTS is the single definition of the scoring, so this is the
    one place its arithmetic is checked. Each row is a stat line and the value
    FanDuel's rule table gives it, worked by hand:

      QB 300 yds 3 TD 1 INT          0.04*300 + 3 bonus + 4*3 - 1        = 26.00
      RB 20 car 100 yds 1 TD, 3-30   0.1*100 + 3 + 6 + 0.5*3 + 0.1*30    = 23.50
      WR 5-99 0 TD, 1 fumble lost    0.5*5 + 0.1*99 - 2                  = 10.40
      two-point pass thrown + caught 2 + 2 (the QB row throws, WR catches)
      return TD only                 6
      all NULL                       0, never NULL

    Bonuses are exactly-at-threshold: 100 rushing pays the bonus, 99 receiving
    does not. The last row pins the NULL contract: every argument NULL scores 0.
*/

with cases as (

    select * from values
        ('qb_300_3_1',      null, null, null, null, null, 300, 3, 1, null, null, null, null, null, 26.00),
        ('rb_100_1_td',     3,    30,   0,    100,  1,    null, null, null, 0, null, null, null, null, 23.50),
        ('wr_99_fumble',    5,    99,   0,    null, null, null, null, null, 1, null, null, null, null, 10.40),
        ('qb_two_pt_pass',  null, null, null, null, null, 20,   0, 0, null, null, null, 0, 1, 2.80),
        ('wr_two_pt_catch', 1,    5,    0,    null, null, null, null, null, null, null, null, 1, null, 3.00),
        ('return_td_only',  null, null, null, null, null, null, null, null, null, null, 1, null, null, 6.00),
        ('all_null',        null, null, null, null, null, null, null, null, null, null, null, null, null, 0.00)
    as t(case_name, receptions, receiving_yards, receiving_touchdowns, rushing_yards, rushing_touchdowns,
         passing_yards, passing_touchdowns, passing_interceptions, fumbles_lost, fumble_recovery_tds,
         return_touchdowns, two_point_conversions, two_point_thrown, expected)

),

scored as (

    select
        case_name,
        expected,
        {{ nfl_fanduel_points_fqn() }}(
            receptions, receiving_yards, receiving_touchdowns,
            rushing_yards, rushing_touchdowns,
            passing_yards, passing_touchdowns, passing_interceptions,
            fumbles_lost, fumble_recovery_tds, return_touchdowns,
            two_point_conversions, two_point_thrown
        ) as actual
    from cases

)

select case_name, expected, actual
from scored
where actual is null
   or actual <> expected
