"""One module per tile. A tile is a row model, the columns it selects, and a load
function that issues one select through app.sports.source and shapes the rows
lightly (grouping, default resolution). Routers import tiles; tiles import no
router and no sport by name."""
