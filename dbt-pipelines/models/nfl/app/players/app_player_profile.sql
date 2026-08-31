{{
    config(
        materialized='table'
    )
}}

/*
    app_player_profile -- the player page's identity header, one row per player.

    Grain: player (every player app_player_weeks can open). Current-state by
    design, which is why it is its own mart rather than columns on
    app_player_leaders: the Sleeper live block (injury status, practice
    participation) and the resolved current team describe NOW, and stamping
    them onto every player-season row would replicate today's state across
    history. The page labels the live block as-of news_updated_at.

    Current team is the prop board's resolver, evaluated at "now": the
    player's most recent box score wins when it is from the current league
    season; before the season's first box score the BDL roster feed decides,
    so offseason movers are right; a player the roster feed has dropped keeps
    his last box-score team. team_source says which tier answered, mirroring
    dim_player's position_source. The alternatives were measured and rejected:
    the depth-chart resolver only covers charted players and goes stale, and
    the per-season last_team on app_player_leaders mislabels every offseason
    mover (the prop board documents the incident).

    The next-game block is the status board's team-anchored pattern: the
    resolved team's next non-completed game. NULL when the schedule holds
    none (deep offseason).
*/

with weeks as (

    select distinct player_key from {{ ref('app_player_weeks') }}

),

players as (

    select * from {{ ref('dim_player') }}

),

teams as (

    select * from {{ ref('dim_team') }}

),

-- the current league season = the newest season with a completed box score
current_season as (

    select max(season) as season from {{ ref('fact_player_game_offense') }}

),

-- the player's most recent box score anywhere, with its season
last_box as (

    select
        o.player_key,
        o.team_key,
        o.season                                        as box_score_season
    from {{ ref('fact_player_game_offense') }} o
    inner join {{ ref('dim_game') }} g
        on g.game_key = o.game_key
    qualify row_number() over (
        partition by o.player_key
        order by g.game_datetime desc, o.game_key desc
    ) = 1

),

-- the BDL roster feed's current team (what the news mart trusts)
current_team as (

    select
        player_id,
        current_team_key
    from {{ ref('stg_nfl__players') }}
    where current_team_id is not null

),

resolved_team as (

    select
        w.player_key,
        case
            when lb.box_score_season = cs.season then lb.team_key
            else coalesce(ct.current_team_key, lb.team_key)
        end                                             as team_key,
        case
            when lb.box_score_season = cs.season then 'box_score'
            when ct.current_team_key is not null then 'roster'
            else 'prior_box_score'
        end                                             as team_source
    from weeks w
    inner join players p
        on p.player_key = w.player_key
    cross join current_season cs
    left join last_box lb
        on lb.player_key = w.player_key
    left join current_team ct
        on ct.player_id = p.player_id

),

-- each team's next non-completed game (the status board's pattern)
next_game as (

    select
        t.team_key,
        g.game_key,
        g.game_datetime_et,
        g.season,
        g.week,
        g.season_type_name,
        iff(g.home_team_key = t.team_key, g.away_team_key, g.home_team_key)
                                                        as opponent_team_key,
        g.home_team_key = t.team_key                    as is_home
    from teams t
    inner join {{ ref('dim_game') }} g
        on (g.home_team_key = t.team_key or g.away_team_key = t.team_key)
       and not g.is_completed
    qualify row_number() over (partition by t.team_key order by g.game_datetime) = 1

)

select
    p.player_key                                        as app_player_profile_key,
    p.player_key,
    p.player_id,
    p.full_name                                         as player_name,
    p.first_name,
    p.last_name,
    p.position_abbreviation                             as position,
    p.position_name,
    p.position_group,
    p.jersey_number,
    p.headshot_url,
    p.age,
    p.birth_date,
    p.height_inches,
    p.weight_lbs,
    coalesce(p.college, p.college_name)                 as college_display,
    p.college,
    p.college_name,
    p.draft_year,
    p.draft_round,
    p.draft_pick,
    p.draft_team,
    p.seasons_experience,
    p.is_rookie,
    p.rookie_season,
    -- Sleeper live block: serving-only current state, as-of news_updated_at
    p.injury_status,
    p.injury_body_part,
    p.injury_notes,
    p.practice_participation,
    p.practice_description,
    p.news_updated_at,
    p.has_nflverse_match,
    p.has_sleeper_match,
    rt.team_key,
    t.team_abbreviation                                 as team_label,
    t.team_full_name                                    as team_name,
    rt.team_source,
    ng.game_key                                         as next_game_key,
    ng.opponent_team_key                                as next_opponent_team_key,
    nt.team_abbreviation                                as next_opponent_label,
    ng.is_home                                          as next_is_home,
    ng.game_datetime_et                                 as next_game_datetime_et,
    ng.season                                           as next_season,
    ng.week                                             as next_week,
    ng.season_type_name                                 as next_season_type_name
from weeks w
inner join players p
    on p.player_key = w.player_key
inner join resolved_team rt
    on rt.player_key = w.player_key
left join teams t
    on t.team_key = rt.team_key
left join next_game ng
    on ng.team_key = rt.team_key
left join teams nt
    on nt.team_key = ng.opponent_team_key
