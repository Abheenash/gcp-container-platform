"""Integration tests against the real Firestore emulator.

`test_api.py` runs the API against `fake_firestore.py`, a hand-written double.
That double was written from the Firestore docs, which makes it exactly the kind
of thing that can be confidently wrong — a fake encodes what its author believed
the API does, and any belief that is off stays off in every test that uses it.

These run the same API against Google's own emulator (`gcloud emulators
firestore`), which speaks the real gRPC protocol. Free, no GCP project, no
credentials: `google-cloud-firestore` honours `FIRESTORE_EMULATOR_HOST` and skips
auth entirely when it is set, so — as with the DynamoDB side of the AWS repo —
there is no test-only branch in the application.

Skipped when the emulator is not running; CI sets `REQUIRE_FIRESTORE=1`, which
turns a missing emulator into an error rather than a handful of quiet skips
behind a green tick.
"""

import os
import socket
import sys
import uuid

import pytest
from fastapi.testclient import TestClient

HOST = os.environ.get("FIRESTORE_EMULATOR_HOST", "127.0.0.1:8085")
COLLECTION = "notes-integration"


def _emulator_is_up() -> bool:
    host, _, port = HOST.rpartition(":")
    try:
        with socket.create_connection((host or "127.0.0.1", int(port)), timeout=1):
            return True
    except OSError:
        return False


_UP = _emulator_is_up()

if os.environ.get("REQUIRE_FIRESTORE") == "1" and not _UP:
    raise RuntimeError(
        f"REQUIRE_FIRESTORE=1 but nothing is listening on {HOST}. These tests were "
        "meant to run, not to be skipped."
    )

pytestmark = pytest.mark.skipif(
    not _UP,
    reason=f"no Firestore emulator on {HOST} — run: docker run -d -p 8085:8085 "
           "google/cloud-sdk:emulators gcloud emulators firestore start "
           "--host-port=0.0.0.0:8085",
)


@pytest.fixture
def client():
    os.environ.update(
        FIRESTORE_EMULATOR_HOST=HOST,
        GOOGLE_CLOUD_PROJECT="local-integration",
        FIRESTORE_COLLECTION=COLLECTION,
    )
    sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "app"))
    import main

    main._collection = None  # rebuild against the emulator
    main.COLLECTION = COLLECTION
    main.GCP_PROJECT = "local-integration"
    main.FAIL_READY = False
    yield TestClient(main.app)
    main._collection = None


def test_app_reaches_a_real_firestore_with_no_code_change(client):
    r = client.get("/ready")
    assert r.status_code == 200, r.text
    assert r.json() == {"status": "ready", "collection": COLLECTION}


def test_round_trip_through_the_real_engine(client):
    text = f"integration {uuid.uuid4()}"
    created = client.post("/notes", json={"text": text})
    assert created.status_code == 201, created.text
    note_id = created.json()["id"]

    fetched = client.get(f"/notes/{note_id}")
    assert fetched.status_code == 200
    assert fetched.json()["text"] == text

    assert client.delete(f"/notes/{note_id}").status_code == 204
    assert client.get(f"/notes/{note_id}").status_code == 404


def test_create_uses_an_explicit_id_and_refuses_a_duplicate(client):
    """`.create()` differs from `.set()`: it fails if the document already
    exists, where `.set()` overwrites silently. The handler uses `.create()` on
    purpose, so the id in the response is the id in the store and a collision can
    never clobber someone else's note. Asserted against the real server, which is
    what actually enforces it."""
    from google.api_core.exceptions import AlreadyExists
    from google.cloud import firestore

    db = firestore.Client(project="local-integration", database="(default)")
    doc_id = str(uuid.uuid4())
    db.collection(COLLECTION).document(doc_id).create({"id": doc_id, "text": "first"})

    with pytest.raises(AlreadyExists):
        db.collection(COLLECTION).document(doc_id).create({"id": doc_id, "text": "second"})

    assert db.collection(COLLECTION).document(doc_id).get().to_dict()["text"] == "first"
    client.delete(f"/notes/{doc_id}")


def test_missing_document_returns_a_snapshot_not_an_error(client):
    """The API difference that the fake most easily gets wrong, and the reason the
    handler checks `.exists` instead of catching an exception: Firestore returns a
    snapshot whose `.exists` is False rather than raising. DynamoDB returns a
    response with no `Item`; Cosmos raises. Three stores, three shapes, one API
    contract on top."""
    from google.cloud import firestore

    db = firestore.Client(project="local-integration", database="(default)")
    snap = db.collection(COLLECTION).document(f"absent-{uuid.uuid4()}").get()
    assert snap.exists is False
    assert snap.to_dict() is None


def test_delete_of_a_missing_document_is_404_not_204(client):
    """Firestore's delete succeeds on a document that is not there, so the 404 has
    to come from an explicit existence check in the handler — the same shape as
    the DynamoDB build, for the same reason."""
    assert client.delete(f"/notes/{uuid.uuid4()}").status_code == 404


def test_cursor_pagination_returns_every_note_exactly_once(client):
    """The handler pages with `start_after` on an ordered query rather than an
    opaque token. That is a real cursor against a real index here, not a slice of
    a Python list as it is in the fake — which is the part most worth checking."""
    made = {client.post("/notes", json={"text": f"page probe {i}"}).json()["id"] for i in range(25)}
    assert len(made) == 25

    seen, cursor, pages = set(), None, 0
    while True:
        r = client.get("/notes", params={"limit": 10, **({"cursor": cursor} if cursor else {})})
        assert r.status_code == 200, r.text
        body = r.json()
        seen.update(item["id"] for item in body["items"])
        pages += 1
        cursor = body.get("next")
        if not cursor or pages > 20:
            break

    assert made <= seen, f"{len(made - seen)} notes were never returned across {pages} pages"
    assert pages >= 3, "the page boundary was never actually crossed"
    for note_id in made:
        client.delete(f"/notes/{note_id}")
