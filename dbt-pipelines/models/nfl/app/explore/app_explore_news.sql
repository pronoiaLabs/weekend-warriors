{{
    config(
        materialized='table'
    )
}}

/*
    app_explore_news -- the Explorer's news sheet. One row per mention
    (app_news_mentions) with the player, team, feed and headline, and the next
    game the article points at.
*/

select
    mention_key                                         as row_id,
    published_at,
    published_date,
    feed,
    player_name,
    is_player_resolved,
    position,
    team_label                                          as team,
    headline,
    context,
    detail,
    url,
    resolution_method,
    next_game_week,
    next_game_datetime_et,
    next_opponent_label                                 as next_opponent,
    next_game_is_home,
    days_to_next_game
from {{ ref('app_news_mentions') }}
