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
