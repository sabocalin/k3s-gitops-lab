"""Tests for /health, /ready, /metrics (#19).

TestClient used as a context manager runs the app's lifespan (startup and shutdown) and
serves it on its own event loop in a separate thread. The startup used here waits on a
threading.Event, so a test decides exactly when "startup work" finishes.
"""

import asyncio
import sys
import threading
import time

import pytest
from fastapi.testclient import TestClient

from lab_api.main import create_app


def gated_startup(gate: threading.Event):
    # Poll on the event loop rather than block a worker thread on gate.wait(): a blocked
    # thread cannot be cancelled, so a test failing before gate.set() would hang shutdown.
    # Not asyncio.Event: the test sets the gate from its own thread, and asyncio.Event is
    # not thread-safe (the app runs on TestClient's loop in another thread).
    async def startup() -> None:
        while not gate.is_set():  # noqa: ASYNC110
            await asyncio.sleep(0.01)

    return startup


def wait_until_ready(client: TestClient, timeout: float = 5.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if client.get("/ready").status_code == 200:
            return
        time.sleep(0.01)
    pytest.fail("never became ready")


@pytest.fixture
def ready_client():
    gate = threading.Event()
    gate.set()
    with TestClient(create_app(gated_startup(gate))) as client:
        wait_until_ready(client)
        yield client


def test_health_is_ok_even_before_startup_finishes():
    gate = threading.Event()  # never set: startup is still running
    with TestClient(create_app(gated_startup(gate))) as client:
        response = client.get("/health")
        assert response.status_code == 200
        assert response.json() == {"status": "ok"}
        gate.set()  # let the background task finish before shutdown


def test_ready_is_503_until_startup_completes():
    gate = threading.Event()
    with TestClient(create_app(gated_startup(gate))) as client:
        # Negative control first: not ready while startup work is still running.
        first = client.get("/ready")
        assert first.status_code == 503
        assert first.json() == {"status": "starting"}
        assert client.get("/ready").status_code == 503  # still not ready, no flapping

        gate.set()
        wait_until_ready(client)
        assert client.get("/ready").json() == {"status": "ready"}


def test_ready_is_503_again_after_shutdown():
    gate = threading.Event()
    gate.set()
    app = create_app(gated_startup(gate))
    with TestClient(app) as client:
        wait_until_ready(client)
    assert app.state.ready is False


def test_metrics_are_prometheus_text(ready_client):
    response = ready_client.get("/metrics")
    assert response.status_code == 200
    assert response.headers["content-type"].startswith("text/plain")
    assert "python_info" in response.text  # platform collector: every OS
    if sys.platform == "linux":  # process collector reads /proc: Linux (CI, the container)
        assert "process_resident_memory_bytes" in response.text


def test_metrics_count_requests_by_route_template_and_status(ready_client):
    ready_client.get("/health")
    ready_client.get("/health")
    ready_client.get("/no-such-page")
    text = ready_client.get("/metrics").text
    assert 'http_requests_total{method="GET",route="/health",status="200"} 2.0' in text
    # Unknown paths share one label value instead of one series per URL.
    assert 'http_requests_total{method="GET",route="unmatched",status="404"} 1.0' in text
    assert "no-such-page" not in text


def test_metrics_is_not_a_redirect(ready_client):
    response = ready_client.get("/metrics", follow_redirects=False)
    assert response.status_code == 200


def test_root_reports_version_and_pod(ready_client, monkeypatch):
    monkeypatch.setenv("APP_VERSION", "abc1234")
    body = ready_client.get("/").json()
    assert body["service"] == "k3s-gitops-lab"
    assert body["version"] == "abc1234"
    assert body["pod"]
