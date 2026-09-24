# Same two-stage build as the AWS side: dependencies built once, then only the
# runtime bits copied into a slim image — no compilers, no pip cache, no leftovers.
FROM python:3.13-slim AS build
WORKDIR /build
COPY app/requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

FROM python:3.13-slim
WORKDIR /app
COPY --from=build /install /usr/local
COPY app/ .

# Strip pip (and its vendored copies of setuptools/wheel) from the RUNTIME image.
# Two reasons, and the second is the one trivy found:
#   1. A production container has no business carrying a package installer. If
#      something can run `pip install` in there, so can an attacker.
#   2. pip VENDORS its own msgpack and setuptools — 1.1.2 and 70.3.0 here, which
#      carry GHSA-6v7p-g79w-8964 and CVE-2025-47273. Upgrading OUR dependencies
#      does nothing for pip's vendored ones; only removing pip does.
#
# The path comes from the interpreter, never written out as python3.NN. A
# hardcoded version fails OPEN on the next base-image bump: `rm -rf` on a path
# that no longer exists succeeds silently, pip survives into the runtime image,
# and the vendored CVEs above come back with a green build. Not hypothetical —
# that is exactly what happened when Dependabot proposed python:3.14-slim here,
# and trivy caught it. The `test -z` turns the silent failure into a build failure.
RUN SP="$(python -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])')" \
 && STD="$(python -c 'import sysconfig; print(sysconfig.get_paths()["stdlib"])')" \
 && rm -rf "$SP"/pip* "$SP"/setuptools* "$SP"/wheel* \
           "$SP"/_distutils_hack "$SP"/distutils-precedence.pth \
           "$STD"/ensurepip /usr/local/bin/pip* /root/.cache \
 && test -z "$(find /usr/local -maxdepth 6 -name 'pip' -o -maxdepth 6 -name 'setuptools' | head -1)"

# Unprivileged, fixed uid (CI asserts it). Cloud Run runs the container read-only
# apart from /tmp by default, so there is no rootfs flag to set — see
# docs/three-clouds.md.
RUN useradd --create-home --uid 10001 --shell /usr/sbin/nologin appuser
USER appuser

ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=3s --retries=3 \
  CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8080/health', timeout=2).status == 200 else 1)"
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080", "--no-server-header"]
