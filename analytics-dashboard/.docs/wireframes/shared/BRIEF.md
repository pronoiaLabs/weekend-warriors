# Wireframe brief — Weekend Warriors NFL app redesign

Every wireframe page follows this brief so the nine pages read as one app. The product
thinking behind the pages lives in `docs/nfl-app-screens-plan.html` at the repo root
(the journey: catch up → go fishing at game level or player level → dig in at play grain).

## Files

- Pages live in `pages/<name>.html`. Shared assets are linked relatively:
  `<link rel="stylesheet" href="../shared/theme.css">` and
  `<script src="../shared/data.js"></script>` (defines global `WW`: `WW.teams[abbr]`,
  `WW.players` — real team colors/logos and real player headshots from the warehouse).
- One self-contained HTML file per page. No external libraries, no CDN scripts, no
  build step — open from disk and it works. Vanilla JS only. Inline `<style>` for
  page-specific CSS is expected (the real app ships page CSS with each page too);
  shared theme classes come from theme.css.

## Theme — Glass Prism (this is the current app's real CSS, reuse it)

- Dark graphite ground (`--bg: #0d0e11`), drifting aurora blobs, glass tiles
  (`.tile`, `.kpi`) with an iridescent hairline ring, ONE muted steel accent
  (`--accent`), sage `--pos` / rose `--neg` for good/bad numbers, `--warn` amber.
- Key existing classes you should reuse rather than reinvent: `.shell .topbar .brand
  .sport-switch .context .main .foot` (chrome); `.page-head .lede .hint .kpis .kpi
  .tile .tile-head .chips .chip .filters .crumbs .crumb-row .back` (scaffolding);
  `.trows .trow` generic row tables driven by `--cols` grid template, with `.rk .tm
  .n .pos .neg .sorted` cells; `.board .slots .slot-head .game .game-teams .team
  .game-line .game-wx .flag` (game-day board); `.game-head .matchup .line-strip
  .stat .prows .prow .pnum .pin .pins` (game page + prop rows); `.stand-row
  .week-row .allowed-row .split-row` (teams); `.move-card .move .spark .path-chart
  .legend` (markets); `.mention` (news rows); `.sheet` (explorer grid);
  `.stat-chart .margin-chart` (SVG chart patterns); `.q` (per-tile query expander).
- Wireframe addendum classes (bottom of theme.css): `.avatar` (+ `.sm .lg .xl`) with
  initials fallback, `.tlogo` (+ sizes), `.badge` (+ `.out .q .ok .acc`), `.wf-note`,
  and the edge agent dock (`.edge-fab`, `.edge-panel`, `.edge-msg`…).
- Numbers are tabular; labels are 10px uppercase letterspaced (`.l` pattern);
  big values thin-weight (see `.kpi .v`). Keep that typographic voice everywhere.
- You may restructure page LAYOUT freely (the user welcomes structural improvements)
  but never the design language: glass, one accent, quiet chrome, data-dense rows.

## Chrome skeleton (copy this structure exactly; swap the active dock link)

```html
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>PAGE — Weekend Warriors wireframe</title>
<link rel="stylesheet" href="../shared/theme.css">
<style>/* page-specific css */</style>
</head>
<body>
<div class="wf-note">wireframe · sample data</div>
<div class="aurora"><i></i><i></i><i></i></div>
<div class="aurora two"><i></i><i></i><i></i></div>
<div class="shell">
  <header class="topbar">
    <a class="brand" href="../index.html">
      <span class="mark"></span><span class="word">Weekend Warriors</span><span class="sub">analytics</span>
    </a>
    <nav class="sport-switch"><a class="on" href="#">NFL</a><a href="#">NCAAF</a></nav>
    <div class="context">
      <span class="ctx-item"><span class="l">Season</span><span class="v">2025 · Week 8</span></span>
      <span class="ctx-item"><span class="l">Data</span><span class="v">postgres</span></span>
    </div>
  </header>
  <main class="main"><!-- page content --></main>
  <footer class="foot"><span>Wireframe — zones annotated with the mart + route feeding them.</span><span>NFL_PROD_DB.APP → app.app_copy</span></footer>
</div>
<nav class="dock">
  <a href="pulse.html">Pulse</a>
  <a href="game-day.html">Game Day</a>
  <a href="players.html">Players</a>
  <a href="teams.html">Teams</a>
  <a href="markets.html">Markets</a>
  <a href="play-log.html">Play Log</a>
  <a href="explorer.html">Explorer</a>
</nav>
<button class="edge-fab" id="edgeFab" title="Edge agent">✦</button>
<aside class="edge-panel" id="edgePanel">
  <div class="edge-head">Edge agent<small>page-aware · sees your filters</small></div>
  <div class="edge-msgs"><!-- 2–3 sample messages CONTEXTUAL TO THIS PAGE --></div>
  <div class="edge-input"><input placeholder="Ask about this page…"></div>
</aside>
<script src="../shared/data.js"></script>
<script>
  document.getElementById('edgeFab').addEventListener('click', function () {
    document.getElementById('edgePanel').classList.toggle('open');
  });
  /* page scripts */
</script>
</body>
</html>
```

- Mark the current page's dock link with `class="active"`.
- The edge panel's sample conversation must fit the page (on the pond: "which props
  look soft here?"; on play log it drives the screen; etc.) and one bot reply should
  demonstrate the page-aware trick: the agent narrates that it just updated the page
  ("Sorted the board by projection − line and filtered to WRs — see left.").

## Canonical sample context (all pages share it, so cross-links feel real)

- Season 2025, Week 8. Vendor/book: DraftKings.
- The slate (fictional but consistent):
  - THU 8:15p: MIN @ LAR
  - SUN 1:00p: CIN @ CLE, GB @ PIT, NYJ @ NE, ATL @ MIA
  - SUN 4:25p: DAL @ SF, BAL @ ARI
  - SUN 8:20p: BUF @ KC  ← the marquee game
  - MON 8:15p: HOU @ DET
- Focus entities (detail pages + examples elsewhere):
  - Game detail: **BUF @ KC** (Allen vs Mahomes; both in WW.players)
  - Player detail: **Ja'Marr Chase** (CIN WR, in WW.players)
  - Team page: **Detroit Lions** (Gibbs, LaPorta, St. Brown in WW.players)
- Use players from `WW.players` wherever a player appears (real headshots). For
  role players not in the list, use the initials-only avatar (no img). Render from
  the WW object in JS where a list is long; hardcoding a few rows is fine too.
- Invent plausible stats/lines/EPA numbers; they're sample data. Keep them
  internally consistent within your page (records, lines, projections).

## Images

- Player headshot: `<span class="avatar"><img src="…" alt="" onerror="this.remove()">JC</span>`
  — initials sit underneath so a broken URL degrades gracefully.
- Team logo: `WW.teams[abbr].logo` (ESPN 500px, renders crisp small). Team color:
  set `style="--team: #97233F"` and use `.team-accent` or your own accent usage —
  sparingly, the app is near-monochrome; team color is a whisper (a 3px bar, a
  ring), never a background flood.

## Annotations (wireframes double as an API-payload review)

Each major zone/tile gets a small data-contract note using the existing `.q`
expander pattern: `<details class="q"><summary>data</summary><pre>mart: APP.PROP_BOARD
route: GET /api/nfl/games/{game_key}
fields: player, prop_type, line, projection, delta…</pre></details>` — collapsed by
default, one per tile, naming the mart + route + key fields feeding that zone.

## Don'ts

- Light mode exists and is handled ENTIRELY by the shared theme: theme.css carries a
  light palette behind `html[data-theme="light"]` and data.js injects the topbar
  toggle automatically. Your job is only to never hardcode a color — use tokens
  (`var(--bg) --surface --ink-* --line --accent --pos --neg --warn`) or
  `color-mix(...)` over tokens for any tint, so both themes work untouched.
- No second accent color, no rounded-corner inconsistency (radius
  is `--r: 18px` for tiles, 999px for pills), no dense borders (hairlines only).
- No lorem ipsum — every string should look like the real product.
- Don't invent new global chrome (topbar/dock/foot stay as specced).
- Don't link pages that don't exist; the nine pages are: pulse, game-day,
  game-detail, players, player-detail, play-log, teams, markets, explorer
  (+ ../index.html).
