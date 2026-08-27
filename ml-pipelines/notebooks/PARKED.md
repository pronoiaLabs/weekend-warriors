# Parked — not v1

v1 is the dedicated-model fleet under [`v1/`](v1/): inspect FEATURES, walk-forward 2023–24 / 2025, register on `NFL_PROD_DB.ML`, write a pred table. These items were on the ML list and stayed out on purpose. Do not start them because a notebook exists.

## Need data or a later grain

| Item | Why it waited |
|---|---|
| `first_td` | Needs play-level scoring order. Competing risks, not a box-score label. |
| Period TDs (1Q / 1H / …) | No player-period TD on CORE. Team quarter points are not a player TD. |
| QB anytime-TD variant `I(pass TD + rush TD)` | Different label than skill-player anytime TD (`I(rush + rec TD)`). Starter QBs are almost always 1; passing-TD count is the better v1 market. |
| Separate rush-TD / rec-TD counts | Anytime TD covers v1. Split when the market is “rush TDs,” not “anytime.” |
| `feat_player_prop_train` | Later FEATURES grain (`player × game × family`). Rolling + weather + CORE join is enough to fit. |
| CLV / residual vs close | No 2023–25 closes. Live `ODDS` / `PLAYER_PROPS` are current-line only. Opening is not close. |
| `P(Y > line)` from a distribution | v1 is a point model (MAE / Brier). A prop needs mean + variance, then a 2026 line at score time — the line is not in X. |
| `feat_player_availability` | Injury gate so healthy scratches are not trained as true zeros. |
| Timezone / miles travel | `dim_stadium` has IANA tz / lat / lon. Parked after `is_short_week`. |
| Weather ablation | Same yards/TD model with vs without the weather products. Keep the columns only if 2025 walk-forward moves. |
| Beat-the-mean / promote a version | `BREEZY_STINGRAY_2` exists. Registering is not promoting. |

## Explicitly not on the list

- A dedicated weather-only scorer (42 windy games; role is the signal)
- Snowflake Feature Store as a rewrite of dbt FEATURES
- Cortex agent tools on FEATURES or `NFL_PROD_DB.ML`
- A scorer inside `SP_DBT_BUILD`
- Kicker or DST models
- DFS as its own model (FanDuel / DraftKings points already live on CORE)
- Correlation / copula for same-game parlays or DFS stacks
- Training on the 2026 offer table (ungraded, tiny)

## When one of these unblocks

Historical closes (Odds API or an archive) unlock CLV and “score vs line.” Play-level order unlocks `first_td`. An availability mart unlocks a cleaner player gate. Until then, cook the v1 notebooks.
