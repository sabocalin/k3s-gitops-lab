# 29 · Liveness, readiness and startup probes

> Issue: #29 (3.3) · Phase 3

## What
Three probes on the app's container, each asking a different question:

| Probe | Asks | Endpoint | Timing | On failure |
|---|---|---|---|---|
| startup | has it finished starting? | `/health` | every 2 s, up to 30 times (60 s) | keeps waiting; the other two are paused until it passes |
| liveness | is it stuck? | `/health` | every 10 s, 3 misses | **restart the container** |
| readiness (#28) | should it get traffic now? | `/ready` | every 2 s, 1 miss | **out of the Service endpoints, no restart** |

The app gained a way to fail readiness on purpose: **`SIGUSR1` toggles "draining"** (`/ready`
503 `draining`, `/health` still 200).

## Why
Liveness and readiness answer different questions, and mixing them is a classic
self-inflicted outage. If liveness checked `/ready`, every pod that is warming up, draining, or
briefly overloaded would be killed and restarted, often in a loop. So liveness asks only "is the
process alive" (`/health`, no dependencies), and readiness decides traffic.

The startup probe exists so a slow start is not mistaken for a hang: until it passes,
liveness does not run.

Alternatives considered for the drain switch:
- **An HTTP endpoint** (`POST /drain`) — anyone who can reach the app could take pods out of
  service; the Ingress (#35) makes the app public.
- **A marker file** — needs a writable volume once the root filesystem is read-only (#31).
- **A signal** (chosen) — only someone allowed to `kubectl exec` can send it.

## How it works
```
kubectl exec <pod> -- python3 -c "import os,signal; os.kill(1, signal.SIGUSR1)"
   └▶ PID 1 (uvicorn) ─ handler registered in the lifespan hook ─▶ draining = not draining
readiness probe (2 s) ─▶ /ready 503 "draining" ─▶ EndpointSlice: ready=false, serving=false
   └▶ kube-proxy stops sending Service traffic to it
liveness probe (10 s) ─▶ /health 200 ─▶ nothing happens (no restart)
second SIGUSR1 ─▶ /ready 200 ─▶ back in the endpoints
```
- `/ready` precedence: **starting** (startup work not finished), then **draining**, then **ready**.
- `loop.add_signal_handler` only works in the main thread. Under the test client the app runs
  in a worker thread, so registration is skipped there and tests call
  `app.state.toggle_drain()` directly.
- Python is PID 1 in the container (exec-form ENTRYPOINT, #20). A process signalling PID 1
  as the same user (65532) is allowed; PID 1 ignores signals it has no handler for, which is
  why the app registers one.

## Implementation
- Part 1 (PR #94): `app/src/lab_api/main.py` (`toggle_drain`, SIGUSR1 handler, `draining`
  status), 2 new tests (9 total), startup and liveness probes in `k8s/base/deployment.yaml`,
  readiness `timeoutSeconds: 1` made explicit.
- Part 2: both overlays bumped to the image built from part 1:
  `lab-api@sha256:7952a1567b7da01e15b033fb407d3a0ecb50670dbb647b18eca7fa13254d5279`. Its
  cosign signature was verified with `scripts/verify-image.sh` before deploying.

## Verification
**Locally** (image built from part 1): `docker kill --signal=SIGUSR1` → `/ready` 503
`draining`, `/health` 200. The exec-style `os.kill(1, SIGUSR1)` as the app user toggled it
back; 0 restarts.

**On the cluster** (`push` namespace, the new image rolled out with 0 restarts):

| Check | Result |
|---|---|
| Before draining | the target pod `…-6ncrv` (10.52.0.27) is a ready endpoint and serves part of 60 Service requests |
| `SIGUSR1` sent | EndpointSlice for 10.52.0.27: `ready:false, serving:false`; pod `READY` false |
| Direct to the drained pod | `/ready` 503 `{"status":"draining"}`, `/health` **200** |
| Service traffic while drained (60 requests) | **0** to the drained pod: 27 + 33 to the other two |
| **Restarts while drained** (about 7 min, far past liveness's 30 s window) | **0**; events: `Unhealthy` ×133 (`Readiness probe failed … 503`), no `Killing` |
| Second `SIGUSR1` | back as a ready endpoint after **1 s**; it served 23 of the next 60 requests; restarts still 0 |
| **Negative: liveness pointed at a 404 path** | `Liveness probe failed … 404`, then `Killing: Container lab-api failed liveness probe, will be restarted`: restartCount 1 after **32 s** (3 × 10 s) |
| Restored from git | `kubectl diff -k` clean |

Same app, same pod: a readiness failure takes it out of traffic; a liveness failure restarts it.

## Gotchas
- **jq's `//` treats `false` as missing.** The test's wait helper did
  `… | .conditions.ready | first // "absent"`, so a real `false` became `"absent"` and the loop
  waited forever, while the pod had in fact been drained. Convert with `tostring` before `//`.
- **`/` returns JSON without a trailing newline**, so a shell loop of `curl` calls produced one
  long line; add `echo` after each request before counting.
- **Old pods during a rollout** still show in listings for their 5 s `preStop`; their
  `restarts=1` was from the node's stop and start, not from the probes.

## Further reading
- [Configure liveness, readiness and startup probes](https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/)
- [EndpointSlice conditions: ready, serving, terminating](https://kubernetes.io/docs/concepts/services-networking/endpoint-slices/#conditions)
- [asyncio: `loop.add_signal_handler`](https://docs.python.org/3/library/asyncio-eventloop.html#unix-signals)
