# ops-dashboard

Observability dashboard for the dlt ingestion fleet: a React front end and a FastAPI
back end reading the `DLT_DB.OPS` views and each sport's `V_PIPELINE_RUNS`.

**This runs locally, by design.** The only Snowflake cost is warehouse seconds when a
page loads; there is no always-on service. Queries go through your `weekend-warriors`
connection, read-only.

## Run it

```bash
make install    # api deps (uv) + web deps (npm), one time
make serve      # build the web app, serve everything on http://localhost:8000
```

One command, one port: FastAPI serves the built bundle and /api together, the
same shape the SPCS container would use. For development with hot reload use
two terminals instead: `make dev-api` (:8000) and `make dev-web` (:5173).

Pages: fleet overview (schedule board + exception-only sport panels), incidents
feed, pipeline detail, run detail.

`OPS_DASHBOARD_DATA=fixtures make dev-api` serves recorded fixture data with no
Snowflake connection at all; the test suite always runs in that mode.

## Quality

```bash
make test    # api pytest (fixture mode, no network)
make lint    # ruff + tsc
make build   # production bundle into web/dist
```

## SPCS deployment: parked, not deleted

`deploy/` holds a complete but UNAPPLIED path to run this as an SPCS service
(Dockerfile, spec template, role/pool/service SQL, `make setup` / `image-push` /
`deploy` targets). It is parked because an always-on XS pool costs real money 24/7
and local serves the same pages for warehouse-seconds. If that trade ever flips,
start at `deploy/sql/01_ops_role.sql`, whose header explains the service-owner-role
trap that shaped the design.
