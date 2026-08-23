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
