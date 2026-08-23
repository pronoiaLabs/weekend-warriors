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
    PLAYER_PERFORMANCE = "player_performance"  # app_player_* (later phase)
    GAME_ODDS = "game_odds"                # app_market_lines (later phase)
    PLAYER_PROPS = "player_props"          # app_props_edge, app_prop_history (later phase)
    NEWS = "news"                          # app_news_mentions (later phase)
