#!/usr/bin/env bash
# Route walk in headless Chrome against the built app in fixture mode.
#
# Starts the API on a spare port serving web/dist, renders each route with a
# virtual-time budget so fetches settle, and fails on any console error or on a
# page missing the text it must show. No Snowflake connection: the API runs with
# OPS_DASHBOARD_DATA=fixtures, so this is the same walk CI could do.
#
#   make smoke            # builds web/dist first
#   CHROME=/path/to/chrome make smoke
set -euo pipefail

cd "$(dirname "$0")/.."
PORT="${SMOKE_PORT:-8027}"
# virtual time per route, ms: the pages settle on fixtures in well under a second
BUDGET="${SMOKE_BUDGET_MS:-2000}"
NOW="2026-08-09T18:00:00+00:00"   # the fixture snapshot's era, the same pin as tests/conftest.py
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

LOG="$(mktemp -t ww-ops-smoke.XXXXXX)"
(
  cd api
  OPS_DASHBOARD_DATA=fixtures OPS_DASHBOARD_NOW="$NOW" \
    uv run uvicorn app.main:app --port "$PORT" --log-level warning >"$LOG" 2>&1
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

# the ids come from the fixtures rather than being pinned here, so a recapture
# does not break the walk
read -r SPORT NAME QID < <(curl -fsS "http://127.0.0.1:$PORT/api/pipelines?sport=all" \
  | python3 -c 'import json,sys; r=json.load(sys.stdin)["pipelines"]; x=next(p for p in r if p["latest"] and p["latest"].get("query_id")); print(x["sport"], x["pipeline"], x["latest"]["query_id"])')
BID="$(curl -fsS "http://127.0.0.1:$PORT/api/dbt/builds?sport=all&limit=20" \
  | python3 -c 'import json,sys; print(next(b["build_id"] for b in json.load(sys.stdin)["builds"] if b["build_id"]))')"

# route | text the rendered DOM must contain
ROUTES=(
  "/|How this board is built"
  "/?sport=NFL&date=2026-08-08|Sat"
  "/pipelines|Worst record first"
  "/pipelines?sport=NFL|Pipelines"
  "/builds|Build log"
  "/ingestion/$SPORT/$NAME|Back to pipelines"
  "/runs/$QID|Back to pipeline"
  "/dbt/builds/$BID|Back to builds"
  "/runs/nope|unknown run"
  "/dbt|Build log"
  "/ingestion|Worst record first"
)

render() {
  "$CHROME" --headless=new --disable-gpu --no-first-run --no-default-browser-check \
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
out="$("$CHROME" --headless=new --disable-gpu --no-first-run --enable-logging=stderr --v=0 \
  --virtual-time-budget=$BUDGET --window-size=420,900 --dump-dom "http://127.0.0.1:$PORT/" 2>&1 || true)"
if printf '%s' "$out" | grep -q 'class="tabs"'; then
  echo "ok   / at 420px renders bottom tabs"
else
  echo "FAIL / at 420px: no bottom tabs"
  fail=1
fi

exit $fail
