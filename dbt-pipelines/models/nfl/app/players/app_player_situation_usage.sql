{{
    config(
        materialized='table'
    )
}}

/*
    app_player_situation_usage -- where a player's targets come from, by
    situation, with the league baseline for his position.

    Grain: player x season x season type x bucket_type x bucket, long format.
    Three bucket types, three buckets each: down (1st / 2nd / 3rd_4th),
    field_zone (red_zone / mid / own) and script (leading / trailing /
    neutral). The bucket CASEs are copied verbatim from
    fact_team_game_situation so the app speaks one situational vocabulary --
    tests/nfl/assert_app_player_situation_dropbacks_reconcile.sql pins the
    copy against that fact. Regular and postseason only: nflverse publishes
    no preseason play-by-play, so a preseason read is honestly empty.

    The play base is the team fact's exact base filter restricted to pass
    plays (pass = 1, which includes sacks and scrambles -- a dropback), so
    team_dropbacks here reconciles with the fact's dropbacks. Targets count
    plays whose receiver_player_id is the player's gsis id; sacks and
    scrambles carry no receiver and land in nobody's numerator.
    target_share divides by team_targets (plays with any receiver), the same
    definition nflverse's own game-level target_share uses; team_dropbacks
    rides along as the wireframe's "routes" stand-in -- routes run are not
    in play-by-play, so the page says "N tgt · N dropbacks" instead.

    Denominators are scoped to the games the player actually appeared in
    (his fact_player_game_offense rows with a nflverse match): play-by-play
    has no participation data, so game-level presence stands in for on-field
    participation. games counts the contributing games.

    league_pos_avg_share is the exposure-weighted share of qualifying
    same-position players in the same cell (targets >= qualifying_targets;
    without a floor, fringe players drag the baseline to noise) -- "the
    average qualified WR's share in these spots", NOT a WR1 average, which
    no tiering exists to compute. league_qualifying_players says how many
    players stand behind it.
*/

{% set qualifying_targets = 5 %}

with pbp as (

    -- the team fact's base filter (play_type/epa/posteam), pass plays only
    select
        nflverse_game_id,
        posteam,
        down,
        yardline_100,
        score_differential,
        receiver_player_id
    from {{ ref('stg_nfl__nflverse_pbp') }}
    where play_type in ('pass', 'run')
      and epa is not null
      and posteam is not null
      and pass = 1

),

bridged as (

    select
        p.down,
        p.yardline_100,
        p.score_differential,
        p.receiver_player_id,
        g.game_key,
        g.season,
        g.season_type,
        iff(p.posteam = g.home_abbr_nflverse, g.home_team_key, g.away_team_key)
                                                        as team_key
    from pbp p
    inner join {{ ref('bridge_game_ids') }} g
        on g.nflverse_game_id = p.nflverse_game_id

),

-- one row per play per bucket type; the CASEs mirror fact_team_game_situation
buckets as (

    select
        'down'                                          as bucket_type,
        case
            when down = 1          then '1st'
            when down = 2          then '2nd'
            when down in (3, 4)    then '3rd_4th'
        end                                             as bucket,
        game_key, season, season_type, team_key, receiver_player_id
    from bridged
    where down is not null    -- two-point tries have no down; this cut only

    union all

    select
        'field_zone',
        case
            when yardline_100 <= 20            then 'red_zone'
            when yardline_100 <= 50            then 'mid'
            else                                    'own'
        end,
        game_key, season, season_type, team_key, receiver_player_id
    from bridged

    union all

    select
        'script',
        case
            when score_differential > 0        then 'leading'
            when score_differential < 0        then 'trailing'
            else                                    'neutral'
        end,
        game_key, season, season_type, team_key, receiver_player_id
    from bridged

),

-- gsis -> player_key (a read of the bridge view; nothing re-decides)
gsis_players as (

    select gsis_id, player_key
    from {{ ref('bridge_player_ids') }}
    where player_key is not null

),

-- the games that scope a player's denominators: appearances with a nflverse match
player_games as (

    select player_key, game_key, team_key, season, season_type
    from {{ ref('fact_player_game_offense') }}
    where has_nflverse

),

team_bucket_game as (

    select
        game_key,
        team_key,
        season,
        season_type,
        bucket_type,
        bucket,
        count(*)                                        as team_dropbacks,
        count(receiver_player_id)                       as team_targets
    from buckets
    group by all

),

denominators as (

    select
        pg.player_key,
        pg.season,
        pg.season_type,
        tbg.bucket_type,
        tbg.bucket,
        sum(tbg.team_dropbacks)                         as team_dropbacks,
        sum(tbg.team_targets)                           as team_targets,
        count(distinct pg.game_key)                     as games
    from player_games pg
    inner join team_bucket_game tbg
        on tbg.game_key = pg.game_key
       and tbg.team_key = pg.team_key
    group by all

),

numerators as (

    select
        gp.player_key,
        b.season,
        b.season_type,
        b.bucket_type,
        b.bucket,
        count(*)                                        as targets
    from buckets b
    inner join gsis_players gp
        on gp.gsis_id = b.receiver_player_id
    inner join player_games pg
        on pg.player_key = gp.player_key
       and pg.game_key = b.game_key
    group by all

),

usage as (

    select
        d.player_key,
        d.season,
        d.season_type,
        d.bucket_type,
        d.bucket,
        coalesce(n.targets, 0)                          as targets,
        d.team_dropbacks,
        d.team_targets,
        d.games
    from denominators d
    left join numerators n
        on n.player_key = d.player_key
       and n.season = d.season
       and n.season_type = d.season_type
       and n.bucket_type = d.bucket_type
       and n.bucket = d.bucket

),

season_types as (

    select distinct season_type, season_type_name, is_postseason
    from {{ ref('dim_season_week') }}

)

select
    {{ dbt_utils.generate_surrogate_key(['u.player_key', 'u.season', 'u.season_type', 'u.bucket_type', 'u.bucket']) }}
                                                        as app_player_situation_usage_key,
    u.player_key,
    p.player_id,
    p.full_name                                         as player_name,
    p.position_abbreviation                             as position,
    p.position_group,
    u.season,
    u.season_type,
    st.season_type_name,
    st.is_postseason,
    u.bucket_type,
    u.bucket,
    decode(u.bucket,
        '1st',      '1st down',
        '2nd',      '2nd down',
        '3rd_4th',  '3rd & 4th down',
        'red_zone', 'Red zone (opp 1-20)',
        'mid',      'Midfield (21-50)',
        'own',      'Own territory',
        'leading',  'Leading',
        'trailing', 'Trailing',
        'neutral',  'Tied',
        u.bucket)                                       as bucket_label,
    decode(u.bucket,
        '1st',      10, '2nd', 11, '3rd_4th', 12,
        'red_zone', 30, 'mid', 31, 'own', 32,
        'leading',  40, 'trailing', 41, 'neutral', 42,
        99)                                             as bucket_order,
    u.targets,
    u.team_targets,
    u.team_dropbacks,
    u.games,
    round(u.targets / nullif(u.team_targets, 0), 3)     as target_share,
    round(
        sum(iff(u.targets >= {{ qualifying_targets }}, u.targets, 0)) over (
            partition by u.season, u.season_type, u.bucket_type, u.bucket, p.position_abbreviation
        ) / nullif(sum(iff(u.targets >= {{ qualifying_targets }}, u.team_targets, 0)) over (
            partition by u.season, u.season_type, u.bucket_type, u.bucket, p.position_abbreviation
        ), 0), 3)                                       as league_pos_avg_share,
    count_if(u.targets >= {{ qualifying_targets }}) over (
        partition by u.season, u.season_type, u.bucket_type, u.bucket, p.position_abbreviation
    )                                                   as league_qualifying_players,
    round(u.targets / nullif(u.team_targets, 0)
        - sum(iff(u.targets >= {{ qualifying_targets }}, u.targets, 0)) over (
              partition by u.season, u.season_type, u.bucket_type, u.bucket, p.position_abbreviation
          ) / nullif(sum(iff(u.targets >= {{ qualifying_targets }}, u.team_targets, 0)) over (
              partition by u.season, u.season_type, u.bucket_type, u.bucket, p.position_abbreviation
          ), 0), 3)                                     as share_vs_league
from usage u
inner join {{ ref('dim_player') }} p
    on p.player_key = u.player_key
left join season_types st
    on st.season_type = u.season_type
