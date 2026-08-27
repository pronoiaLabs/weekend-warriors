{{
    config(
        materialized='table'
    )
}}

/*
    dim_player_combine -- NFL Combine testing, 2000 on. Grain: combine
    appearance (season x player x position; effectively one row per player).
    Physical name PLAYER_COMBINE.

    Kept as its own dimension rather than 15 more dim_player columns: combine
    data exists only for drafted-era players and would be NULL-heavy on the
    13.5k-row roster dim.

    Rows WITHOUT a bridge match stay, on purpose -- the combine holds
    prospects who never played a down, and dropping them would make "who ran
    the fastest forty" quietly mean "who ran it and later made a roster".
    gsis_id resolves through the players crosswalk on pfr_id (unique there,
    measured; 7,048 of 7,437 non-NULL combine pfr_ids resolve) and player_key
    through bridge_player_ids on gsis_id; both are NULL for the unmatched.

    combine_key is the surrogate over (season, player_name, position) because
    pfr_id cannot key this table: NULL on 1,531 rows and 17 ids each sit on
    two same-name different players at the source (so those 17 can also carry
    a wrong gsis_id -- the id, not the join, is at fault).
*/

with combine as (

    select * from {{ ref('stg_nfl__nflverse_combine') }}

),

crosswalk as (

    select
        pfr_id,
        gsis_id
    from {{ ref('stg_nfl__nflverse_players') }}
    where pfr_id is not null

),

bridge as (

    select
        gsis_id,
        player_key
    from {{ ref('bridge_player_ids') }}
    where player_key is not null

)

select
    {{ dbt_utils.generate_surrogate_key(['c.season', 'c.player_name', 'c.position']) }}
                                                        as combine_key,

    -- identity; keys NULL when the prospect never resolved (see header)
    b.player_key,
    x.gsis_id,
    c.pfr_id,
    c.cfb_id,
    c.player_name,
    c.position,
    c.school,
    c.season,

    -- draft outcome, as the combine file records it
    c.draft_year,
    c.draft_team,
    c.draft_round,
    c.draft_overall,

    -- athletic testing
    c.height_inches,
    c.weight_lbs,
    c.forty,
    c.bench,
    c.vertical,
    c.broad_jump,
    c.cone,
    c.shuttle,

    (x.gsis_id is not null)                             as has_nflverse_match,
    (b.player_key is not null)                          as has_player_match

from combine c
left join crosswalk x
    on x.pfr_id = c.pfr_id
left join bridge b
    on b.gsis_id = x.gsis_id
