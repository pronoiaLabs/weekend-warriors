/*
    The player box score must add up to the team box score.

    For every team-game that has a team_stats row, the sum of its players'
    points, rebounds and assists must equal the team's own figures. This is
    the test that catches a bad player-to-team key, a DNP row wrongly filled
    with zeros, or a game whose player rows loaded only partly -- none of which
    changes a row count.

    POINTS ARE THE INTERESTING ONE, because the two sides come from DIFFERENT
    SOURCES. The team_stats table has no points column at all, so
    fact_wnba_team_game.points_scored is the score off the game record while the
    player sum comes from player_stats. Nothing upstream forces them to agree,
    and a scorekeeping gap on either side would show here first. Rebounds and
    assists are the ordinary case, both sides tracing back to the same box
    score load.

    THRESHOLD: 0. Measured before the test was written, over all 474 team-game
    rows that have a box score: zero rows differ on points, zero on rebounds,
    zero on assists, and the maximum absolute difference on each is 0. The
    sources reconcile exactly today, so the tolerance is exact rather than a
    padded upper bound, and any drift at all is worth seeing. Raise it only
    with a measurement and a comment saying what the new number is made of.

    DNP ROWS NEED NO SPECIAL HANDLING. fact_wnba_player_game carries NULL, not 0,
    for every measure on a bench night, and SUM ignores NULLs -- so a team's
    12 dressed players and 9 who played produce the same total either way.

    SCOPE is the 474 team-game rows with has_box_score = true. The other 4
    rows (the two 2026-08-08 games, ids 24989 and 24990) have neither a team
    box score nor player rows, so there is nothing to reconcile and comparing
    them would fail on missing data rather than on a real disagreement. A
    team-game that has a team box score but NO player rows is a violation and
    is returned, since that is a genuine load gap; today there are none.
*/

{% set max_allowed_discrepancy = 0 %}

with team_box as (

    select
        game_id,
        team_id,
        points_scored,
        rebounds,
        assists
    from {{ ref('fact_wnba_team_game') }}
    where has_box_score

),

player_box as (

    select
        game_id,
        team_id,
        sum(points)     as player_points,
        sum(rebounds)   as player_rebounds,
        sum(assists)    as player_assists
    from {{ ref('fact_wnba_player_game') }}
    group by game_id, team_id

),

compared as (

    select
        t.game_id,
        t.team_id,

        t.points_scored,
        p.player_points,
        abs(t.points_scored - p.player_points)  as points_diff,

        t.rebounds,
        p.player_rebounds,
        abs(t.rebounds - p.player_rebounds)     as rebounds_diff,

        t.assists,
        p.player_assists,
        abs(t.assists - p.player_assists)       as assists_diff,

        (p.game_id is null)                     as has_no_player_rows

    from team_box t
    left join player_box p
        on  t.game_id = p.game_id
        and t.team_id = p.team_id

)

select *
from compared
where has_no_player_rows
   or points_diff   > {{ max_allowed_discrepancy }}
   or rebounds_diff > {{ max_allowed_discrepancy }}
   or assists_diff  > {{ max_allowed_discrepancy }}
