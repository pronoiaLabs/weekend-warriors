from app.sports.profile import SportProfile

# No APP marts yet: the NCAAF mart set lands in a later phase. An empty table map
# means the nav shows nothing but the explorer, and every page route 404s with a
# message naming the missing capability rather than an empty tile.
NCAAF = SportProfile(
    key="ncaaf",
    label="NCAAF",
    default_season=2026,
    tables={},
    extensions=("rankings",),
)
