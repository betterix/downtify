FROM mwader/static-ffmpeg:9.0.2 AS ffmpeg-bin
FROM denoland/deno:alpine-2.9.7 AS deno

FROM python:3.14-alpine AS builder

WORKDIR /build

COPY requirements.txt .

# Install only the runtime dependencies, then remove pip/setuptools
# so they are not included in the final image.
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install --root-user-action ignore -r requirements.txt && \
    pip uninstall --root-user-action ignore -y pip setuptools

# Build the Vue frontend so the image is self-contained and never ships a
# stale dist. `npm ci` installs exactly what package-lock.json pins; the
# source is copied afterwards so dependency layers stay cached across
# source-only changes.
FROM node:26-alpine AS frontend-builder

WORKDIR /frontend

# Install frontend dependencies from the lockfile for reproducible builds.
COPY frontend/package.json frontend/package-lock.json ./
RUN --mount=type=cache,target=/root/.npm npm install -g npm@latest && npm ci

COPY frontend/ ./
RUN npm run build

# Final minimal runtime image
FROM python:3.14-alpine

LABEL maintainer="Henrique Sebastião <contato@henriquesebastiao.com>"
LABEL version="3.1.0"
LABEL description="Self-hosted Spotify downloader"

LABEL org.opencontainers.image.title="Downtify" \
    org.opencontainers.image.description="Download your Spotify playlists and songs along with album art and metadata in a self-hosted way via Docker." \
    org.opencontainers.image.version="3.1.0" \
    org.opencontainers.image.authors="Henrique Sebastião <contato@henriquesebastiao.com>" \
    org.opencontainers.image.url="https://github.com/henriquesebastiao/downtify" \
    org.opencontainers.image.source="https://github.com/henriquesebastiao/downtify" \
    org.opencontainers.image.licenses="GPL-3.0" \
    org.opencontainers.image.documentation="https://github.com/henriquesebastiao/downtify#readme" \
    org.opencontainers.image.vendor="Henrique Sebastião" \
    org.opencontainers.image.base.name="python:3.14-alpine"

# Runtime configuration
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PYTHON_COLORS=0 \
    DOWNTIFY_LOG_LEVEL=info \
    DOWNTIFY_PORT=8000 \
    DOWNTIFY_HEALTHCHECK=1 \
    UID=1000 \
    GID=1000 \
    UMASK=022

WORKDIR /downtify

# Small set of runtime utilities:
# user management, privilege dropping, init process, and timezone data.
RUN apk add --no-cache \
    shadow \
    su-exec \
    tini \
    tzdata 

# Add Deno and its glibc runtime to the Alpine image.
COPY --from=deno /bin/deno /usr/local/bin/deno
COPY --from=deno /usr/local/lib/glibc /usr/local/lib/glibc
COPY --from=deno /lib/ld-linux-* /lib/
RUN mkdir -p /lib64 && ln -sf /usr/local/lib/glibc/ld-linux-* /lib64/

# Remove the Python packages that come with the base image before
# copying in the exact environment built above.
RUN rm -rf /usr/local/lib/python3.14/site-packages/*

# Add FFmpeg/ffprobe binaries
COPY --from=ffmpeg-bin /ffmpeg /usr/local/bin/ffmpeg
COPY --from=ffmpeg-bin /ffprobe /usr/local/bin/ffprobe

# Copy Python dependencies and their installed CLI entry points
COPY --from=builder /usr/local/lib/python3.14/site-packages /usr/local/lib/python3.14/site-packages
COPY --from=builder /usr/local/bin /usr/local/bin

# Application files
COPY --chmod=755 main.py entrypoint.sh healthcheck.sh ./
COPY downtify ./downtify

COPY --from=frontend-builder /frontend/dist ./frontend/dist

# Normalize scripts to Unix line endings
RUN sed -i 's/\r$//g' entrypoint.sh healthcheck.sh

ENV PATH="/home/downtify/.local/bin:${PATH}"

VOLUME /downloads
VOLUME /data

EXPOSE ${DOWNTIFY_PORT}

# Container health monitoring
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD ./healthcheck.sh

# tini handles signals/zombie processes and starts the application
ENTRYPOINT ["/sbin/tini", "-g", "--", "./entrypoint.sh"]