{{
    config(
        materialized='table'
    )
}}

/*
    app_status_board -- the Pulse's status zone: who carries a designation or a
    live status change, with the practice line, the next man up, and the game
    it matters for.

    Grain: player (one row per player currently worth watching). Two sources,
    report first:

      report  fact_injury_report rows filed for the team's NEXT non-completed
              game -- the league's official designation (Out, Doubtful,
              Questionable). The filing is the record.
      live    dim_player's Sleeper block (injury_status set, is_active) for
              players with NO current filing -- the between-filings signal.
              Serving-only current state, exactly as dim_player documents it.

    Honest v1 limits, by design rather than accident:

      * The injuries feed is MERGED on its natural key, so only the latest
        filing per week survives -- a true Wed/Thu/Fri practice ladder is not
        reconstructible today. practice_wed/thu/fri carry the letter (D/L/F)
        only for the weekday the surviving filing was modified on; the other
        days are NULL and the page renders them empty. NULL is "not filed",
        never "did not practice". The fix is an appended daily snapshot of the
        feed; until then this column set is one-day-truthful.
      * The ripple is depth-chart-mechanical: for Out/Doubtful players, the
        next depth_rank at the same team + formation + position (+ slot) on
        the chart for that game. No usage or route-share claims -- those need
        the Phase-3 situation marts. NULL when the player is not on the chart.
      * Team for live-only rows comes from the player's latest depth-chart
        appearance (dim_player deliberately has no team); recently moved
        players can show a stale or NULL team, rendered as a dash.
      * Unbridged players (no player_key) are dropped: the page needs identity
        and headshots, and bridge coverage makes this a sliver.
*/

with players as (

    select * from {{ ref('dim_player') }}

),

teams as (

    select * from {{ ref('dim_team') }}

),

-- each team's next non-completed game (the news mart's pattern, team-anchored)
next_game as (

    select
        t.team_key,
        g.game_key,
        g.game_datetime_et                              as game_datetime_et,
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

),

report as (

    select
        f.player_key,
        f.team_key,
        f.game_key,
        f.report_status                                 as designation,
        f.report_primary_injury                         as injury,
        f.report_secondary_injury                       as injury_detail,
        f.practice_status,
        f.modified_at                                   as report_modified_at
    from {{ ref('fact_injury_report') }} f
    inner join next_game ng
        on  ng.team_key = f.team_key
        and ng.game_key = f.game_key
    where f.player_key is not null

),

-- latest depth-chart appearance per player: the team resolver for live rows.
-- Ordered by the chart's game, tie-broken by the daily chart date.
latest_chart_team as (

    select
        d.player_key,
        d.team_key
    from {{ ref('fact_depth_chart') }} d
    inner join {{ ref('dim_game') }} g
        on g.game_key = d.game_key
    where d.player_key is not null
    qualify row_number() over (
        partition by d.player_key
        order by g.game_datetime desc, d.chart_as_of desc nulls last
    ) = 1

),

live as (

    select
        p.player_key,
        lct.team_key
    from players p
    left join latest_chart_team lct
        on lct.player_key = p.player_key
    where p.injury_status is not null
      and p.is_active
      and not exists (select 1 from report r where r.player_key = p.player_key)

),

-- the ripple: next man up at the injured player's primary slot on the chart
-- for the game the report is filed against
chart_slots as (

    select
        game_key,
        team_key,
        chart_source,
        formation,
        position,
        coalesce(depth_slot, -1)                        as depth_slot_n,
        depth_rank,
        player_key,
        player_name
    from {{ ref('fact_depth_chart') }}

),

primary_slot as (

    select s.*
    from chart_slots s
    inner join report r
        on  r.player_key = s.player_key
        and r.game_key = s.game_key
    where r.designation in ('Out', 'Doubtful')
    qualify row_number() over (
        partition by s.player_key, s.game_key
        order by s.depth_rank, s.formation, s.position
    ) = 1

),

ripple as (

    select
        mine.player_key,
        mine.game_key,
        nxt.player_key                                  as backup_player_key,
        nxt.player_name                                 as backup_player_name,
        nxt.depth_rank                                  as backup_depth_rank
    from primary_slot mine
    inner join chart_slots nxt
        on  nxt.game_key = mine.game_key
        and nxt.team_key = mine.team_key
        and nxt.chart_source = mine.chart_source
        and nxt.formation = mine.formation
        and nxt.position = mine.position
        and nxt.depth_slot_n = mine.depth_slot_n
        and nxt.depth_rank > mine.depth_rank
        and nxt.player_key is distinct from mine.player_key
    qualify row_number() over (
        partition by mine.player_key, mine.game_key
        order by nxt.depth_rank
    ) = 1

),

unioned as (

    select
        player_key,
        team_key,
        'report'                                        as status_source,
        designation,
        injury,
        injury_detail,
        practice_status,
        report_modified_at
    from report

    union all

    select
        player_key,
        team_key,
        'live'                                          as status_source,
        null                                            as designation,
        null                                            as injury,
        null                                            as injury_detail,
        null                                            as practice_status,
        null                                            as report_modified_at
    from live

)

select
    u.player_key                                        as app_status_board_key,
    u.player_key,
    p.player_id,
    p.full_name                                         as player_name,
    p.position_abbreviation                             as position,
    p.position_name,
    p.position_group,
    p.headshot_url,
    p.sleeper_player_id,

    u.team_key,
    t.team_abbreviation                                 as team_label,
    t.team_full_name                                    as team_name,

    u.status_source,
    u.designation,
    case u.designation
        when 'Out'          then 1
        when 'Doubtful'     then 2
        when 'Questionable' then 3
        else 4
    end                                                 as designation_order,
    u.injury,
    u.injury_detail,
    u.practice_status,
    -- one-day-truthful ladder: the letter lands only on the filing's weekday
    {% for day in ['Wed', 'Thu', 'Fri'] %}
    iff(
        dayname(convert_timezone('America/New_York', u.report_modified_at)) = '{{ day }}',
        case
            when u.practice_status ilike '%did not%' then 'D'
            when u.practice_status ilike '%limited%' then 'L'
            when u.practice_status ilike '%full%'    then 'F'
        end,
        null
    )                                                   as practice_{{ day | lower }},
    {% endfor %}
    u.report_modified_at,

    -- serving-only live block, on every row (report rows carry it too: the
    -- filing is the record, this is the "as of now" overlay)
    p.injury_status                                     as live_injury_status,
    p.practice_participation                            as live_practice_participation,
    p.depth_chart_position,
    p.depth_chart_order,
    p.news_updated_at,

    r.backup_player_key,
    r.backup_player_name,
    r.backup_depth_rank,
    iff(r.backup_player_name is not null,
        'Next up: ' || r.backup_player_name || ' (depth ' || r.backup_depth_rank || ')',
        null)                                           as ripple_note,

    ng.game_key,
    ng.game_datetime_et,
    ng.season,
    ng.week,
    ng.season_type_name,
    ng.opponent_team_key,
    ot.team_abbreviation                                as opponent_label,
    ng.is_home

from unioned u
inner join players p
    on p.player_key = u.player_key
left join teams t
    on t.team_key = u.team_key
left join next_game ng
    on ng.team_key = u.team_key
left join teams ot
    on ot.team_key = ng.opponent_team_key
left join ripple r
    on r.player_key = u.player_key
