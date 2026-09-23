"""The same behavioural contract the AWS side asserts, against the GCP port.

Kept deliberately parallel to the AWS and Azure suites so a reviewer can diff all
three and see the API is genuinely identical — only the cloud underneath changed.
"""
import importlib

import pytest
from fake_firestore import FakeCollection
from fastapi.testclient import TestClient


@pytest.fixture
def client(monkeypatch):
    main = importlib.import_module("main")
    fake = FakeCollection()
    monkeypatch.setattr(main, "_notes", lambda: fake)
    monkeypatch.setattr(main, "FAIL_READY", False)
    c = TestClient(main.app)
    c.fake = fake
    return c


def test_health_never_touches_the_backend(monkeypatch):
    """Liveness must answer even when Cosmos is unreachable — otherwise a
    dependency outage gets the container killed instead of drained."""
    main = importlib.import_module("main")
    monkeypatch.setattr(main, "_notes", lambda: FakeCollection(unreachable=True))
    r = TestClient(main.app).get("/health")
    assert r.status_code == 200
    assert r.json() == {"status": "ok"}


def test_ready_is_503_when_cosmos_is_unreachable(monkeypatch):
    main = importlib.import_module("main")
    monkeypatch.setattr(main, "_notes", lambda: FakeCollection(unreachable=True))
    monkeypatch.setattr(main, "FAIL_READY", False)
    r = TestClient(main.app).get("/ready")
    assert r.status_code == 503
    assert r.json()["status"] == "not ready"


def test_ready_ok(client):
    r = client.get("/ready")
    assert r.status_code == 200
    assert r.json()["status"] == "ready"


def test_create_and_get(client):
    r = client.post("/notes", json={"text": "hello"})
    assert r.status_code == 201
    note = r.json()
    assert note["text"] == "hello"

    got = client.get(f"/notes/{note['id']}")
    assert got.status_code == 200
    assert got.json()["text"] == "hello"


def test_get_missing_is_404(client):
    assert client.get("/notes/does-not-exist").status_code == 404


def test_delete_then_missing(client):
    note = client.post("/notes", json={"text": "bye"}).json()
    assert client.delete(f"/notes/{note['id']}").status_code == 204
    assert client.get(f"/notes/{note['id']}").status_code == 404


def test_delete_missing_is_404(client):
    assert client.delete("/notes/nope").status_code == 404


@pytest.mark.parametrize("text", ["", "x" * 4001])
def test_validation_rejects_empty_and_oversized(client, text):
    assert client.post("/notes", json={"text": text}).status_code == 422


def test_list_pagination_is_bounded(client):
    for i in range(5):
        client.post("/notes", json={"text": f"n{i}"})

    r = client.get("/notes", params={"limit": 2})
    body = r.json()
    assert len(body["items"]) == 2
    assert body["next"] is not None

    r2 = client.get("/notes", params={"limit": 2, "cursor": body["next"]})
    assert len(r2.json()["items"]) == 2


def test_list_limit_is_capped(client):
    assert client.get("/notes", params={"limit": 101}).status_code == 422
    assert client.get("/notes", params={"limit": 0}).status_code == 422


def test_security_headers_and_request_id(client):
    r = client.get("/health")
    assert r.headers["X-Content-Type-Options"] == "nosniff"
    assert r.headers["X-Frame-Options"] == "DENY"
    assert r.headers["Content-Security-Policy"] == "default-src 'none'"
    assert r.headers["Cache-Control"] == "no-store"
    assert r.headers["X-Request-Id"]


def test_request_id_is_echoed_from_cloud_run_trace_header(client):
    r = client.get("/health", headers={"X-Cloud-Trace-Context": "abc-123"})
    assert r.headers["X-Request-Id"] == "abc-123"


def test_fail_ready_drill_flag(client, monkeypatch):
    main = importlib.import_module("main")
    monkeypatch.setattr(main, "FAIL_READY", True)
    r = client.get("/ready")
    assert r.status_code == 503
    assert "FAIL_READY" in r.json()["reason"]


def test_docs_endpoints_are_disabled(client):
    for path in ("/docs", "/redoc", "/openapi.json"):
        assert client.get(path).status_code == 404
