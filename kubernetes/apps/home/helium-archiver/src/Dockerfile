# First-party image for the helium archiver.
# Build & push to the repo's GHCR org before deploying:
#   docker build -t ghcr.io/bluevulpine/helium-archiver:0.1.0 .
#   docker push ghcr.io/bluevulpine/helium-archiver:0.1.0
FROM python:3.14-slim AS base

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY main.py storage.py schema.sql ./

# Run as a non-root, no-home user to match the pod securityContext (uid 1000)
# and the readOnlyRootFilesystem hardening (only /tmp is writable).
USER 1000:1000

ENTRYPOINT ["python", "/app/main.py"]
