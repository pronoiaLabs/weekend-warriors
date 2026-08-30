-- The vocabulary pin: app_player_situation_usage copies its bucket CASEs from
-- fact_team_game_situation, and this test fails the moment the copies drift.
-- For a player who appeared in every one of his team's games for the season
-- type, on one team, with a nflverse match in each, his team_dropbacks per
-- bucket must equal the fact's dropbacks (side = 'offense') rolled up to the
-- same bucket for that team-season -- both count the same pass plays.

with player_games as (

    select
        player_key,
        season,
        season_type,
        max(team_key)                                   as team_key,
        count(*)                                        as games,
        count_if(not has_nflverse)                      as unmatched_games,
        count(distinct team_key)                        as teams_count
    from {{ ref('app_player_weeks') }}
    group by 1, 2, 3

),

team_games as (

    select
        team_key,
        season,
        season_type,
        count(*)                                        as team_game_count
    from {{ ref('fact_team_game_offense') }}
    group by 1, 2, 3

),

full_season_players as (

    select pg.player_key, pg.season, pg.season_type, pg.team_key
    from player_games pg
    inner join team_games tg
        on tg.team_key = pg.team_key
       and tg.season = pg.season
       and tg.season_type = pg.season_type
    where pg.teams_count = 1
      and pg.unmatched_games = 0
      and pg.games = tg.team_game_count

),

fact_rollup as (

    {% for cut in [('down', 'down_bucket'), ('field_zone', 'field_zone'), ('script', 'game_script')] %}
    select
        team_key,
        season,
        season_type,
        '{{ cut[0] }}'                                  as bucket_type,
        {{ cut[1] }}                                    as bucket,
        sum(dropbacks)                                  as team_dropbacks
    from {{ ref('fact_team_game_situation') }}
    where side = 'offense'
      and {{ cut[1] }} is not null
    group by 1, 2, 3, 5
    {% if not loop.last %}union all{% endif %}
    {% endfor %}

)

select
    u.player_key,
    u.season,
    u.season_type,
    u.bucket_type,
    u.bucket,
    u.team_dropbacks                                    as usage_dropbacks,
    f.team_dropbacks                                    as fact_dropbacks
from {{ ref('app_player_situation_usage') }} u
inner join full_season_players fs
    on fs.player_key = u.player_key
   and fs.season = u.season
   and fs.season_type = u.season_type
inner join fact_rollup f
    on f.team_key = fs.team_key
   and f.season = u.season
   and f.season_type = u.season_type
   and f.bucket_type = u.bucket_type
   and f.bucket = u.bucket
where u.team_dropbacks <> f.team_dropbacks
