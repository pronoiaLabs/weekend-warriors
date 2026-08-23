{{
    config(
        materialized='table'
    )
}}

/*
    app_news_mentions -- the news page: every resolved player mention with its
    context and the player's next game.

    Grain: mention (the grain of fact_player_news_mention). Carries the player's
    identity and position, the team the article attributed him to, the feed and
    headline, how the name was resolved (so the page can show a confidence
    cue), and the team's next scheduled game after the article: key, kickoff,
    opponent and days away, from dim_game, so "who is he playing next" needs no
    second lookup. NULL next game once the season's schedule is exhausted.

    A mention whose name did not resolve to a player keeps its row with a NULL
    player and is_player_resolved = false: it is still news about the team,
    and the page shows the name as the article wrote it.
*/

with mentions as (

    select * from {{ ref('fact_player_news_mention') }}

),

players as (

    select * from {{ ref('dim_player') }}

),

teams as (

    select * from {{ ref('dim_team') }}

),

games as (

    select * from {{ ref('dim_game') }}

),

-- the mention team's first game on or after the article
next_game as (

    select
        m.mention_key,
        g.game_key                                      as next_game_key,
        g.game_datetime_et                              as next_game_datetime_et,
        g.season                                        as next_game_season,
        g.week                                          as next_game_week,
        g.season_type_name                              as next_game_season_type_name,
        iff(g.home_team_key = m.mention_team_key, g.away_team_key, g.home_team_key)
                                                        as next_opponent_team_key,
        g.home_team_key = m.mention_team_key            as next_game_is_home
    from mentions m
    inner join games g
        on (g.home_team_key = m.mention_team_key or g.away_team_key = m.mention_team_key)
       and g.game_datetime >= m.published_at
       and not g.is_completed
    qualify row_number() over (partition by m.mention_key order by g.game_datetime) = 1

)

select
    m.mention_key                                       as app_news_mentions_key,
    m.mention_key,
    m.article_key,
    m.player_key,
    m.player_id,
    m.player_key is not null                            as is_player_resolved,
    coalesce(p.full_name, m.player_name_text)           as player_name,
    p.position_abbreviation                             as position,
    p.position_name,
    p.position_group,
    m.mention_team_key                                  as team_key,
    t.team_abbreviation                                 as team_label,
    t.team_full_name                                    as team_name,
    m.published_at,
    m.published_date,
    m.feed,
    m.headline,
    m.context,
    m.detail,
    m.url,
    m.player_name_text                                  as player_name_in_article,
    m.team_text                                         as team_in_article,
    m.extract_mode,
    m.resolution_method,
    m.candidate_count,
    ng.next_game_key,
    ng.next_game_datetime_et,
    ng.next_game_season,
    ng.next_game_week,
    ng.next_game_season_type_name,
    ng.next_opponent_team_key,
    ot.team_abbreviation                                as next_opponent_label,
    ot.team_full_name                                   as next_opponent_name,
    ng.next_game_is_home,
    iff(ng.next_game_datetime_et is not null,
        datediff(day, m.published_date, ng.next_game_datetime_et::date), null)
                                                        as days_to_next_game
from mentions m
left join players p
    on p.player_key = m.player_key
left join teams t
    on t.team_key = m.mention_team_key
left join next_game ng
    on ng.mention_key = m.mention_key
left join teams ot
    on ot.team_key = ng.next_opponent_team_key
