{{
    config(
        materialized='view'
    )
}}

/*
    stg_wnba__player_stats -- player box score, one row per player per game.
    5,751 rows.

    Three jobs here.

    1. Strip the flattened payload. dlt copied the whole game record, the team
       record and the player record into every row. Only game_id, team_id and
       player_id survive, plus game_date and season, which are kept as
       degenerate attributes so a season filter does not need a join back to
       games.

    2. Separate did-not-play from played-and-scored-nothing. MIN is TEXT and
       is never NULL: verified 0 NULLs across all 5,751 rows. Instead the
       source spells a DNP two ways, '0' on 1,069 rows and '--' on 7, and
       both carry NULL for every stat column. wnba_parse_minutes() returns a
       number for '0' and NULL for '--', so is_dnp folds the two together as
       "no minutes on the floor", giving 1,076 DNP rows against 4,675 played
       rows. minutes_played stays NULL for the 7 '--' rows because the source
       genuinely did not say.

    3. Apply the DNP-aware coalesce. On a played row a missing stat means
       zero, since the API omits zero-valued keys -- 1,318 of the 4,675 played
       rows have no BLK because the player recorded no blocks, not because the
       block count is unknown. On a DNP row the same NULL means "did not
       take the floor", and coalescing it to 0 would drag every AVG down by
       counting bench nights as zero-point games. So each measure is
       0-filled on played rows and left NULL on DNP rows, and
       game_played_count carries the denominator for anyone averaging by hand.

    Two columns are renamed to match team_stats, which spells the same two
    measures differently: TURNOVER -> turnovers and PF -> personal_fouls.

    No variant twins in this table: DESCRIBE shows no __V_DOUBLE column, and
    the sources.yml registry lists none, so wnba_coalesce_variant() is not
    needed here.

    team_id is the team the player appeared for in THIS game, which makes it
    the only historically accurate team affiliation in the whole source.
*/

with source as (

    select * from {{ source('wnba_raw', 'player_stats') }}

),

with_minutes as (

    select
        *,
        {{ wnba_parse_minutes('min') }}                                   as minutes_played,

        -- '0' parses to 0 and '--' parses to NULL; both mean no minutes.
        (coalesce({{ wnba_parse_minutes('min') }}, 0) = 0)                as is_dnp

    from source

),

renamed as (

    select
        -- grain: player x game
        {{ dbt_utils.generate_surrogate_key(['game__id', 'player__id']) }} as player_game_key,
        {{ dbt_utils.generate_surrogate_key(['game__id']) }}               as game_key,
        game__id                                                          as game_id,
        {{ dbt_utils.generate_surrogate_key(['player__id']) }}             as player_key,
        player__id                                                        as player_id,
        {{ dbt_utils.generate_surrogate_key(['team__id']) }}               as team_key,
        team__id                                                          as team_id,

        -- degenerate attributes off the flattened game payload
        game__date::date                                                  as game_date,
        game__season                                                      as season,

        -- ---------------------------------------------------------------
        -- playing time
        -- ---------------------------------------------------------------
        min                                                               as minutes_text,
        minutes_played,
        is_dnp,
        iff(is_dnp, 0, 1)                                                 as game_played_count,

        -- ---------------------------------------------------------------
        -- shooting. NULL on a played row means zero; NULL on a DNP row means
        -- absent, so every measure below follows the same shape.
        -- ---------------------------------------------------------------
        case when is_dnp then null else coalesce(fgm, 0) end              as fgm,
        case when is_dnp then null else coalesce(fga, 0) end              as fga,
        case when is_dnp then null else coalesce(fg3m, 0) end             as fg3m,
        case when is_dnp then null else coalesce(fg3a, 0) end             as fg3a,
        case when is_dnp then null else coalesce(ftm, 0) end              as ftm,
        case when is_dnp then null else coalesce(fta, 0) end              as fta,

        -- ---------------------------------------------------------------
        -- rebounding
        -- ---------------------------------------------------------------
        case when is_dnp then null else coalesce(oreb, 0) end             as oreb,
        case when is_dnp then null else coalesce(dreb, 0) end             as dreb,
        case when is_dnp then null else coalesce(reb, 0) end              as reb,

        -- ---------------------------------------------------------------
        -- playmaking and defence
        -- ---------------------------------------------------------------
        case when is_dnp then null else coalesce(ast, 0) end              as ast,
        case when is_dnp then null else coalesce(stl, 0) end              as stl,
        case when is_dnp then null else coalesce(blk, 0) end              as blk,
        case when is_dnp then null else coalesce(turnover, 0) end         as turnovers,
        case when is_dnp then null else coalesce(pf, 0) end               as personal_fouls,

        -- ---------------------------------------------------------------
        -- scoring
        -- ---------------------------------------------------------------
        case when is_dnp then null else coalesce(pts, 0) end              as pts,

        -- plus_minus is a differential rather than a count, so a 0 would be a
        -- real reading and not an omitted key. It is populated on all 4,675
        -- played rows, so the coalesce never fires; it is written the same way
        -- as the rest only so one rule covers the whole box score.
        case when is_dnp then null else coalesce(plus_minus, 0) end       as plus_minus

    from with_minutes

)

select * from renamed
