/*
    app_game_prop_board -- the game page, one row per player prop.
    Grain: game x player x vendor x prop_type, the grain of
    fact_player_prop_closing; the key is that fact's key. Every prop row
    appears exactly once, whether or not its prop type maps to a box-score stat.

    Each row joins the three things a prop player looks at first:
      the line            fact_player_prop_closing at this book (line, open, movement, odds)
      the player's form   from fact_player_game_offense for the stat the prop is about,
                          in two windows, both strictly BEFORE this game (what was
                          knowable at kickoff, never hindsight):
                            trailing: the last ten games of the same season type,
                                      crossing seasons, so week 1 has a basis
                            to date:  this season only, empty until the season starts
                          Each gives games, average, how many cleared THIS line; the
                          trailing window also gives the last three values.
      the matchup         what the opponent allows per game to the player's position
                          in the prop's stat, with its rank (app_team_allowed)
                          (QB passing, RB rushing, WR and TE receiving), ranked across
                          teams where 1 allows the most, for this season; the prior
                          season stands in until this season has games.
      the projection      fact_sleeper_projection_latest joined on (player_key,
                          game_key) -- already bridged and pre-kickoff-selected. The
                          prop's stat_key picks the projection column in a CASE here
                          (not the seed: seeds cannot hold the scoring_touchdowns
                          sum). Unmapped prop types and players without a projection
                          row carry NULLs and has_projection false. Coverage follows
                          Sleeper's calendar: projections exist for the league's
                          CURRENT week, so a board read far ahead of kickoff (or in
                          preseason, when Sleeper's clock and the props diverge) is
                          honestly empty until the weeks align.
      usage form          trailing three games of the same season type strictly
                          before kickoff, from the same offense rows the form block
                          reads: target share, air-yards share, snap pct (nflverse
                          offense_pct, Sleeper snap share standing in when absent).
                          Averages of per-game shares -- a display convention, not
                          the additive contract.

    The prop type to stat mapping is a seed (seed_nfl_prop_stat_map), because
    prop_type is a lowercased passthrough from the feed with no enumeration in
    the repo. Unmapped types (first_td, the quarter and half touchdown props)
    keep their line and odds and carry NULL form columns; nothing is guessed.

    Team and opponent: the prop fact carries only the game's two teams, and
    dim_player has no team by design. The player's team is the team of their
    most recent offensive box score on or before the game when that box score
    is from the prop's season; before the season's first box score it is the
    roster feed's current team (stg_nfl__players.current_team_id, what the news
    fact uses), falling back to the prior-season box score only when the roster
    feed has no team. A prior-season box score alone would put every offseason
    mover on the wrong side of the board (measured on the 2026 week 1 slate:
    players priced for NE at SEA carried GB and PHI labels). The opponent is the
    other side of the game; a player whose team is neither side, or who has no
    team at all, keeps NULL opponent and side and still appears.

    Actual and outcome are filled once the game is completed and the stat is
    mapped: over / under / push against line_value for over_under markets, hit /
    miss against the threshold for milestone markets (a missing threshold means
    "at least one").
*/

with props as (

    select * from {{ ref('fact_player_prop_closing') }}

),

stat_map as (

    select * from {{ ref('seed_nfl_prop_stat_map') }}

),

players as (

    select * from {{ ref('dim_player') }}

),

current_team as (

    select
        player_id,
        current_team_key
    from {{ ref('stg_nfl__players') }}
    where current_team_id is not null

),

games as (

    select * from {{ ref('dim_game') }}

),

teams as (

    select * from {{ ref('dim_team') }}

),

offense as (

    select
        o.player_key,
        o.game_key,
        o.team_key,
        o.season,
        o.season_type,
        g.game_datetime,
        g.home_team_key,
        g.away_team_key,
        o.receiving_yards,
        o.receptions,
        o.rushing_yards,
        o.passing_yards,
        o.passing_touchdowns,
        coalesce(o.rushing_touchdowns, 0) + coalesce(o.receiving_touchdowns, 0)
                                                        as scoring_touchdowns,
        o.target_share,
        o.air_yards_share,
        coalesce(o.offense_pct, o.off_snap_share)       as snap_pct
    from {{ ref('fact_player_game_offense') }} o
    inner join games g
        on g.game_key = o.game_key

),

projections as (

    select
        player_key,
        game_key,
        rec,
        rec_yd,
        rec_td,
        rush_yd,
        rush_td,
        pass_yd,
        pass_td,
        projection_as_of
    from {{ ref('fact_sleeper_projection_latest') }}

),

-- one row per player-game-stat, so any prop type joins on its stat_key
offense_long as (

    {% set stats = ['receiving_yards', 'receptions', 'rushing_yards', 'passing_yards', 'passing_touchdowns', 'scoring_touchdowns'] %}
    {% for stat in stats %}
    select
        player_key, game_key, team_key, season, season_type, game_datetime,
        home_team_key, away_team_key,
        '{{ stat }}'                                    as stat_key,
        {{ stat }}                                      as stat_value
    from offense
    {% if not loop.last %}union all{% endif %}
    {% endfor %}

),

-- the prop with its stat and the game it belongs to
prop_base as (

    select
        p.*,
        m.stat_key,
        m.stat_label,
        g.game_datetime                                 as game_dt,
        g.game_datetime_et,
        g.is_completed,
        g.season_type_name                              as game_season_type_name,
        pl.player_id                                    as dim_player_id,
        pl.full_name                                    as player_name,
        pl.position_abbreviation                        as position,
        pl.position_name,
        pl.position_group
    from props p
    left join stat_map m
        on m.prop_type = p.prop_type
    inner join games g
        on g.game_key = p.game_key
    left join players pl
        on pl.player_key = p.player_key

),

-- the player's most recent box score on or before kickoff, with its season
box_score_team as (

    select
        pb.game_player_vendor_prop_key,
        o.team_key,
        o.season                                        as box_score_season
    from prop_base pb
    inner join offense o
        on o.player_key = pb.player_key
       and o.game_datetime <= pb.game_dt
    qualify row_number() over (
        partition by pb.game_player_vendor_prop_key
        order by o.game_datetime desc
    ) = 1

),

-- the player's team as of the game: this season's box score wins; before the
-- season's first box score the roster feed does, so offseason moves are right
team_as_of as (

    select
        pb.game_player_vendor_prop_key,
        case
            when bt.box_score_season = pb.season then bt.team_key
            else coalesce(ct.current_team_key, bt.team_key)
        end                                             as team_key
    from prop_base pb
    left join box_score_team bt
        on bt.game_player_vendor_prop_key = pb.game_player_vendor_prop_key
    left join current_team ct
        on ct.player_id = pb.dim_player_id

),

-- every prior game of the same season type for the prop's stat, ranked newest first
prior_games as (

    select
        pb.game_player_vendor_prop_key,
        pb.line_value,
        pb.season                                       as prop_season,
        ol.season,
        ol.game_datetime,
        ol.stat_value,
        row_number() over (
            partition by pb.game_player_vendor_prop_key
            order by ol.game_datetime desc
        )                                               as recency
    from prop_base pb
    inner join offense_long ol
        on ol.player_key = pb.player_key
       and ol.stat_key = pb.stat_key
       and ol.season_type = pb.season_type
       and ol.game_datetime < pb.game_dt

),

form_trailing as (

    select
        game_player_vendor_prop_key,
        count(*)                                        as trailing_games,
        avg(stat_value)                                 as trailing_avg,
        sum(iff(line_value is not null and stat_value > line_value, 1, 0))
                                                        as trailing_over_line,
        array_slice(
            array_agg(stat_value) within group (order by game_datetime desc),
            0, 3
        )                                               as stat_last3
    from prior_games
    where recency <= 10
    group by 1

),

-- usage is per player-game, not per stat: the same three trailing games feed
-- every prop the player has on this board
usage_prior as (

    select
        pb.game_player_vendor_prop_key,
        o.target_share,
        o.air_yards_share,
        o.snap_pct,
        row_number() over (
            partition by pb.game_player_vendor_prop_key
            order by o.game_datetime desc
        )                                               as recency
    from prop_base pb
    inner join offense o
        on o.player_key = pb.player_key
       and o.season_type = pb.season_type
       and o.game_datetime < pb.game_dt

),

usage_form as (

    select
        game_player_vendor_prop_key,
        count(*)                                        as usage_trailing3_games,
        avg(target_share)                               as target_share_trailing3,
        avg(air_yards_share)                            as air_yards_share_trailing3,
        avg(snap_pct)                                   as snap_pct_trailing3
    from usage_prior
    where recency <= 3
    group by 1

),

form_to_date as (

    select
        game_player_vendor_prop_key,
        count(*)                                        as games_played_to_date,
        avg(stat_value)                                 as stat_avg_to_date,
        sum(iff(line_value is not null and stat_value > line_value, 1, 0))
                                                        as games_over_line_to_date
    from prior_games
    where season = prop_season
    group by 1

),

-- the actual for completed games
actual as (

    select
        pb.game_player_vendor_prop_key,
        ol.stat_value                                   as actual_value
    from prop_base pb
    inner join offense_long ol
        on ol.player_key = pb.player_key
       and ol.game_key = pb.game_key
       and ol.stat_key = pb.stat_key

),

-- what each defense allows, by position and stat: one definition, shared with
-- the team page (app_team_allowed). Joined on the prop's own stat, so a RB
-- receiving prop reads the RB receiving row, not the rushing one.
allowed_ranked as (

    select
        team_key                                        as defense_team_key,
        season,
        season_type,
        position,
        stat_key,
        allowed_per_game,
        allowed_rank,
        teams_ranked
    from {{ ref('app_team_allowed') }}

),

-- latest mention in the week before the game
latest_news as (

    select
        pb.game_player_vendor_prop_key,
        n.headline                                      as news_headline,
        n.context                                       as news_context,
        n.feed                                          as news_feed,
        n.published_at                                  as news_published_at
    from prop_base pb
    inner join {{ ref('fact_player_news_mention') }} n
        on n.player_key = pb.player_key
       and n.published_date between dateadd(day, -7, pb.game_date) and pb.game_date
    qualify row_number() over (
        partition by pb.game_player_vendor_prop_key
        order by n.published_at desc
    ) = 1

),

sided as (

    select
        pb.*,
        t.team_key,
        case
            when t.team_key = pb.home_team_key then pb.away_team_key
            when t.team_key = pb.away_team_key then pb.home_team_key
        end                                             as opponent_team_key,
        case
            when t.team_key = pb.home_team_key then true
            when t.team_key = pb.away_team_key then false
        end                                             as is_home
    from prop_base pb
    left join team_as_of t
        on t.game_player_vendor_prop_key = pb.game_player_vendor_prop_key

)

select
    s.game_player_vendor_prop_key                       as app_game_prop_board_key,
    s.game_player_vendor_prop_key,
    s.game_key,
    s.game_id,

    -- when
    s.season,
    s.week,
    s.season_type,
    s.game_season_type_name                             as season_type_name,
    s.game_date,
    s.game_datetime_et,
    s.is_completed,

    -- who
    s.player_key,
    s.player_id,
    s.player_name,
    s.position,
    s.position_name,
    s.position_group,
    s.team_key,
    tt.team_abbreviation                                as team_label,
    tt.team_full_name                                   as team_name,
    s.is_home,
    s.opponent_team_key,
    ot.team_abbreviation                                as opponent_label,
    ot.team_full_name                                   as opponent_name,
    s.home_team_key,
    s.away_team_key,

    -- the line
    s.vendor,
    s.prop_type,
    s.market_type,
    s.stat_key,
    s.stat_label,
    s.line_value,
    s.opening_line_value,
    s.line_movement,
    s.over_odds,
    s.under_odds,
    s.market_odds,
    s.opening_over_odds,
    s.opening_under_odds,
    s.opening_market_odds,
    s.selected_snapshot_at                              as line_selected_at,

    -- form, trailing ten games of this season type before this game
    ft.trailing_games,
    ft.trailing_avg,
    ft.stat_last3,
    ft.trailing_over_line,
    iff(ft.trailing_games > 0 and s.line_value is not null,
        ft.trailing_over_line / ft.trailing_games, null)
                                                        as trailing_hit_rate,
    iff(s.line_value is not null, ft.trailing_avg - s.line_value, null)
                                                        as gap_to_line,

    -- form, this season to date before this game
    coalesce(fd.games_played_to_date, 0)                as games_played_to_date,
    fd.stat_avg_to_date,
    fd.games_over_line_to_date,
    iff(fd.games_played_to_date > 0 and s.line_value is not null,
        fd.games_over_line_to_date / fd.games_played_to_date, null)
                                                        as hit_rate_over_line,

    -- the projection: Sleeper's number for this prop's stat, and the lean
    case s.stat_key
        when 'receiving_yards'      then pj.rec_yd
        when 'receptions'           then pj.rec
        when 'rushing_yards'        then pj.rush_yd
        when 'passing_yards'        then pj.pass_yd
        when 'passing_touchdowns'   then pj.pass_td
        when 'scoring_touchdowns'   then iff(pj.player_key is null, null,
                                             coalesce(pj.rush_td, 0) + coalesce(pj.rec_td, 0))
    end                                                 as projection_value,
    iff(s.line_value is not null, projection_value - s.line_value, null)
                                                        as projection_vs_line,
    (projection_value is not null)                      as has_projection,
    pj.projection_as_of                                 as projection_captured_at,

    -- usage form: trailing three games before this one
    coalesce(uf.usage_trailing3_games, 0)               as usage_trailing3_games,
    uf.target_share_trailing3,
    uf.air_yards_share_trailing3,
    uf.snap_pct_trailing3,

    -- the matchup: what this defense allows to this position
    coalesce(ac.stat_key, ap.stat_key)                  as opponent_allowed_stat_key,
    coalesce(ac.allowed_per_game, ap.allowed_per_game)  as opponent_allowed_per_game,
    coalesce(ac.allowed_rank, ap.allowed_rank)          as opponent_allowed_rank,
    coalesce(ac.teams_ranked, ap.teams_ranked)          as opponent_allowed_teams_ranked,
    case
        when ac.allowed_rank is not null then s.season
        when ap.allowed_rank is not null then s.season - 1
    end                                                 as opponent_allowed_season,

    -- news
    ln.news_headline,
    ln.news_context,
    ln.news_feed,
    ln.news_published_at,

    -- result, once played and mappable
    a.actual_value,
    case
        when not s.is_completed or a.actual_value is null then null
        when s.market_type = 'over_under' and s.line_value is not null then
            case when a.actual_value > s.line_value then 'over'
                 when a.actual_value < s.line_value then 'under'
                 else 'push' end
        when s.market_type = 'milestone' then
            iff(a.actual_value >= coalesce(s.line_value, 1), 'hit', 'miss')
    end                                                 as outcome

from sided s
left join teams tt
    on tt.team_key = s.team_key
left join teams ot
    on ot.team_key = s.opponent_team_key
left join form_trailing ft
    on ft.game_player_vendor_prop_key = s.game_player_vendor_prop_key
left join form_to_date fd
    on fd.game_player_vendor_prop_key = s.game_player_vendor_prop_key
left join projections pj
    on pj.player_key = s.player_key
   and pj.game_key = s.game_key
left join usage_form uf
    on uf.game_player_vendor_prop_key = s.game_player_vendor_prop_key
left join actual a
    on a.game_player_vendor_prop_key = s.game_player_vendor_prop_key
left join allowed_ranked ac
    on ac.defense_team_key = s.opponent_team_key
   and ac.season = s.season
   and ac.season_type = s.season_type
   and ac.position = s.position
   and ac.stat_key = s.stat_key
left join allowed_ranked ap
    on ap.defense_team_key = s.opponent_team_key
   and ap.season = s.season - 1
   and ap.season_type = s.season_type
   and ap.position = s.position
   and ap.stat_key = s.stat_key
left join latest_news ln
    on ln.game_player_vendor_prop_key = s.game_player_vendor_prop_key
