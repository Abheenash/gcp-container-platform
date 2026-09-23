import os
import pathlib
import sys

# The app is imported as a top-level module inside the image (WORKDIR /app), so
# tests put app/ on the path the same way rather than inventing a package.
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "app"))

os.environ.setdefault("GOOGLE_CLOUD_PROJECT", "test-project")
os.environ.setdefault("FIRESTORE_COLLECTION", "notes")
