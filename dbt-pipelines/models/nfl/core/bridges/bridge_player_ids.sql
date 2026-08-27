{{
    config(
        materialized='view',
        pre_hook="call DLT_DB.DEPLOY.SP_PLAYER_BRIDGE('{{ this.database }}', '{{ this.schema }}', false)"
    )
}}

{#
    bridge_player_ids -- one row per nflverse player, with the BallDontLie and
    Sleeper ids the bridge has tied to it.

    THE PRE_HOOK IS THE BRIDGE. Every build first calls
    DLT_DB.DEPLOY.SP_PLAYER_BRIDGE (dbt-pipelines/snowpark/player_bridge/),
    which writes PLAYER_BRIDGE and PLAYER_BRIDGE_UNMATCHED into this model's
    own schema (DEV_<user> in dev, CORE in prod). The procedure decides only
    players it has not seen and returns in milliseconds when there are none,
    so the hook is free in the steady state; a new player is bridged on the
    first build after he appears in a vendor table. It never re-decides a
    row: call it with full_refresh => true by hand to redo everything.

    The bridge stores stable ids only (no team, no jersey), so a trade changes
    nothing here. Grain is gsis_id: nflverse is the spine because every other
    nflverse table keys on it. player_key is NULL for the players BallDontLie
    does not carry.

    BallDontLie holds a few genuine duplicates (two ids for Vinny Testaverde,
    two for Chuck Wiley: a second import batch, measured 2026-08-23), and the
    bridge rightly maps both ids to the one nflverse player. This view keeps
    the grain by taking ONE vendor id per gsis_id: the strongest tier first
    (id, exact, tiebreak, search_ai), then the lowest vendor id (the older
    import). tests/nfl/assert_player_bridge_is_one_to_one reports the rest
    as a warning, so a new duplicate is visible without failing the build.
#}

with bridge as (

    select
        *,
        row_number() over (
            partition by vendor, gsis_id
            order by
                case match_method
                    when 'id' then 1
                    when 'exact' then 2
                    when 'tiebreak' then 3
                    else 4
                end,
                try_to_number(vendor_player_id),
                vendor_player_id
        )                                               as claim_rank
    from {{ nfl_player_bridge_fqn() }}

),

bdl as (

    select
        vendor_player_id                                as bdl_player_id,
        gsis_id,
        match_method                                    as bdl_match_method,
        search_agrees                                   as bdl_search_agrees,
        decided_at                                      as bdl_decided_at
    from bridge
    where vendor = 'bdl'
      and claim_rank = 1

),

sleeper as (

    select
        vendor_player_id                                as sleeper_player_id,
        gsis_id,
        match_method                                    as sleeper_match_method,
        search_agrees                                   as sleeper_search_agrees,
        decided_at                                      as sleeper_decided_at
    from bridge
    where vendor = 'sleeper'
      and claim_rank = 1

),

nflverse as (

    select * from {{ ref('stg_nfl__nflverse_players') }}

),

players as (

    -- Staging, not dim_player: dim_player now enriches FROM this bridge, so
    -- reading the dim here would be a dependency cycle. player_key and
    -- player_id pass through dim_player from staging unchanged.
    select player_key, player_id from {{ ref('stg_nfl__players') }}

)

select
    p.player_key,
    p.player_id,
    n.gsis_id,
    s.sleeper_player_id,
    n.espn_id,
    n.pfr_id,
    n.pff_id,
    n.esb_id,

    n.display_name                                      as nflverse_display_name,
    n.position                                          as nflverse_position,
    n.nflverse_team_abbr,
    n.team_abbreviation,
    n.status                                            as nflverse_status,
    n.headshot_url,

    b.bdl_match_method,
    b.bdl_search_agrees,
    s.sleeper_match_method,
    s.sleeper_search_agrees,
    greatest_ignore_nulls(b.bdl_decided_at, s.sleeper_decided_at) as decided_at

from nflverse n
left join bdl b
    on b.gsis_id = n.gsis_id
left join players p
    on p.player_id = try_to_number(b.bdl_player_id)
left join sleeper s
    on s.gsis_id = n.gsis_id
