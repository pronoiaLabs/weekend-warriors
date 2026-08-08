# ops-dashboard SPCS image: React bundle + FastAPI in one container, one port.
#
# Two stages, two platforms, on purpose:
#   - The node stage runs on $BUILDPLATFORM (the build host's native arch).
#     JS/CSS output is architecture-independent, so emulating amd64 through
#     QEMU for npm would only make the build slower. Only dist/ crosses over.
#   - The runtime stage is linux/amd64 because SPCS pools are x86_64.
#     Build with: docker build --platform linux/amd64 -f this-file (from
#     the ops-dashboard/ directory; see `make image-build`).
#
# No external access integration is needed at runtime: npm and pip run here,
# at image build time, and the container never makes an outbound call.

FROM --platform=$BUILDPLATFORM node:22-slim AS web
WORKDIR /build
COPY web/package.json web/package-lock.json ./
RUN npm ci
COPY web/ ./
RUN npm run build

FROM python:3.11-slim
COPY --from=ghcr.io/astral-sh/uv:0.11.2 /uv /uvx /bin/

WORKDIR /app
COPY api/pyproject.toml ./
RUN uv pip install --system --no-cache "."
COPY api/app/ ./app/
COPY --from=web /build/dist/ ./web/dist/

# main.py falls back to a path relative to the api package, which does not
# exist in this layout; the env var is the supported override.
ENV OPS_DASHBOARD_STATIC=/app/web/dist

EXPOSE 8000
ENTRYPOINT ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
