"""What a sport can show. A capability is present when the sport's APP layer has
the mart behind it; routers 404 on an absent capability and the frontend renders
its nav from this list, so no component ever tests the sport by name."""

from enum import StrEnum


class Capability(StrEnum):
    SCHEDULE = "schedule"                  # app_game_slate
    GAME_PROP_BOARD = "game_prop_board"    # app_game_prop_board
    TEAM_STANDINGS = "team_standings"      # app_team_standings
    TEAM_WEEKS = "team_weeks"              # app_team_weeks
    TEAM_ALLOWED = "team_allowed"          # app_team_allowed
    TEAM_ATS = "team_ats"                  # app_team_ats
    PLAYER_LEADERS = "player_leaders"      # app_player_leaders
    PLAYER_WEEKS = "player_weeks"          # app_player_weeks
    PLAYER_WEEK_STATS = "player_week_stats"  # app_player_week_stats
    PLAYER_DEFENSE_WEEKS = "player_defense_weeks"  # app_player_defense_weeks
    LINE_HISTORY = "line_history"          # app_line_history
    PROP_LINE_HISTORY = "prop_line_history"  # app_prop_line_history
    NEWS = "news"                          # app_news_mentions
    STATUS_BOARD = "status_board"          # app_status_board
    TRENDING_PLAYERS = "trending_players"  # app_trending_players
    MARKET_MOVERS = "market_movers"        # app_market_movers
    TEAM_BRANDING = "team_branding"        # app_team_branding
    # the Explorer's sheets: flat, one table per grain
    EXPLORE_PLAYER_GAMES = "explore_player_games"      # app_explore_player_games
    EXPLORE_DEFENDER_GAMES = "explore_defender_games"  # app_explore_defender_games
    EXPLORE_TEAM_GAMES = "explore_team_games"          # app_explore_team_games
    EXPLORE_GAME_LINES = "explore_game_lines"          # app_explore_game_lines
    EXPLORE_PLAYER_PROPS = "explore_player_props"      # app_explore_player_props
    EXPLORE_NEWS = "explore_news"                      # app_explore_news
    EXPLORE_LINE_MOVES = "explore_line_moves"          # app_explore_line_moves
