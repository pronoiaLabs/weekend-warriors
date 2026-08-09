{{
    config(
        materialized='table'
    )
}}

/*
    fact_wnba_player_game -- the player box score. Grain: player x game.

    5,751 rows over 237 games and 231 players, which is every row the source
    carries. Nothing is filtered out.

    ONE FACT, NOT THREE, AND THAT IS A DELIBERATE DEVIATION FROM THE NFL SIDE.
    There the 116-column stats source is split into offense, defense and
    special-teams facts, because a punter's row carries nothing in the passing
    columns and a single wide fact would be almost all NULL. A basketball box
    score has no such phases: every player who takes the floor can record
    every measure in it, the whole line is 16 columns, and splitting it would
    invent a distinction the sport does not have. The NFL split's awkward
    consequence -- 4,613 player-games appearing in more than one fact, so row
    counts do not sum and a UNION double-counts -- does not arise here.

    DNP ROWS ARE INCLUDED, WITH EVERY MEASURE NULL. 1,076 of the 5,751 rows
    are players who dressed and did not play. The source spells that two ways,
    '0' minutes on 1,069 rows and '--' on 7, and stg_wnba__player_stats folds
    them into is_dnp while leaving minutes_played NULL for the 7 that genuinely
    did not say. On those rows every measure below is NULL rather than 0, and
    that is the contract this fact inherits:

      * AVG EXCLUDES DNPs AUTOMATICALLY. avg(points) is points per game
        played, not points per game dressed, because SQL's AVG ignores NULLs.
        This is almost always what a question means, and it is why the prep
        layer refuses to coalesce a DNP to zero.
      * SUM is unaffected either way.
      * COUNT(*) is games dressed. game_played_count is the additive
        denominator for games played, so sum(points) / sum(game_played_count)
        reproduces the average by hand and per-36 style rates have a correct
        base.
      * A COUNT over a measure column is games in which the player recorded
        something measurable, not games played, since a played row with no
        blocks carries 0 and not NULL.

    On a played row a missing stat means zero, since the API omits
    zero-valued keys -- 1,318 of the 4,675 played rows have no BLK because the
    player recorded no blocks, not because it is unknown. The 0-fill happens
    upstream, conditioned on is_dnp.

    THERE ARE NO PERCENTAGE COLUMNS HERE, on purpose. The player source
    carries makes and attempts only, and a per-game shooting percentage is a
    ratio of two of them: computing it as a stored column would produce a
    value that cannot be averaged across games without reweighting. Divide the
    summed counts instead. fact_wnba_player_game_advanced carries the source's own
    rate metrics for anyone who wants them per game.

    team_key is the team the player appeared for in THIS game, which makes it
    the only historically accurate affiliation in the whole source. Prefer it
    over dim_wnba_player.current_team_key wherever the grain allows.

    season_type_name is joined from dim_wnba_game rather than taken from the
    staging view's degenerate columns, so the 22 player-games from the
    All-Star game 24955 are labelled 'All-Star' and can be excluded from
    competitive averages. The join is an inner join and is safe: all 5,751
    rows resolve, and none sits on a scheduled or postponed game.
*/

with player_stats as (

    select * from {{ ref('stg_wnba__player_stats') }}

),

games as (

    select
        game_key,
        date_key,
        season,
        season_type_name,
        is_postseason,
        game_date
    from {{ ref('dim_wnba_game') }}

)

select
    -- ---------------------------------------------------------------
    -- keys
    -- ---------------------------------------------------------------
    p.player_game_key,
    p.game_key,
    p.game_id,
    p.player_key,
    p.player_id,
    p.team_key,
    p.team_id,
    g.date_key,

    -- ---------------------------------------------------------------
    -- degenerate dimensions / context, taken from dim_wnba_game so this fact and
    -- fact_wnba_team_game cannot disagree about what season a game was in
    -- ---------------------------------------------------------------
    g.game_date,
    g.season,
    g.season_type_name,
    g.is_postseason,

    -- ---------------------------------------------------------------
    -- playing time. is_dnp is the switch every measure below obeys.
    -- ---------------------------------------------------------------
    p.minutes_text,
    p.minutes_played,
    p.is_dnp,
    p.game_played_count,

    -- ---------------------------------------------------------------
    -- scoring
    -- ---------------------------------------------------------------
    p.pts                                       as points,

    -- ---------------------------------------------------------------
    -- shooting. Makes and attempts only -- see header on percentages.
    -- ---------------------------------------------------------------
    p.fgm                                       as field_goals_made,
    p.fga                                       as field_goals_attempted,
    p.fg3m                                      as three_pointers_made,
    p.fg3a                                      as three_pointers_attempted,
    p.ftm                                       as free_throws_made,
    p.fta                                       as free_throws_attempted,

    -- ---------------------------------------------------------------
    -- rebounding. rebounds is the source's own total and is NOT recomputed
    -- as offensive + defensive, so the source stays authoritative.
    -- ---------------------------------------------------------------
    p.oreb                                      as offensive_rebounds,
    p.dreb                                      as defensive_rebounds,
    p.reb                                       as rebounds,

    -- ---------------------------------------------------------------
    -- playmaking and defence
    -- ---------------------------------------------------------------
    p.ast                                       as assists,
    p.stl                                       as steals,
    p.blk                                       as blocks,
    p.turnovers,
    p.personal_fouls,

    -- A differential, not a count: it is additive across a player's games but
    -- averaging it across players is a different question than it looks.
    p.plus_minus

from player_stats p
inner join games g
    on p.game_key = g.game_key
