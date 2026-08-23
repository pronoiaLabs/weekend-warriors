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
    },
    extensions=("fantasy",),
    vendors=("draftkings", "fanduel", "caesars", "betmgm", "betrivers", "polymarket", "kalshi"),
    default_vendor="draftkings",
)
