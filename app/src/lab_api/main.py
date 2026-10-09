"""The k3s-gitops-lab demo service (#19).

/health   liveness: the process is up and serving. Always 200.
/ready    readiness: 503 until startup work has finished, while draining, and while
          shutting down.
/metrics  Prometheus metrics: HTTP requests by route and status, latency, process stats.
/         which version and which pod answered (useful with several replicas). The version
          is the git commit the image was built from (APP_VERSION, set by image.yml), so
          it shows which commit each namespace runs (#44).

Startup work runs as a background task started from the lifespan hook. uvicorn accepts
no connections until the lifespan startup returns, so work done *inside* it could never
be observed as "not ready". As a task, the server answers /health at once while /ready
stays 503 until the work completes.

Draining (#29): SIGUSR1 toggles it. A draining pod answers /ready with 503, so Kubernetes
removes it from the Service, while /health stays 200, so it is NOT restarted. Use it to take
one pod out of traffic by hand (and to prove that readiness and liveness are separate):
    kubectl exec <pod> -- python3 -c "import os,signal; os.kill(1, signal.SIGUSR1)"
A signal rather than an HTTP endpoint: only someone allowed to `kubectl exec` can send it.
"""

import asyncio
import os
import signal
import socket
import time
from collections.abc import Awaitable, Callable
from contextlib import asynccontextmanager

from fastapi import FastAPI, Request, Response
from fastapi.responses import JSONResponse
from prometheus_client import (
    CONTENT_TYPE_LATEST,
    CollectorRegistry,
    Counter,
    Histogram,
    gc_collector,
    generate_latest,
    platform_collector,
    process_collector,
)

Startup = Callable[[], Awaitable[None]]


async def default_startup() -> None:
    """Stand-in for real warm-up (connections, caches). Length from STARTUP_DELAY_SECONDS."""
    await asyncio.sleep(float(os.environ.get("STARTUP_DELAY_SECONDS", "2")))


def create_app(startup: Startup = default_startup) -> FastAPI:
    # One registry per app instance (not the global one): tests can build several apps
    # without "Duplicated timeseries" errors, and nothing registers metrics behind our back.
    registry = CollectorRegistry()
    process_collector.ProcessCollector(registry=registry)
    platform_collector.PlatformCollector(registry=registry)
    gc_collector.GCCollector(registry=registry)
    requests_total = Counter(
        "http_requests_total",
        "HTTP requests, by method, route and status code.",
        ["method", "route", "status"],
        registry=registry,
    )
    request_seconds = Histogram(
        "http_request_duration_seconds",
        "HTTP request latency in seconds, by method and route.",
        ["method", "route"],
        registry=registry,
    )

    def toggle_drain() -> None:
        app.state.draining = not app.state.draining

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        app.state.ready = False

        async def warm_up() -> None:
            await startup()
            app.state.ready = True

        task = asyncio.create_task(warm_up())
        loop = asyncio.get_running_loop()
        try:
            loop.add_signal_handler(signal.SIGUSR1, toggle_drain)
        except (NotImplementedError, RuntimeError, ValueError):
            # Signal handlers need the main thread of the main interpreter; tests run the
            # app in a worker thread and call app.state.toggle_drain() directly instead.
            pass
        yield
        # Shutting down: report not ready first, so a load balancer stops sending traffic.
        app.state.ready = False
        task.cancel()

    app = FastAPI(title="k3s-gitops-lab", lifespan=lifespan)
    app.state.ready = False
    app.state.draining = False
    app.state.toggle_drain = toggle_drain

    @app.middleware("http")
    async def record_metrics(request: Request, call_next):
        start = time.perf_counter()
        response = await call_next(request)
        # The route *template* ("/items/{id}"), never the raw path: raw paths would create
        # one time series per URL anyone requests (unbounded label cardinality).
        route = request.scope.get("route")
        label = route.path if route is not None else "unmatched"
        requests_total.labels(request.method, label, str(response.status_code)).inc()
        request_seconds.labels(request.method, label).observe(time.perf_counter() - start)
        return response

    @app.get("/health")
    async def health() -> dict[str, str]:
        return {"status": "ok"}

    @app.get("/ready")
    async def ready() -> JSONResponse:
        if not app.state.ready:
            return JSONResponse({"status": "starting"}, status_code=503)
        if app.state.draining:
            return JSONResponse({"status": "draining"}, status_code=503)
        return JSONResponse({"status": "ready"})

    @app.get("/metrics")
    async def metrics() -> Response:
        # A plain route rather than mounting prometheus_client's ASGI app: a mount at
        # /metrics answers /metrics with a 307 redirect to /metrics/.
        return Response(generate_latest(registry), media_type=CONTENT_TYPE_LATEST)

    @app.get("/")
    async def root() -> dict[str, str]:
        return {
            "service": "k3s-gitops-lab",
            "version": os.environ.get("APP_VERSION", "dev"),
            "pod": socket.gethostname(),
        }

    return app


app = create_app()
