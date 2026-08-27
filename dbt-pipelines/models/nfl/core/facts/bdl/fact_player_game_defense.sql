{{ config(materialized='table') }}

/*
    fact_player_game_defense -- tackles, pressure and coverage, all vendors.
    Grain: player x game. ~42,300 rows, the largest of the three phase facts.
    BallDontLie is the anchor; the nflverse def_* block and the Sleeper IDP
    columns ride along where the bridges find the same player-week.

    See fact_player_game_offense for the full explanation of the phase split and
    the deliberate cross-fact key overlap. Short version: measure sets are
    disjoint, keys can repeat across facts, so aggregate each fact independently
    and never UNION them.

    defensive_sacks is a coalesced dlt variant column and is FLOAT, not integer:
    a shared sack counts as 0.5. Do not cast it to int.

    Fumbles: recovered and returned-for-score sit here (defensive outcomes);
    fumbles committed/lost sit on the offense fact. Both of those columns are in
    the activity filter below -- they have to be, because they are published as
    measures here. Leaving them out dropped 1,022 player-games whose only
    defensive contribution was a fumble recovery, hiding 1,061 of 2,058
    recoveries and understating takeaways by 30%.

    VENDOR BLOCKS. Same bridge path as the offense fact (see its header for
    the mechanics and the postseason week mapping). The two vendors' sack and
    tackle readings deliberately keep their own names beside BallDontLie's
    (defensive_sacks vs def_sacks vs idp_sack): the providers disagree on
    attribution, and coalescing would hide it -- the same policy as the two
    defensive_touchdowns columns on fact_team_game_defense. On matched rows
    the def_* block is populated with zeros, not NULLs, where nothing was
    recorded; the file's penalty pair is player penalties in general, not
    defense-specific, so it carries the vendor prefix rather than def_.
    Measured Aug 2026, excluding preseason: 98.6% regular season / 99.1%
    postseason carry the nflverse block; Sleeper 81.2% / 83.9%, with IDP
    values on roughly 78% of the matched rows.
*/

with stats as (

    select * from {{ ref('stg_nfl__player_stats') }}

),

games as (

    select
        game_key,
        date_key,
        season_week_key,
        season,
        week,
        season_type,
        is_postseason
    from {{ ref('dim_game') }}

),

defense as (

    -- Every column published as a BDL measure by this model must appear here.
    -- fumbles_recovered / fumbles_touchdowns are easy to forget because they
    -- read as "fumble" rather than "defense", but they are defensive takeaways
    -- and appear on no other fact -- omitting them made those rows unreachable
    -- warehouse-wide.
    select *
    from stats
    where coalesce(
              total_tackles,
              solo_tackles,
              tackles_for_loss,
              defensive_sacks,
              qb_hits,
              passes_defended,
              defensive_interceptions,
              fumbles_recovered,
              fumbles_touchdowns
          ) is not null

),

-- One row per player_key; see fact_player_game_offense for why the qualify.
bridge as (

    select player_key, gsis_id, pfr_id, sleeper_player_id
    from {{ ref('bridge_player_ids') }}
    where player_key is not null
    qualify row_number() over (partition by player_key order by gsis_id) = 1

),

game_bridge as (

    select game_key, nflverse_game_id, nflverse_week, season, week,
           season_type, is_postseason
    from {{ ref('bridge_game_ids') }}

),

nflverse as (

    select * from {{ ref('stg_nfl__nflverse_player_stats') }}

),

snaps as (

    select pfr_player_id, nflverse_game_id, defense_snaps, defense_pct
    from {{ ref('stg_nfl__nflverse_snap_counts') }}

),

sleeper as (

    -- No is_team_defense filter: the DEF team rows carry the club abbreviation
    -- as their id and can never match the bridge's numeric sleeper ids, while
    -- prep's length-based flag also catches real veterans with short ids
    -- (id 96, 167, ...) whose weeks belong here.
    select * from {{ ref('stg_nfl__sleeper_stats') }}

)

select
    -- keys
    d.player_game_key,
    d.game_key,
    d.game_id,
    d.player_key,
    d.player_id,
    d.team_key,
    d.team_id,
    g.date_key,
    g.season_week_key,

    -- context
    g.season,
    g.week,
    g.season_type,
    g.is_postseason,

    -- ---------------------------------------------------------------
    -- tackling
    -- ---------------------------------------------------------------
    d.total_tackles,
    d.solo_tackles,
    d.tackles_for_loss,

    -- ---------------------------------------------------------------
    -- pass rush. FLOAT: half-sacks are real.
    -- ---------------------------------------------------------------
    d.defensive_sacks,
    d.qb_hits,

    -- ---------------------------------------------------------------
    -- coverage
    -- ---------------------------------------------------------------
    d.passes_defended,
    d.defensive_interceptions,
    d.interception_yards,
    d.interception_touchdowns,

    -- ---------------------------------------------------------------
    -- takeaways
    -- ---------------------------------------------------------------
    d.fumbles_recovered,
    d.fumbles_touchdowns,

    -- ---------------------------------------------------------------
    -- derived: total takeaways and total defensive scores, the two roll-ups
    -- most defensive questions reach for
    -- ---------------------------------------------------------------
    coalesce(d.defensive_interceptions, 0) + coalesce(d.fumbles_recovered, 0)
                                                        as takeaways,
    coalesce(d.interception_touchdowns, 0) + coalesce(d.fumbles_touchdowns, 0)
                                                        as defensive_touchdowns,

    -- assisted tackles are not published directly; total minus solo is the
    -- standard derivation. Guarded so a missing solo count cannot go negative.
    case
        when d.total_tackles is not null and d.solo_tackles is not null
             and d.total_tackles >= d.solo_tackles
        then d.total_tackles - d.solo_tackles
    end                                                 as assisted_tackles,

    -- ---------------------------------------------------------------
    -- nflverse: the def_* block from the week stats, under the vendor's own
    -- names beside BallDontLie's readings (see header)
    -- ---------------------------------------------------------------
    nv.def_tackles_solo,
    nv.def_tackles_with_assist,
    nv.def_tackle_assists,
    nv.def_tackles_for_loss,
    nv.def_tackles_for_loss_yards,
    nv.def_fumbles_forced,
    nv.def_sacks,
    nv.def_sack_yards,
    nv.def_qb_hits,
    nv.def_interceptions,
    nv.def_interception_yards,
    nv.def_pass_defended,
    nv.def_tds,
    nv.def_fumbles,
    nv.def_safeties,
    nv.def_punt_blocks,
    nv.def_pat_blocks,
    nv.def_fg_blocks,
    nv.def_2pt_atts,
    nv.def_2pt_made,
    nv.penalties                                        as nflverse_penalties,
    nv.penalty_yards                                    as nflverse_penalty_yards,

    -- nflverse: snaps, via the pfr crosswalk on the bridge
    sn.defense_snaps,
    sn.defense_pct,

    (nv.gsis_id is not null)                            as has_nflverse,

    -- ---------------------------------------------------------------
    -- Sleeper: IDP scoring inputs and snap share
    -- ---------------------------------------------------------------
    sl.idp_tkl,
    sl.idp_sack,
    sl.idp_int,
    sl.idp_ff,
    sl.idp_fum_rec,
    sl.idp_pass_def,
    sl.idp_qb_hit,
    sl.def_snp,
    sl.tm_def_snp,

    (sl.sleeper_player_id is not null)                  as has_sleeper

from defense d
inner join games g
    on d.game_key = g.game_key
left join bridge b
    on b.player_key = d.player_key
left join game_bridge gb
    on gb.game_key = d.game_key
left join nflverse nv
    on  nv.gsis_id = b.gsis_id
    and nv.nflverse_game_id = gb.nflverse_game_id
left join snaps sn
    on  sn.pfr_player_id = b.pfr_id
    and sn.nflverse_game_id = gb.nflverse_game_id
left join sleeper sl
    on  sl.sleeper_player_id = b.sleeper_player_id
    and sl.season = gb.season
    and case sl.season_type
            when 'regular' then gb.season_type = 2 and sl.week = gb.week
            when 'post'    then gb.is_postseason and sl.week + 18 = gb.nflverse_week
            when 'pre'     then gb.season_type = 1 and sl.week = gb.week
        end
