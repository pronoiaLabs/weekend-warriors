{#
    assert_wide_offense_nflverse_reconciles_to_prep -- the nflverse block on
    the wide offense fact carries prep's values, not an artifact of the join.

    Replaces assert_fact_nflverse_player_week_reconciles_to_raw, which
    guarded the retired standalone fact at its own grain; the wide fact is
    BDL-anchored, so a count reconciliation no longer applies. Instead, a
    deterministic ~5% sample of fact rows (hash of the key, so the same rows
    every run) re-resolves each row through the bridges and checks two
    things:

      * value fidelity: the usage / EPA / detail columns equal prep's for
        the same (gsis, nflverse game), null-safely -- a drifted join
        condition or a renamed column shows up here;
      * flag honesty: has_nflverse is true exactly when the bridge path
        finds a prep row, so the measured coverage numbers stay meaningful.
#}

with sample_rows as (

    select *
    from {{ ref('fact_player_game_offense') }}
    where mod(abs(hash(player_game_key)), 20) = 0

),

bridge as (

    select player_key, gsis_id
    from {{ ref('bridge_player_ids') }}
    where player_key is not null
    qualify row_number() over (partition by player_key order by gsis_id) = 1

),

games as (

    select game_key, nflverse_game_id
    from {{ ref('bridge_game_ids') }}

),

prep as (

    select *
    from {{ ref('stg_nfl__nflverse_player_stats') }}

)

select
    f.player_game_key,
    f.season,
    f.week,
    f.has_nflverse,
    (p.gsis_id is not null)                             as prep_row_exists,
    f.target_share                                      as fact_target_share,
    p.target_share                                      as prep_target_share,
    f.receiving_epa                                     as fact_receiving_epa,
    p.receiving_epa                                     as prep_receiving_epa
from sample_rows f
left join bridge b
    on b.player_key = f.player_key
left join games g
    on g.game_key = f.game_key
left join prep p
    on  p.gsis_id = b.gsis_id
    and p.nflverse_game_id = g.nflverse_game_id
where f.has_nflverse != (p.gsis_id is not null)
   or f.target_share            is distinct from p.target_share
   or f.air_yards_share         is distinct from p.air_yards_share
   or f.wopr                    is distinct from p.wopr
   or f.passing_epa             is distinct from p.passing_epa
   or f.rushing_epa             is distinct from p.rushing_epa
   or f.receiving_epa           is distinct from p.receiving_epa
   or f.passing_cpoe            is distinct from p.passing_cpoe
   or f.receiving_first_downs   is distinct from p.receiving_first_downs
   or f.receiving_air_yards     is distinct from p.receiving_air_yards
   or f.fantasy_points_ppr      is distinct from p.fantasy_points_ppr
