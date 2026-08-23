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
(
  cd api
  ANALYTICS_DASHBOARD_DATA=fixtures ANALYTICS_DASHBOARD_NOW=2026-08-23T02:00:00+00:00 \
    uv run --extra dev uvicorn app.main:app --port "$PORT" --log-level warning >"$LOG" 2>&1
) &
API_PID=$!
# uv run leaves uvicorn as a grandchild that outlives the subshell, so stop
# whatever listens on the port, not just the subshell
trap 'kill $API_PID 2>/dev/null || true; lsof -tnP -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null | xargs kill 2>/dev/null || true; wait $API_PID 2>/dev/null || true; rm -f "$LOG"' EXIT

for _ in $(seq 1 50); do
  if curl -fsS "http://127.0.0.1:$PORT/api/health" >/dev/null 2>&1; then break; fi
  sleep 0.2
done
curl -fsS "http://127.0.0.1:$PORT/api/health" >/dev/null || { echo "smoke: API did not start"; cat "$LOG"; exit 1; }

GAME_KEY="$(curl -fsS "http://127.0.0.1:$PORT/api/nfl/slate?season_type=Regular%20Season&week=1" \
  | python3 -c 'import json,sys; rows=json.load(sys.stdin)["rows"]; print(next(r["game_key"] for r in rows if r["props_open_all_books"]))')"

# route | text the rendered DOM must contain
ROUTES=(
  "/nfl|Game day board"
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
  "/ncaaf|No page marts yet"
  "/ncaaf/slate|No game day data yet"
)

fail=0
for entry in "${ROUTES[@]}"; do
  route="${entry%%|*}"
  expect="${entry#*|}"
  out="$("$CHROME" --headless=new --disable-gpu --no-first-run --no-default-browser-check \
    --enable-logging=stderr --v=0 --virtual-time-budget=8000 --window-size=1400,1000 \
    --dump-dom "http://127.0.0.1:$PORT$route" 2>&1 || true)"
  errors="$(printf '%s\n' "$out" | grep -E 'CONSOLE\([0-9]+\)\] "(Uncaught|Error|TypeError|ReferenceError|Failed to load|Warning: )' || true)"
  if ! printf '%s' "$out" | grep -q -- "$expect"; then
    echo "FAIL $route: expected text not found: $expect"
    fail=1
  elif [ -n "$errors" ]; then
    echo "FAIL $route: console errors"
    echo "$errors"
    fail=1
  else
    echo "ok   $route"
  fi
done

# the narrow chrome: bottom tabs instead of the dock
out="$("$CHROME" --headless=new --disable-gpu --no-first-run --enable-logging=stderr --v=0 \
  --virtual-time-budget=8000 --window-size=420,900 --dump-dom "http://127.0.0.1:$PORT/nfl/slate" 2>&1 || true)"
if printf '%s' "$out" | grep -q 'class="tabs"'; then
  echo "ok   /nfl/slate at 420px renders bottom tabs"
else
  echo "FAIL /nfl/slate at 420px: no bottom tabs"
  fail=1
fi

exit $fail
