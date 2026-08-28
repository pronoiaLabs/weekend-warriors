#!/usr/bin/env bash
# Route walk in headless Chrome against the built app in fixture mode.
#
# Starts the API on a spare port serving web/dist, renders each route with a
# virtual-time budget so fetches settle, and fails on any console error or on a
# page missing the text it must show. No Snowflake connection: the API runs with
# ANALYTICS_DASHBOARD_DATA=fixtures, so this is the same walk CI could do.
#
#   make smoke            # builds web/dist first
#   CHROME=/path/to/chrome make smoke
set -euo pipefail

cd "$(dirname "$0")/.."
PORT="${SMOKE_PORT:-8017}"
# virtual time per route, ms: the pages settle on fixtures in well under a
# second, and the walk is 27 routes, so 2s keeps the whole run near a minute
BUDGET="${SMOKE_BUDGET_MS:-4000}"
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
if [ ! -x "$CHROME" ]; then
  CHROME="$(command -v google-chrome || command -v chromium || command -v chromium-browser || true)"
fi
if [ -z "$CHROME" ] || [ ! -x "$CHROME" ]; then
  echo "smoke: no Chrome found; set CHROME=/path/to/chrome" >&2
  exit 2
fi
if [ ! -f web/dist/index.html ]; then
  echo "smoke: web/dist is missing; run make build first" >&2
  exit 2
fi

# A server already on the port would be served instead of this build and the
# walk would test stale code, so refuse rather than proceed.
if lsof -tnP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "smoke: port $PORT is in use (pid $(lsof -tnP -iTCP:"$PORT" -sTCP:LISTEN | tr '\n' ' ')); stop it or set SMOKE_PORT" >&2
  exit 2
fi

LOG="$(mktemp -t ww-smoke.XXXXXX)"
# An isolated profile per run: without it Chrome shares the default headless
# profile and the first render of a run can dump the PREVIOUS run's restored
# tab instead of the requested URL (bit on the first route, Aug 2026).
PROFILE="$(mktemp -d -t ww-smoke-profile.XXXXXX)"
(
  cd api
  ANALYTICS_DASHBOARD_DATA=fixtures ANALYTICS_DASHBOARD_NOW=2026-08-28T17:00:00+00:00 \
    uv run --extra dev uvicorn app.main:app --port "$PORT" --log-level warning >"$LOG" 2>&1
) &
API_PID=$!
# uv run leaves uvicorn as a grandchild that outlives the subshell, so stop
# whatever listens on the port, not just the subshell
trap 'kill $API_PID 2>/dev/null || true; lsof -tnP -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null | xargs kill 2>/dev/null || true; wait $API_PID 2>/dev/null || true; rm -f "$LOG"; rm -rf "$PROFILE"' EXIT

for _ in $(seq 1 50); do
  if curl -fsS "http://127.0.0.1:$PORT/api/health" >/dev/null 2>&1; then break; fi
  sleep 0.2
done
curl -fsS "http://127.0.0.1:$PORT/api/health" >/dev/null || { echo "smoke: API did not start"; cat "$LOG"; exit 1; }

GAME_KEY="$(curl -fsS "http://127.0.0.1:$PORT/api/nfl/slate?season_type=Regular%20Season&week=1" \
  | python3 -c 'import json,sys; rows=json.load(sys.stdin)["rows"]; print(next(r["game_key"] for r in rows if r["props_open_all_books"]))')"

# route | text the rendered DOM must contain
ROUTES=(
  "/nfl|The Pulse"
  "/nfl?days=7|Around the league"
  "/nfl/slate|kickoff slot"
  "/nfl/slate?season_type=Regular%20Season&week=1|SUN 1:00 PM"
  "/nfl/slate?season=2025&season_type=Regular%20Season&week=18|Final"
  "/nfl/games/$GAME_KEY|Back to board"
  "/nfl/games/$GAME_KEY?vendor=fanduel|fanduel line"
  "/nfl/games/nope|No such game"
  "/nfl/teams|By division"
  "/nfl/teams?season=2025&season_type=Regular%20Season&split=home&group=league|League"
  "/nfl/teams/KC?season=2025&season_type=Regular%20Season|Back to standings"
  "/nfl/teams/xxx|No such team"
  "/nfl/players|Player leaders"
  "/nfl/players?season=2025&season_type=Regular%20Season&position=WR&sort=rank_receptions|Jaxon Smith-Njigba"
  "/nfl/players/daca41214b39c5dc66674d09081940f0?season=2025&season_type=Regular%20Season|Back to leaders"
  "/nfl/players/nope|No such player"
  "/nfl/markets|Biggest spread move"
  "/nfl/markets?season_type=Regular%20Season&week=1&vendor=fanduel|Click a game"
  "/nfl/markets/$GAME_KEY|Back to markets"
  "/nfl/markets/nope|No lines for this game"
  "/nfl/news|Playing within 3 days"
  "/nfl/news?days=30&position=QB|Resolved players only"
  "/nfl/explore|Copy as TSV"
  "/nfl/explore?sheet=team_games&where=team:KC&order=point_margin&desc=1|Kansas City Chiefs"
  "/ncaaf/explore|No sheets yet"
  "/ncaaf|No page marts yet"
  "/ncaaf/slate|No game day data yet"
)

render() {
  "$CHROME" --headless=new --disable-gpu --no-first-run --no-default-browser-check \
    --user-data-dir="$PROFILE" \
    --enable-logging=stderr --v=0 --virtual-time-budget=$BUDGET --window-size=1400,1000 \
    --dump-dom "http://127.0.0.1:$PORT$1" 2>&1 || true
}

fail=0
for entry in "${ROUTES[@]}"; do
  route="${entry%%|*}"
  expect="${entry#*|}"
  # a route gets a second render before it counts as broken: the virtual-time
  # budget can expire before a large table paints, and a real break fails twice
  verdict=""
  for attempt in 1 2; do
    out="$(render "$route")"
    errors="$(printf '%s\n' "$out" | grep -E 'CONSOLE\([0-9]+\)\] "(Uncaught|Error|TypeError|ReferenceError|Failed to load|Warning: )' || true)"
    if ! printf '%s' "$out" | grep -q -- "$expect"; then
      verdict="expected text not found: $expect"
    elif [ -n "$errors" ]; then
      verdict="console errors
$errors"
    else
      verdict=""
      [ "$attempt" = 2 ] && echo "note $route passed on the second render"
      break
    fi
  done
  if [ -n "$verdict" ]; then
    echo "FAIL $route: $verdict"
    fail=1
  else
    echo "ok   $route"
  fi
done

# the narrow chrome: bottom tabs instead of the dock
out="$("$CHROME" --headless=new --disable-gpu --no-first-run --user-data-dir="$PROFILE" --enable-logging=stderr --v=0 \
  --virtual-time-budget=$BUDGET --window-size=420,900 --dump-dom "http://127.0.0.1:$PORT/nfl/slate" 2>&1 || true)"
if printf '%s' "$out" | grep -q 'class="tabs"'; then
  echo "ok   /nfl/slate at 420px renders bottom tabs"
else
  echo "FAIL /nfl/slate at 420px: no bottom tabs"
  fail=1
fi

exit $fail
