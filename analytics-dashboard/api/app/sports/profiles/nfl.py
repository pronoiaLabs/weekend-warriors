from app.sports.capabilities import Capability as C
from app.sports.profile import SportProfile

# Vendors are the lowercase book names the odds feed writes. The list is what the
# slate's vendor chips offer; an unlisted book in the data is still served when
# asked for by name.
NFL = SportProfile(
    key="nfl",
    label="NFL",
    default_season=2026,
    tables={
        C.SCHEDULE: "app_game_slate",
        C.GAME_PROP_BOARD: "app_game_prop_board",
        C.TEAM_STANDINGS: "app_team_standings",
        C.TEAM_WEEKS: "app_team_weeks",
        C.TEAM_ALLOWED: "app_team_allowed",
        C.TEAM_ATS: "app_team_ats",
        C.PLAYER_LEADERS: "app_player_leaders",
        C.PLAYER_WEEKS: "app_player_weeks",
        C.PLAYER_WEEK_STATS: "app_player_week_stats",
        C.PLAYER_DEFENSE_WEEKS: "app_player_defense_weeks",
        C.LINE_HISTORY: "app_line_history",
        C.PROP_LINE_HISTORY: "app_prop_line_history",
        C.NEWS: "app_news_mentions",
        C.EXPLORE_PLAYER_GAMES: "app_explore_player_games",
        C.EXPLORE_DEFENDER_GAMES: "app_explore_defender_games",
        C.EXPLORE_TEAM_GAMES: "app_explore_team_games",
        C.EXPLORE_GAME_LINES: "app_explore_game_lines",
        C.EXPLORE_PLAYER_PROPS: "app_explore_player_props",
        C.EXPLORE_NEWS: "app_explore_news",
        C.EXPLORE_LINE_MOVES: "app_explore_line_moves",
    },
    extensions=("fantasy",),
    vendors=("draftkings", "fanduel", "caesars", "betmgm", "betrivers", "polymarket", "kalshi"),
    default_vendor="draftkings",
)
