# syntax=docker/dockerfile:1
# #20: two stages. The build stage installs the locked dependencies; the final stage is
# distroless Python (no shell, no package manager) running as a non-root user.
# Every base image is pinned by digest; Dependabot (docker, /app) bumps tag and digest.

# uv, only as a tool for the build stage.
FROM ghcr.io/astral-sh/uv:0.12.8@sha256:d1cbaeadc234fe19c0d93daabcf5e98738cd93c6d1dd4918ef6aa30735feb23a AS uv

FROM python:3.13-slim-trixie@sha256:7c61056e61ac89e852de05f3dc6fa51a6dd2181797bceed46aa725dd7cb2cd3b AS build
COPY --from=uv /uv /usr/local/bin/uv
WORKDIR /src

# Dependencies first, in their own layer: a code change does not reinstall them.
# `uv export` turns uv.lock into a requirements file WITH hashes; --require-hashes makes
# the install fail if any downloaded file does not match the lock.
# --target installs into a plain folder (not a virtualenv): a venv's interpreter symlink
# would point at this stage's /usr/local/bin/python, which does not exist in distroless.
COPY pyproject.toml uv.lock ./
RUN uv export --frozen --no-dev --no-emit-project --format requirements.txt -o requirements.txt \
 && uv pip install --no-cache --require-hashes --compile-bytecode \
      --python /usr/local/bin/python3.13 --target /app/deps -r requirements.txt

# The app itself is plain source on PYTHONPATH: no build backend runs at image build time.
COPY src/lab_api /app/lab_api
RUN python -m compileall -q /app/lab_api

# Distroless Python (Debian 13, Python 3.13), tag "nonroot" = UID/GID 65532.
# No HEALTHCHECK: Kubernetes ignores it and probes /health and /ready itself (#29);
# distroless also has no curl to run one with (trivy DS-0026, accepted in .trivyignore.yaml).
# DELIBERATELY OUTDATED (#23 demo, reverted next): python 3.13.0 slim from 2024-10-18
FROM python:3.13.0-slim-bookworm@sha256:0de818129b26ed8f46fd772f540c80e277b67a28229531a1ba0fdacfaed19bcb
# Files stay owned by root and are not writable by the app user: the process cannot
# modify its own code. Precompiled bytecode means nothing needs writing at runtime, so the
# container also runs with a read-only root filesystem.
COPY --from=build /app /app
# The commit this image was built from (CI passes the git SHA; `/` reports it).
ARG APP_VERSION=dev
ENV APP_VERSION=${APP_VERSION} \
    PYTHONPATH=/app/deps:/app \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1
USER 65532:65532
EXPOSE 8000
# Exec form, python as PID 1: SIGTERM from Kubernetes reaches uvicorn directly, which
# runs the lifespan shutdown (/ready turns 503) before exiting.
ENTRYPOINT ["/usr/bin/python3.13", "-m", "uvicorn", "lab_api.main:app", "--host", "0.0.0.0", "--port", "8000"]
