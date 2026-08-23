#!/usr/bin/env bash
# Drive the built app in headless Chrome over the DevTools protocol and assert
# the navigation contract: Back to board returns to the week you were on, the
# board's scroll position comes back, the dock remembers the week, a book picked
# on a game page follows you to the board, a deep link's Back has somewhere to
# go, and browser Back skips chip history. The assertions live in navcheck.mjs.
#
#   make nav              # builds web/dist first
#   CHROME=/path/to/chrome make nav
set -euo pipefail

cd "$(dirname "$0")/.."
PORT="${NAV_PORT:-8019}"
CDP_PORT="${NAV_CDP_PORT:-9333}"
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
if [ ! -x "$CHROME" ]; then
  CHROME="$(command -v google-chrome || command -v chromium || command -v chromium-browser || true)"
fi
if [ -z "$CHROME" ] || [ ! -x "$CHROME" ]; then
  echo "nav: no Chrome found; set CHROME=/path/to/chrome" >&2
  exit 2
fi
if [ ! -f web/dist/index.html ]; then
  echo "nav: web/dist is missing; run make build first" >&2
  exit 2
fi

if lsof -tnP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "nav: port $PORT is in use (pid $(lsof -tnP -iTCP:"$PORT" -sTCP:LISTEN | tr '\n' ' ')); stop it or set NAV_PORT" >&2
  exit 2
fi

PROFILE="$(mktemp -d -t ww-nav-profile.XXXXXX)"
(
  cd api
  ANALYTICS_DASHBOARD_DATA=fixtures ANALYTICS_DASHBOARD_NOW=2026-08-23T02:00:00+00:00 \
    uv run --extra dev uvicorn app.main:app --port "$PORT" --log-level warning >/dev/null 2>&1
) &
API_PID=$!
"$CHROME" --headless=new --disable-gpu --no-first-run --remote-debugging-port="$CDP_PORT" \
  --user-data-dir="$PROFILE" --window-size=1400,1000 about:blank >/dev/null 2>&1 &
CHROME_PID=$!
# uv run leaves uvicorn as a grandchild that outlives the subshell: stop the
# port's listener, not just the subshell
trap 'kill $API_PID $CHROME_PID 2>/dev/null || true; lsof -tnP -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null | xargs kill 2>/dev/null || true; wait $API_PID $CHROME_PID 2>/dev/null || true' EXIT

for _ in $(seq 1 50); do
  curl -fsS "http://127.0.0.1:$PORT/api/health" >/dev/null 2>&1 && curl -fsS "http://127.0.0.1:$CDP_PORT/json" >/dev/null 2>&1 && break
  sleep 0.2
done

node scripts/navcheck.mjs "http://127.0.0.1:$PORT" "$CDP_PORT"
