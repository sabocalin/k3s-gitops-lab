# 20 · Multi-stage Dockerfile: distroless, non-root, digest-pinned

> Issue: #20 (2.2) · Phase 2

## What
`app/Dockerfile` builds the service into a **27.9 MB** (compressed) image. A build stage
installs the locked dependencies; the final stage is **distroless Python**
(`gcr.io/distroless/python3-debian13:nonroot`): Python and its runtime libraries only, no
shell, no package manager, running as UID/GID **65532**.

## Why
- **Smaller:** compilers, pip, uv and caches never reach the final image.
- **Harder to abuse:** an attacker inside the container finds no shell, curl or apt.
- **Fewer CVEs:** fewer packages means fewer findings for the image scan (#23).
- **Non-root:** what Kubernetes `runAsNonRoot` will require (Phase 3).

Alternatives considered:
- **`python:3.13-slim` as the final stage** — the base alone is 43.3 MB / 202 MB, with a
  shell and apt.
- **Alpine** — musl libc: the manylinux wheels (pydantic-core) do not fit or must be
  compiled.
- **Chainguard/Wolfi Python** — very small and low-CVE, but the free tags track latest only.
- **A single stage** — everything used to build would ship in the image.

## How it works
```
uv:0.12.8@sha256:…          ── /uv binary only
python:3.13-slim-trixie@sha256:… (build)
   uv export --frozen  ─▶ requirements.txt WITH hashes (from uv.lock)
   uv pip install --require-hashes --compile-bytecode --target /app/deps
   COPY src/lab_api /app/lab_api ; compileall
distroless/python3-debian13:nonroot@sha256:… (final)
   COPY /app ; PYTHONPATH=/app/deps:/app ; USER 65532:65532
   ENTRYPOINT ["/usr/bin/python3.13", "-m", "uvicorn", "lab_api.main:app", ...]
```
- **`--target` folder, not a virtualenv:** a venv's `python` symlinks to the build stage's
  `/usr/local/bin/python`, which does not exist in distroless (`/usr/bin/python3.13`).
  Both are CPython 3.13, so the compiled wheels (cp313) work in either.
- **`--require-hashes`:** every downloaded file must match `uv.lock`, or the build fails.
- **No build backend at image build time:** the app is copied as source on `PYTHONPATH`, so
  `uv_build` (not in the lock) is never downloaded.
- **Precompiled bytecode** and `PYTHONDONTWRITEBYTECODE=1`: nothing is written at runtime,
  so the container runs with a read-only root filesystem.
- **Exec-form ENTRYPOINT**, Python as PID 1: `SIGTERM` reaches uvicorn directly, which runs
  the lifespan shutdown (`/ready` → 503) and exits 0.
- **`.dockerignore` is an allow-list** (`*`, then `!pyproject.toml !uv.lock !src/`): tests,
  `.venv` and anything local stay out of the build context.
- **Digests:** `tag@sha256:…` uses the digest; the tag is for humans and for Dependabot
  (docker ecosystem, `/app`), which bumps both.

## Implementation
`app/Dockerfile`, `app/.dockerignore`, `.trivyignore.yaml` (file-level findings),
`make image`, README "Container image" section with sizes.

## Verification
All against `lab-api:dev`, linux/arm64 (the node's architecture), built in 14 s:

| Check | Result |
|---|---|
| Endpoints (`docker run --read-only`, `STARTUP_DELAY_SECONDS=3`) | early: health 200, ready **503**; after 3.5 s: ready 200; `/metrics` includes `process_resident_memory_bytes` (Linux) ≈ 52 MB |
| **User** | `Config.User=65532:65532`; `docker top`: UID 65532 GID 65532; in-process `os.getuid()` 65532 |
| **Negative: shell** | `exec: "sh": executable file not found in $PATH` |
| **Negative: write its own code** (no `--read-only`) | `PermissionError: [Errno 13] Permission denied: '/app/lab_api/x'` |
| **Negative: write anywhere** (`--read-only`) | `OSError: [Errno 30] Read-only file system: '/tmp/x'`; the app still serves |
| `SIGTERM` (`docker stop`) | stopped in under 1 s, exit code 0, log: `Waiting for application shutdown. ... Application shutdown complete.` |
| Sizes | lab-api 27.9 MB compressed / 126 MB on disk; distroless base 22.6 / 103; `python:3.13-slim` base alone 43.3 / 202 |
| trivy config | only DS-0026 (no `HEALTHCHECK`, LOW): accepted in `.trivyignore.yaml`; a repo-wide scan with it is clean |

## Gotchas
- **File-level trivy findings cannot be ignored inline.** DS-0026 has no line to attach a
  `# trivy:ignore` to. `.trivyignore.yaml` takes a path, relative to the **scan target**:
  `app/Dockerfile` matches when scanning `.`, but not when scanning `app/`.
- **A read-only filesystem hides other protections.** The first "cannot write its own code"
  test failed with `Read-only file system`, which proved nothing about ownership; run
  without `--read-only` it gives `Permission denied`.
- **Docker Desktop reports two sizes.** `docker image ls` shows unpacked disk usage;
  `docker image inspect .Size` with the containerd store is the compressed content. The
  README lists both, measured the same way for every image.

## Further reading
- [Distroless images](https://github.com/GoogleContainerTools/distroless)
- [Dockerfile best practices: multi-stage builds](https://docs.docker.com/build/building/multi-stage/)
- [uv in Docker](https://docs.astral.sh/uv/guides/integration/docker/)
- [Trivy: ignore file (YAML)](https://trivy.dev/latest/docs/configuration/filtering/#trivyignoreyaml)
