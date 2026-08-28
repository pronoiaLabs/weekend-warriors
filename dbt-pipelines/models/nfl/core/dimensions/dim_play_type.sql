{{
    config(
        materialized='table'
    )
}}

/*
    dim_play_type -- play classification. Grain: play type. 39 rows.

    Built from the distinct type values on plays. The source has no separate
    play-type reference table, so this is derived; if a new play type appears in
    a future load it shows up here automatically.

    play_category rolls the 39 source types into the groups analysts filter by.
    The match is on lowercased slug substrings because the source slugs are
    granular ('pass-incompletion', 'sack', 'rush', 'field-goal-good' and so on)
    and the useful grouping is coarser.

    THE NFLVERSE MAPPING (measured, both directions). The two vocabularies
    differ in kind: BDL types encode the OUTCOME (Reception, Incompletion,
    Sack, Passing TD and Interception Return are five separate types), nflverse
    play_type encodes the CALLED play (all five are play_type = 'pass') with
    the outcome in flags. So nflverse_play_type is the called play a matched
    row must carry and nflverse_flag_check is the flag that confirms the
    outcome -- a semantic check on top of any positional match. Asymmetries
    the mapping documents rather than hides:

      * XP kicks (3,876 XP_KICK plays) have no BDL play type at all -- BDL's
        play stream omits PATs, so no row here can represent them. XP stats
        still arrive via the box score on fact_player_game_special.
      * kneels (1,343) and spikes (224) are distinct nflverse types buried
        inside BDL's Rush and Pass Incompletion, hence 'run or qb_kneel' and
        'pass or qb_spike'.
      * ~27k BDL administrative rows (official timeouts alone are 13,904)
        mostly do not exist as nflverse plays; is_matchable = false keeps them
        out of any match denominator.
      * preseason sits outside the match entirely (nflverse publishes no
        preseason pbp; bridge_game_ids carries NULL there).

    is_scrimmage_play mirrors the team EPA fold's denominator EXACTLY (the
    fold lives on fact_team_game_offense since the epa fact retired): the
    types whose called play is nflverse play_type in ('pass', 'run'). That is
    why the two-point types are excluded (down-less, no EPA) while sacks,
    turnovers and safeties are in. Safety is not in the measured table; it is
    mapped here as a scrimmage 'pass or run' outcome confirmed by safety = 1.
    is_dropback / is_designed_run split scrimmage by the call (fumble
    recoveries stay false on both: at BDL granularity the call is unknowable).
*/

with plays as (

    select distinct
        play_type_slug,
        play_type_abbreviation,
        play_type_text
    from {{ ref('stg_nfl__plays') }}
    where play_type_slug is not null

)

select
    {{ dbt_utils.generate_surrogate_key(['play_type_slug']) }} as play_type_key,

    play_type_slug,
    play_type_abbreviation,
    play_type_text,

    case
        when lower(play_type_slug) like '%pass%'
          or lower(play_type_slug) like '%sack%'          then 'Passing'
        when lower(play_type_slug) like '%rush%'          then 'Rushing'
        when lower(play_type_slug) like '%punt%'          then 'Punt'
        when lower(play_type_slug) like '%field-goal%'
          or lower(play_type_slug) like '%extra-point%'   then 'Kicking'
        when lower(play_type_slug) like '%kickoff%'       then 'Kickoff'
        when lower(play_type_slug) like '%penalty%'       then 'Penalty'
        when lower(play_type_slug) like '%timeout%'
          or lower(play_type_slug) like '%end%'
          or lower(play_type_slug) like '%two-minute%'    then 'Administrative'
        when lower(play_type_slug) like '%fumble%'
          or lower(play_type_slug) like '%interception%'  then 'Turnover'
        else 'Other'
    end                                                 as play_category,

    -- administrative rows are clock/bookkeeping events, not football plays;
    -- most rate calculations should exclude them
    case
        when lower(play_type_slug) like '%timeout%'
          or lower(play_type_slug) like '%end%'
          or lower(play_type_slug) like '%two-minute%'    then false
        else true
    end                                                 as is_live_ball_play,

    -- the CALLED play a matched nflverse row carries (see header); NULL for
    -- BDL-only administrative granularity nflverse does not record
    case play_type_slug
        when 'rush'                          then 'run or qb_kneel'
        when 'rushing-touchdown'             then 'run'
        when 'two-point-rush'                then 'run'
        when 'pass-incompletion'             then 'pass or qb_spike'
        when 'pass'                          then 'pass'
        when 'pass-reception'                then 'pass'
        when 'passing-touchdown'             then 'pass'
        when 'pass-interception-return'      then 'pass'
        when 'interception-return-touchdown' then 'pass'
        when 'sack'                          then 'pass'
        when 'sack-opp-fumble-recovery'      then 'pass'
        when 'two-point-pass'                then 'pass'
        when 'fumble-recovery-own'           then 'pass or run'
        when 'fumble-recovery-opponent'      then 'pass or run'
        when 'fumble-return-touchdown'       then 'pass or run'
        when 'safety'                        then 'pass or run'
        when 'defensive-2pt-conversion'      then 'pass or run'
        when 'kickoff'                       then 'kickoff'
        when 'kickoff-return-offense'        then 'kickoff'
        when 'kickoff-return-touchdown'      then 'kickoff'
        when 'punt'                          then 'punt'
        when 'blocked-punt'                  then 'punt'
        when 'blocked-punt-touchdown'        then 'punt'
        when 'punt-return-touchdown'         then 'punt'
        when 'muffed-punt-recovery-opponent' then 'punt'
        when 'field-goal-good'               then 'field_goal'
        when 'field-goal-missed'             then 'field_goal'
        when 'blocked-field-goal'            then 'field_goal'
        when 'blocked-field-goal-touchdown'  then 'field_goal'
        when 'missed-field-goal-return'      then 'field_goal'
        when 'penalty'                       then 'no_play'
        when 'timeout'                       then 'no_play'
    end                                                 as nflverse_play_type,

    -- the flag the matched nflverse row must carry to confirm the OUTCOME the
    -- BDL type encodes (nflverse pbp column expressions, as text)
    case play_type_slug
        when 'rush'                          then 'rush_attempt = 1'
        when 'rushing-touchdown'             then 'touchdown = 1'
        when 'passing-touchdown'             then 'touchdown = 1'
        when 'pass'                          then 'pass_attempt = 1'
        when 'pass-reception'                then 'complete_pass = 1'
        when 'pass-incompletion'             then 'incomplete_pass = 1'
        when 'pass-interception-return'      then 'interception = 1'
        when 'interception-return-touchdown' then 'interception = 1'
        when 'sack'                          then 'sack = 1'
        when 'sack-opp-fumble-recovery'      then 'sack = 1'
        when 'two-point-rush'                then 'two_point_attempt = 1'
        when 'two-point-pass'                then 'two_point_attempt = 1'
        when 'defensive-2pt-conversion'      then 'two_point_attempt = 1'
        when 'fumble-recovery-own'           then 'fumble = 1'
        when 'fumble-recovery-opponent'      then 'fumble = 1'
        when 'fumble-return-touchdown'       then 'fumble = 1'
        when 'safety'                        then 'safety = 1'
        when 'kickoff'                       then 'kickoff_attempt = 1'
        when 'kickoff-return-offense'        then 'kickoff_attempt = 1'
        when 'kickoff-return-touchdown'      then 'kickoff_attempt = 1'
        when 'punt'                          then 'punt_attempt = 1'
        when 'blocked-punt'                  then 'punt_attempt = 1'
        when 'blocked-punt-touchdown'        then 'punt_attempt = 1'
        when 'punt-return-touchdown'         then 'punt_attempt = 1'
        when 'muffed-punt-recovery-opponent' then 'punt_attempt = 1'
        when 'field-goal-good'               then 'field_goal_result is not null'
        when 'field-goal-missed'             then 'field_goal_result is not null'
        when 'blocked-field-goal'            then 'field_goal_result is not null'
        when 'blocked-field-goal-touchdown'  then 'field_goal_result is not null'
        when 'missed-field-goal-return'      then 'field_goal_result is not null'
        when 'penalty'                       then 'penalty = 1'
        when 'timeout'                       then 'timeout = 1'
    end                                                 as nflverse_flag_check,

    -- the EPA denominator: mirrors the team EPA fold's
    -- play_type in ('pass', 'run') filter (see header)
    (play_type_slug in (
        'pass', 'pass-reception', 'pass-incompletion', 'passing-touchdown',
        'pass-interception-return', 'interception-return-touchdown',
        'sack', 'sack-opp-fumble-recovery',
        'rush', 'rushing-touchdown',
        'fumble-recovery-own', 'fumble-recovery-opponent',
        'fumble-return-touchdown', 'safety'
    ))                                                  as is_scrimmage_play,

    -- scrimmage split by the call; both false where the call is unknowable
    (play_type_slug in (
        'pass', 'pass-reception', 'pass-incompletion', 'passing-touchdown',
        'pass-interception-return', 'interception-return-touchdown',
        'sack', 'sack-opp-fumble-recovery'
    ))                                                  as is_dropback,
    (play_type_slug in (
        'rush', 'rushing-touchdown'
    ))                                                  as is_designed_run,

    (play_type_slug in (
        'kickoff', 'kickoff-return-offense', 'kickoff-return-touchdown',
        'punt', 'blocked-punt', 'blocked-punt-touchdown',
        'punt-return-touchdown', 'muffed-punt-recovery-opponent',
        'field-goal-good', 'field-goal-missed', 'blocked-field-goal',
        'blocked-field-goal-touchdown', 'missed-field-goal-return'
    ))                                                  as is_special_teams,

    -- pre-excludes the ~27k administrative rows (plus not-available) from the
    -- play-level match so the audit only counts plays that could match; note
    -- timeout maps to no_play yet stays unmatchable -- BDL-only granularity
    (play_type_slug not in (
        'official-timeout', 'timeout', 'end-of-game', 'end-of-half',
        'end-of-regulation', 'end-period', 'two-minute-warning',
        'not-available'
    ))                                                  as is_matchable

from plays
