{{
    config(
        materialized='table'
    )
}}

/*
    app_team_situation -- the game page's situations tab: what each unit does,
    and allows, in the situations that decide games. Grain: team x season x
    season_type x side x situation, where the situation is (situation_group,
    situation_key) in long format -- ~22 rows per team-season-side.

    Source is fact_team_game_situation, whose side column already unpivots
    every play twice ('offense' / 'defense'): a defense row IS the allowed
    reading, so pairing an offense with the opposing defense in the same
    situation needs no derivation here. The additive components (plays,
    epa_sum, success_plays, explosive_plays) are summed per cut and the rates
    recomputed sum-over-sum -- per-game rates are never re-averaged.

    Exposed cuts, only ones the fact can answer:
      overall        the anchor row ('all'); the one place two-point tries
                     (NULL down) are counted, so down cuts sum to slightly
                     less than overall by construction
      down           1st / 2nd / 3rd_4th
      down_distance  the 9 down x distance combos (short <=3, medium 4-7,
                     long 8+); '3rd_4th_long' is the headline
      field_zone     red_zone (opp 1-20) / mid (21-50) / own
      script         leading / trailing / neutral, the ROW's team's view
      play_family    dropback / designed_run
      two_minute     the final two minutes of either half

    Shotgun and no-huddle are deliberately not exposed: tendency dimensions,
    not page-shaped splits (the semantic view covers those questions).

    League context is a ratio of sums across teams per (season, season_type,
    side, situation): league_epa_per_play, epa_vs_league, and the same pair
    for success rate. situation_rank is 1 = BEST for that unit (offense ranks
    epa descending, defense ascending) -- note this differs from
    app_team_allowed, where rank 1 allows the most. plays rides along so the
    page can gray thin cells; no minimum-plays floor is applied here.

    This is a season-level surface (like app_team_allowed): a historical
    game's panel shows the full-season splits, not a pre-kickoff window.
    nflverse publishes no preseason play-by-play, so preseason is honestly
    absent.
*/

with situations as (

    select * from {{ ref('fact_team_game_situation') }}

),

season_types as (

    select distinct season_type, season_type_name, is_postseason
    from {{ ref('dim_season_week') }}

),

teams as (

    select * from {{ ref('dim_team') }}

),

{% set groups = [
    {'name': 'overall',       'key': "'all'",
     'where': 'true'},
    {'name': 'down',          'key': 'down_bucket',
     'where': 'down_bucket is not null'},
    {'name': 'down_distance', 'key': "down_bucket || '_' || distance_bucket",
     'where': 'down_bucket is not null and distance_bucket is not null'},
    {'name': 'field_zone',    'key': 'field_zone',
     'where': 'field_zone is not null'},
    {'name': 'script',        'key': 'game_script',
     'where': 'game_script is not null'},
    {'name': 'play_family',   'key': 'play_family',
     'where': 'play_family is not null'},
    {'name': 'two_minute',    'key': "'two_minute'",
     'where': 'is_two_minute'},
] %}

unioned as (

    {% for grp in groups %}
    select
        team_key,
        team_id,
        season,
        season_type,
        side,
        '{{ grp.name }}'                                as situation_group,
        {{ grp.key }}                                   as situation_key,
        sum(plays)                                      as plays,
        sum(epa_sum)                                    as epa_sum,
        sum(success_plays)                              as success_plays,
        sum(explosive_plays)                            as explosive_plays
    from situations
    where {{ grp.where }}
    group by 1, 2, 3, 4, 5, 6, 7
    {% if not loop.last %}union all{% endif %}
    {% endfor %}

),

rated as (

    select
        *,
        epa_sum / plays                                 as epa_per_play,
        success_plays / plays                           as success_rate,
        explosive_plays / plays                         as explosive_rate
    from unioned

),

-- league context: ratio of sums across teams in the same cut, and the rank
-- where 1 is best for that unit (offense high epa, defense low epa allowed)
contextualized as (

    select
        *,
        sum(epa_sum) over (partition by season, season_type, side, situation_group, situation_key)
            / sum(plays) over (partition by season, season_type, side, situation_group, situation_key)
                                                        as league_epa_per_play,
        sum(success_plays) over (partition by season, season_type, side, situation_group, situation_key)
            / sum(plays) over (partition by season, season_type, side, situation_group, situation_key)
                                                        as league_success_rate,
        rank() over (
            partition by season, season_type, side, situation_group, situation_key
            order by iff(side = 'offense', -epa_per_play, epa_per_play)
        )                                               as situation_rank,
        count(*) over (partition by season, season_type, side, situation_group, situation_key)
                                                        as teams_ranked
    from rated

)

select
    {{ dbt_utils.generate_surrogate_key([
        'c.team_key', 'c.season', 'c.season_type', 'c.side',
        'c.situation_group', 'c.situation_key'
    ]) }}                                               as app_team_situation_key,

    -- who
    c.team_key,
    c.team_id,
    t.team_abbreviation                                 as team_label,
    t.team_full_name                                    as team_name,
    t.conference,
    t.division,

    -- when
    c.season,
    c.season_type,
    st.season_type_name,
    st.is_postseason,

    -- the situation
    c.side,
    c.situation_group,
    c.situation_key,
    decode(c.situation_key,
        'all',              'All plays',
        '1st',              '1st down',
        '2nd',              '2nd down',
        '3rd_4th',          '3rd & 4th down',
        '1st_short',        '1st & short (≤3)',
        '1st_medium',       '1st & medium (4-7)',
        '1st_long',         '1st & long (8+)',
        '2nd_short',        '2nd & short (≤3)',
        '2nd_medium',       '2nd & medium (4-7)',
        '2nd_long',         '2nd & long (8+)',
        '3rd_4th_short',    '3rd/4th & short (≤3)',
        '3rd_4th_medium',   '3rd/4th & medium (4-7)',
        '3rd_4th_long',     '3rd/4th & long (8+)',
        'red_zone',         'Red zone (opp 1-20)',
        'mid',              'Midfield (21-50)',
        'own',              'Own territory',
        'leading',          'Leading',
        'trailing',         'Trailing',
        'neutral',          'Tied',
        'dropback',         'Dropbacks',
        'designed_run',     'Designed runs',
        'two_minute',       'Two-minute drill',
        c.situation_key)                                as situation_label,
    decode(c.situation_key,
        'all',              0,
        '1st',              10, '2nd', 11, '3rd_4th', 12,
        '1st_short',        20, '1st_medium', 21, '1st_long', 22,
        '2nd_short',        23, '2nd_medium', 24, '2nd_long', 25,
        '3rd_4th_short',    26, '3rd_4th_medium', 27, '3rd_4th_long', 28,
        'red_zone',         30, 'mid', 31, 'own', 32,
        'leading',          40, 'trailing', 41, 'neutral', 42,
        'dropback',         50, 'designed_run', 51,
        'two_minute',       60,
        99)                                             as situation_order,

    -- measures: this cut's own division of its additive components
    c.plays,
    c.epa_per_play,
    c.success_rate,
    c.explosive_rate,

    -- league context in the same cut
    c.league_epa_per_play,
    c.epa_per_play - c.league_epa_per_play              as epa_vs_league,
    c.league_success_rate,
    c.success_rate - c.league_success_rate              as success_rate_vs_league,
    c.situation_rank,
    c.teams_ranked

from contextualized c
inner join teams t
    on t.team_key = c.team_key
left join season_types st
    on st.season_type = c.season_type
