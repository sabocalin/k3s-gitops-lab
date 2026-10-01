# 19 · FastAPI scaffold: /health, /ready, /metrics

> Issue: #19 (2.1) · Phase 2

## What
The service the cluster will run: a small FastAPI app in `app/` (package `lab_api`) with
three operational endpoints and a root endpoint, tested with pytest, linted with ruff,
managed with uv (`pyproject.toml` + `uv.lock`).

| Endpoint | Answers | Consumer |
|---|---|---|
| `/health` | is the process alive? always 200 once serving | liveness probe: restart if failing |
| `/ready` | can it take traffic? 503 until startup work finished, and while shutting down | readiness probe: out of the Service, no restart |
| `/metrics` | requests by route and status, latency histogram, process/Python stats | Prometheus / Grafana Cloud (Phase 5) |
| `/` | service, version (`APP_VERSION`), pod (hostname) | humans: which replica answered |

## Why
Kubernetes decides restarts and traffic from these endpoints (#29), so they must mean
different things. With one combined endpoint, a slow start looks like a dead process and
the pod is restarted in a loop before it ever becomes ready.

Alternatives considered:
- **Flask** — synchronous, no lifespan hooks or built-in OpenAPI.
- **Django** — far more than four endpoints need.
- **One `/healthz` for both** — the restart loop above.
- **`pip` + `requirements.txt`** — no lockfile with hashes for transitive packages; uv
  gives both, plus a managed Python 3.13.

## How it works
```
uvicorn ─▶ lifespan startup: ready=False, start warm-up task, return immediately
         ─▶ serving: /health 200, /ready 503 ...
warm-up task done (STARTUP_DELAY_SECONDS, default 2) ─▶ ready=True ─▶ /ready 200
SIGTERM ─▶ lifespan shutdown: ready=False first, cancel the task
```
- **Why a background task:** uvicorn accepts no connections until the lifespan startup
  returns. Work done *inside* it could never be seen as "not ready": the port is simply
  closed. As a task, liveness is answered at once and readiness waits honestly.
- **Metrics labels use the route template** (`/health`, `/items/{id}`), never the raw
  path; unknown paths share `route="unmatched"`. Raw paths would create a time series per
  URL anyone types: unbounded cardinality, a classic way to blow up a metrics bill.
- **A per-app `CollectorRegistry`**, not the global one: tests can build several apps, and
  only metrics we declare are exported.
- **`/metrics` is a route, not a mounted ASGI app:** a mount at `/metrics` answers
  `/metrics` with a 307 redirect to `/metrics/`.

## Implementation
- `app/pyproject.toml`: Python `>=3.13,<3.14` (matches the distroless Debian 13 base planned
  for #20); exact pins: fastapi 0.141.1, uvicorn 0.53.0, prometheus-client 0.26.0; dev:
  pytest 9.1.1, httpx2 2.13.1, ruff 0.16.8. Ruff rules: pycodestyle, pyflakes, isort,
  bugbear, pyupgrade, bandit (`S`), async pitfalls.
- **7-day cooldown, as for Dependabot:** locked with `uv lock --exclude-newer <7 days ago>`
  (fastapi 0.142.2 and uvicorn 0.54.0 were newer and skipped). Every package in `uv.lock`
  was checked to be older than the cutoff. The cutoff was then dropped from the lock's
  options (it is persisted there), so Dependabot can still propose updates.
- `app/src/lab_api/main.py` (`create_app(startup=...)` factory), `app/tests/test_app.py`
  (7 tests), `app/.python-version`.
- `.github/dependabot.yml`: `/app` moves from `pip` to the `uv` ecosystem.
- `Makefile`: `make test` (ruff check, ruff format --check, pytest), `make run`.

## Verification
| Check | Result |
|---|---|
| `make test` | ruff clean, format clean, **7 passed** |
| **Negative: `/ready` before startup completes** (test) | 503 `{"status":"starting"}`, twice; 200 only after the test releases the gate |
| `/health` while startup is still running (test) | 200 |
| After shutdown (test) | `ready` is False again |
| Metrics (test) | `route="/health",status="200"} 2.0`; unknown path → `route="unmatched"`, and the raw path does not appear |
| **Real server, from outside** (uvicorn, `STARTUP_DELAY_SECONDS=3`, curl) | t+0 s and t+1 s: health 200, ready **503**; t+4 s: ready **200**; `/metrics` 200 `text/plain; version=1.0.0` |
| **Mutation test: break `/ready` to always say ready** | `FAILED test_ready_is_503_until_startup_completes`: the tests catch it |

## Gotchas
- **A test helper that blocked a thread hung the suite.** The first version waited with
  `asyncio.to_thread(gate.wait)`. When an assertion failed before `gate.set()`, shutdown
  cancelled the task, but a thread blocked in `wait()` cannot be cancelled, and the event
  loop waited for it forever. The mutation test exposed it. The helper now polls on the
  loop and is cancelled at once.
- **Process metrics exist only on Linux** (`ProcessCollector` reads `/proc`): on macOS
  there is no `process_resident_memory_bytes`. The test checks `python_info` everywhere and
  the process metrics on Linux (CI, the container).
- **Starlette deprecated `httpx` for its TestClient** in favour of `httpx2` (pydantic org);
  using `httpx` prints a `StarletteDeprecationWarning`.
- **`uv lock --exclude-newer` is sticky**: it is saved in `uv.lock` `[options]`, and every
  later lock (Dependabot's too) would keep resolving as of that date.

## Further reading
- [FastAPI lifespan events](https://fastapi.tiangolo.com/advanced/events/)
- [Kubernetes: liveness, readiness and startup probes](https://kubernetes.io/docs/concepts/configuration/liveness-readiness-startup-probes/)
- [Prometheus: label cardinality](https://prometheus.io/docs/practices/naming/#labels)
- [uv: locking and `exclude-newer`](https://docs.astral.sh/uv/concepts/resolution/#reproducible-resolutions)
