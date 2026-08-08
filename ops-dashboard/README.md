# ops-dashboard

Observability dashboard for the dlt ingestion fleet: a React front end and a FastAPI
back end that reads the `DLT_DB.OPS` views. Later phases run it as an SPCS service.

Development:

- `make install` installs api (uv) and web (npm) dependencies
- `make dev-api` starts FastAPI on :8000
- `make dev-web` starts the Vite dev server, proxying `/api` to the api

Deploy and setup docs come in a later phase.
