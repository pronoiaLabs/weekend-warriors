# Container image for dlt pipelines. One image runs any pipeline in the registry;
# the pipeline name is passed as the container argument (see the staged spec
# spec deploy/spcs/dlt_job.tmpl.yaml, inlined into the generated tasks).
#
# ARCHITECTURE: SPCS compute pools are x86_64, so this image MUST be linux/amd64.
# Build it on an amd64 runner (the CI job in .github/workflows/deploy.yml) rather
# than an Apple Silicon laptop, where `--platform linux/amd64` emulates via QEMU
# and is very slow. Local build (emulated) for reference:
#
#   docker build --platform linux/amd64 -t dlt-pipeline:latest -f deploy/spcs/Dockerfile .
#   docker tag ...  <org>-<acct>.registry.snowflakecomputing.com/DLT_DB/DEPLOY/IMAGES/dlt-pipeline:latest
#   docker push ...
#
# docker run <image> nfl_reference     <- runs that pipeline
# docker run <image> --group batch_hourly
# docker run <image> --all
#
# Runtime config source: the image ships NO pipeline definitions. At run time the
# container reads its spec from the DLT_DB.OPS.PIPELINE_REGISTRY table (the
# registries/ directory is only the local-dev fallback). Adding or editing a pipeline is a table change
# (python -m pipelines.registry_sync), so it never requires rebuilding this image.
# Rebuild only for code or dependency changes.

FROM python:3.11-slim

# uv for fast, reproducible installs (matches the local dev toolchain). Pinned.
COPY --from=ghcr.io/astral-sh/uv:0.11.2 /uv /uvx /bin/

WORKDIR /app

# Copy the project (pyproject + package) then install — setuptools needs the
# `pipelines` package present to build. registries/ lives inside pipelines/batch/.
COPY pyproject.toml ./
COPY pipelines/ ./pipelines/
# uv pip install into the system environment (no venv); far faster than pip.
# No extras: the runner needs dlt[snowflake] + dlt[postgres] (pyproject deps).
RUN uv pip install --system --no-cache "."

COPY .dlt/config.toml ./.dlt/config.toml

ENTRYPOINT ["python", "-m", "pipelines.batch.run"]
