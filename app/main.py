"""Minimal notes API — the third build of the same service.

Same API as `secure-container-pipeline` (AWS: Fargate + DynamoDB) and
`azure-container-platform` (Azure: Container Apps + Cosmos DB), now on
Cloud Run + Firestore. Routes, status codes, log shape and security headers are
identical on purpose — only the cloud underneath changes, which is what makes the
three-way diff worth reading. See docs/three-clouds.md.

GET  /health          liveness: the process is up (no GCP calls — never fails because a
                      dependency is down, which is what a liveness probe must not do)
GET  /ready           readiness: the Firestore collection is reachable (Cloud Run's
                      startup probe gates traffic on it)
POST /notes           create a note
GET  /notes/{id}      fetch one
GET  /notes           list (paginated by cursor document, bounded page size)
DELETE /notes/{id}    delete one
"""

import json
import logging
import os
import sys
import time
import uuid

from fastapi import FastAPI, HTTPException, Query, Request, Response
from pydantic import BaseModel, Field

GCP_PROJECT = os.environ.get("GOOGLE_CLOUD_PROJECT", "")
FIRESTORE_DB = os.environ.get("FIRESTORE_DATABASE", "(default)")
COLLECTION = os.environ.get("FIRESTORE_COLLECTION", "notes")
MAX_TEXT = int(os.environ.get("MAX_TEXT", "4000"))
# Drill switch: a revision with FAIL_READY=1 reports not-ready while staying alive —
# the shape of a dependency outage. Cloud Run fails the startup probe and holds
# traffic on the previous revision. Mirrors the AWS side's CodeDeploy
# circuit-breaker drill and the Azure side's revision rollback.
FAIL_READY = os.environ.get("FAIL_READY", "") == "1"

app = FastAPI(title="gcp-container-platform notes API", docs_url=None, redoc_url=None, openapi_url=None)

_log = logging.getLogger("notes")
_log.setLevel(logging.INFO)
_h = logging.StreamHandler(sys.stdout)
_h.setFormatter(logging.Formatter("%(message)s"))
_log.handlers = [_h]
_log.propagate = False

_collection = None


def _notes():
    """Resolved lazily so the module imports (and /health answers) without GCP.

    google.auth picks up the Cloud Run service's attached service account at
    runtime and a developer's `gcloud auth application-default login` locally —
    there is no key file anywhere. This is the direct counterpart of the AWS task
    role and the Azure managed identity.
    """
    global _collection
    if _collection is None:
        from google.cloud import firestore

        client = firestore.Client(project=GCP_PROJECT or None, database=FIRESTORE_DB)
        _collection = client.collection(COLLECTION)
    return _collection


class NoteIn(BaseModel):
    text: str = Field(min_length=1, max_length=MAX_TEXT)


@app.middleware("http")
async def request_context(request: Request, call_next):
    t0 = time.time()
    # Cloud Run propagates X-Cloud-Trace-Context; Container Apps sets Request-Id;
    # the AWS side reads X-Amzn-Trace-Id. Same idea, three header names.
    rid = (request.headers.get("x-cloud-trace-context") or request.headers.get("x-request-id")
           or str(uuid.uuid4()))
    try:
        response = await call_next(request)
    except Exception:
        _log.info(json.dumps({"rid": rid, "method": request.method, "path": request.url.path,
                              "status": 500, "ms": round((time.time() - t0) * 1000, 1)}))
        raise
    response.headers["X-Request-Id"] = rid
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["X-Frame-Options"] = "DENY"
    response.headers["Cache-Control"] = "no-store"
    response.headers["Content-Security-Policy"] = "default-src 'none'"
    _log.info(json.dumps({"rid": rid, "method": request.method, "path": request.url.path,
                          "status": response.status_code, "ms": round((time.time() - t0) * 1000, 1)}))
    return response


@app.get("/health")
def health():
    return {"status": "ok"}


@app.get("/ready")
def ready(response: Response):
    if FAIL_READY:
        response.status_code = 503
        return {"status": "not ready", "reason": "FAIL_READY drill flag"}
    try:
        # A bounded read that proves the identity and the network path without
        # scanning the collection.
        next(_notes().limit(1).stream(), None)
        return {"status": "ready", "collection": COLLECTION}
    except Exception as e:
        response.status_code = 503
        return {"status": "not ready", "reason": type(e).__name__}


@app.post("/notes", status_code=201)
def create_note(note: NoteIn):
    item = {"id": str(uuid.uuid4()), "text": note.text, "createdAt": int(time.time())}
    # Explicit document id rather than an auto-id, so the id in the response is
    # the id in the store — same contract as the other two builds.
    _notes().document(item["id"]).create(item)
    return item


@app.get("/notes/{note_id}")
def get_note(note_id: str):
    # Firestore returns a snapshot whose .exists is False rather than raising —
    # a genuine API difference from both Cosmos and DynamoDB.
    snap = _notes().document(note_id).get()
    if not snap.exists:
        raise HTTPException(status_code=404, detail="note not found")
    return snap.to_dict()


@app.delete("/notes/{note_id}", status_code=204)
def delete_note(note_id: str):
    doc = _notes().document(note_id)
    # Firestore's delete is idempotent and succeeds on a missing document, so the
    # existence check has to be explicit to keep the 404 contract.
    if not doc.get().exists:
        raise HTTPException(status_code=404, detail="note not found")
    doc.delete()
    return Response(status_code=204)


@app.get("/notes")
def list_notes(limit: int = Query(20, ge=1, le=100), cursor: str | None = None):
    # Firestore pages by cursor document, not by an opaque token: order by id and
    # start after the last one seen.
    q = _notes().order_by("id").limit(limit)
    if cursor:
        q = q.start_after({"id": cursor})
    items = [d.to_dict() for d in q.stream()]
    nxt = items[-1]["id"] if len(items) == limit else None
    return {"items": items, "next": nxt}
