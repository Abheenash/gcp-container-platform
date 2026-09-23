"""In-memory stand-in for a Firestore collection.

Implements only the methods the app uses, with Firestore's actual semantics —
which differ from Cosmos and DynamoDB in two ways worth encoding here:

  * a read of a missing document returns a snapshot with .exists == False rather
    than raising, and
  * a delete of a missing document SUCCEEDS.

Both are why the app has explicit existence checks, and both are what these
fakes preserve.
"""


class _Snapshot:
    def __init__(self, data):
        self._data = data
        self.exists = data is not None

    def to_dict(self):
        return dict(self._data) if self._data else None


class _Document:
    def __init__(self, store, doc_id):
        self._store, self._id = store, doc_id

    def get(self):
        return _Snapshot(self._store.get(self._id))

    def create(self, data):
        if self._id in self._store:
            raise ValueError("already exists")
        self._store[self._id] = dict(data)

    def delete(self):
        # Firestore's delete is idempotent: no error on a missing document.
        self._store.pop(self._id, None)


class _Query:
    def __init__(self, store, limit=None, after=None):
        self._store, self._limit, self._after = store, limit, after

    def order_by(self, field):
        return _Query(self._store, self._limit, self._after)

    def limit(self, n):
        return _Query(self._store, n, self._after)

    def start_after(self, doc):
        return _Query(self._store, self._limit, doc["id"])

    def stream(self):
        items = sorted(self._store.values(), key=lambda d: d["id"])
        if self._after is not None:
            items = [d for d in items if d["id"] > self._after]
        if self._limit is not None:
            items = items[: self._limit]
        return iter([_Snapshot(d) for d in items])


class FakeCollection:
    def __init__(self, unreachable=False):
        self.store = {}
        self.unreachable = unreachable

    def document(self, doc_id):
        return _Document(self.store, doc_id)

    def limit(self, n):
        if self.unreachable:
            raise ConnectionError("firestore unreachable")
        return _Query(self.store, n)

    def order_by(self, field):
        if self.unreachable:
            raise ConnectionError("firestore unreachable")
        return _Query(self.store).order_by(field)
