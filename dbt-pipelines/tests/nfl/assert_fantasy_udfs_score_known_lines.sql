/*
    The fantasy UDFs score known stat lines to the hand-computed values.

    NFL_FANDUEL_POINTS and NFL_DRAFTKINGS_POINTS are the single definition of
    each book's scoring, so this is the one place the arithmetic is checked.
    Each row is a stat line and the value each book's rule table gives it,
    worked by hand. The two books differ only in receptions (0.5 vs 1.0) and
    fumbles lost (-2 vs -1), which is why only the lines with either move.

                                     FanDuel                          DraftKings
      QB 300 yds 3 TD 1 INT          0.04*300 + 3 + 4*3 - 1  = 26.00  same      = 26.00
      RB 100 yds 1 TD, 3-30          10 + 3 + 6 + 1.5 + 3    = 23.50  rec 3.0   = 25.00
      WR 5-99 0 TD, 1 fumble lost    2.5 + 9.9 - 2           = 10.40  5 + 9.9-1 = 13.90
      QB 20 yds + two-point pass     0.8 + 2                 =  2.80  same      =  2.80
      WR 1-5 + two-point catch       0.5 + 0.5 + 2           =  3.00  rec 1.0   =  3.50
      return TD only                 6                       =  6.00  same      =  6.00
      all NULL                       0, never NULL           =  0.00  same      =  0.00

    Bonuses are exactly-at-threshold: 100 rushing pays the bonus, 99 receiving
    does not. The last row pins the NULL contract: every argument NULL scores 0.
*/

with cases as (

    select * from values
        ('qb_300_3_1',      null, null, null, null, null, 300,  3,    1,    null, null, null, null, null, 26.00, 26.00),
        ('rb_100_1_td',     3,    30,   0,    100,  1,    null, null, null, 0,    null, null, null, null, 23.50, 25.00),
        ('wr_99_fumble',    5,    99,   0,    null, null, null, null, null, 1,    null, null, null, null, 10.40, 13.90),
        ('qb_two_pt_pass',  null, null, null, null, null, 20,   0,    0,    null, null, null, 0,    1,    2.80,  2.80),
        ('wr_two_pt_catch', 1,    5,    0,    null, null, null, null, null, null, null, null, 1,    null, 3.00,  3.50),
        ('return_td_only',  null, null, null, null, null, null, null, null, null, null, 1,    null, null, 6.00,  6.00),
        ('all_null',        null, null, null, null, null, null, null, null, null, null, null, null, null, 0.00,  0.00)
    as t(case_name, receptions, receiving_yards, receiving_touchdowns, rushing_yards, rushing_touchdowns,
         passing_yards, passing_touchdowns, passing_interceptions, fumbles_lost, fumble_recovery_tds,
         return_touchdowns, two_point_conversions, two_point_thrown, expected_fanduel, expected_draftkings)

),

scored as (

    select
        case_name,
        expected_fanduel,
        expected_draftkings,
        {{ nfl_fantasy_points_fqn('fanduel') }}(
            receptions, receiving_yards, receiving_touchdowns,
            rushing_yards, rushing_touchdowns,
            passing_yards, passing_touchdowns, passing_interceptions,
            fumbles_lost, fumble_recovery_tds, return_touchdowns,
            two_point_conversions, two_point_thrown
        ) as actual_fanduel,
        {{ nfl_fantasy_points_fqn('draftkings') }}(
            receptions, receiving_yards, receiving_touchdowns,
            rushing_yards, rushing_touchdowns,
            passing_yards, passing_touchdowns, passing_interceptions,
            fumbles_lost, fumble_recovery_tds, return_touchdowns,
            two_point_conversions, two_point_thrown
        ) as actual_draftkings
    from cases

)

select case_name, expected_fanduel, actual_fanduel, expected_draftkings, actual_draftkings
from scored
where actual_fanduel is null
   or actual_fanduel <> expected_fanduel
   or actual_draftkings is null
   or actual_draftkings <> expected_draftkings
