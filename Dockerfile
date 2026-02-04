# ==========================================
# Open WebUI (Nexus) - RHEL UBI 9 Build
# ==========================================
ARG USE_CUDA=false
ARG USE_OLLAMA=false
ARG USE_SLIM=true
ARG USE_PERMISSION_HARDENING=true
ARG USE_CUDA_VER=cu128
ARG USE_EMBEDDING_MODEL=sentence-transformers/all-MiniLM-L6-v2
ARG USE_RERANKING_MODEL=""
ARG USE_AUXILIARY_EMBEDDING_MODEL=TaylorAI/bge-micro-v2
ARG USE_TIKTOKEN_ENCODING_NAME="cl100k_base"
ARG BUILD_HASH=dev-build
ARG UID=1001
ARG GID=0

# ==========================================
# Stage 1: Frontend Build (Node.js)
# ==========================================
FROM node:22-alpine3.20 AS frontend-build
ARG BUILD_HASH

WORKDIR /app

# Install git for potential dependencies
RUN apk add --no-cache git

# Copy package files first for better caching
COPY package.json package-lock.json ./
RUN npm ci --force

# Copy source and build
COPY . .
ENV APP_BUILD_HASH=${BUILD_HASH}
RUN npm run build

# ==========================================
# Stage 2: Python Dependencies Builder
# ==========================================
FROM registry.access.redhat.com/ubi9/python-311:1-77 AS python-builder
ARG USE_CUDA
ARG USE_CUDA_VER
ARG USE_SLIM

WORKDIR /opt/app-root/src

# Install build dependencies as root
USER 0
RUN dnf install -y gcc gcc-c++ git && \
    dnf clean all

# Switch back to default user (UID 1001)
USER 1001

# Copy requirements
COPY ./backend/requirements.txt ./requirements.txt

# Upgrade pip and install dependencies
RUN pip install --no-cache-dir --user --upgrade pip wheel setuptools && \
    pip install --no-cache-dir --user uv && \
    if [ "$USE_CUDA" = "true" ]; then \
        pip install --user --no-cache-dir torch torchvision torchaudio --index-url https://download.pytorch.org/whl/$USE_CUDA_VER && \
        ~/.local/bin/uv pip install --user -r requirements.txt --no-cache-dir; \
    else \
        pip install --user --no-cache-dir torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cpu && \
        ~/.local/bin/uv pip install --user -r requirements.txt --no-cache-dir; \
    fi

# ==========================================
# Stage 3: Runtime (UBI Minimal)
# ==========================================
FROM registry.access.redhat.com/ubi9/ubi-minimal:9.5-1733767867

ARG USE_CUDA
ARG USE_OLLAMA
ARG USE_SLIM
ARG USE_PERMISSION_HARDENING
ARG UID=1001
ARG GID=0
ARG BUILD_HASH

# Install Python 3.11 and system packages
# Remove vulnerable pip/setuptools from OS packages
RUN microdnf upgrade -y --refresh --best --nodocs && \
    microdnf install -y \
        python3.11 \
        git \
        curl-minimal \
        tar \
        gzip \
        jq \
        findutils \
        which \
        bash \
        shadow-utils && \
    # Remove vulnerable OS-level pip/setuptools
    rpm -e --nodeps python3-pip python3-setuptools python3-wheel 2>/dev/null || true && \
    rm -rf /usr/lib/python3.11/site-packages/setuptools* \
           /usr/lib/python3.11/site-packages/pip* \
           /usr/lib/python3.11/site-packages/wheel* \
           /usr/share/python3.11-wheels \
           /usr/lib/python3.11/ensurepip && \
    microdnf clean all

# Install ffmpeg (static build)
RUN curl -L -o /tmp/ffmpeg.tar.xz https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz && \
    tar -xf /tmp/ffmpeg.tar.xz -C /tmp && \
    cp /tmp/ffmpeg-*/ffmpeg /usr/local/bin/ && \
    cp /tmp/ffmpeg-*/ffprobe /usr/local/bin/ && \
    rm -rf /tmp/ffmpeg* && \
    chmod +x /usr/local/bin/ffmpeg /usr/local/bin/ffprobe

# Set environment variables
ENV PYTHONUNBUFFERED=1 \
    ENV=prod \
    PORT=8080 \
    PATH="/home/app/.local/bin:$PATH" \
    PYTHONPATH="/home/app/.local/lib/python3.11/site-packages"

# Model settings
ENV WHISPER_MODEL="base" \
    WHISPER_MODEL_DIR="/app/backend/data/cache/whisper/models" \
    SENTENCE_TRANSFORMERS_HOME="/app/backend/data/cache/embedding/models" \
    TIKTOKEN_ENCODING_NAME="cl100k_base" \
    TIKTOKEN_CACHE_DIR="/app/backend/data/cache/tiktoken" \
    HF_HOME="/app/backend/data/cache/embedding/models"

WORKDIR /app/backend

# Create user and directories
RUN useradd -u $UID -g $GID -r -m -d /home/app app && \
    mkdir -p /home/app/.cache/chroma \
             /app/backend/data/cache/whisper/models \
             /app/backend/data/cache/embedding/models \
             /app/backend/data/cache/tiktoken && \
    echo -n 00000000-0000-0000-0000-000000000000 > /home/app/.cache/chroma/telemetry_user_id && \
    chown -R $UID:$GID /app /home/app

# Copy Python dependencies from builder
# UBI9 python-311 image uses /opt/app-root/src/.local for user installs
COPY --from=python-builder --chown=$UID:$GID /opt/app-root/src/.local /home/app/.local

# Copy frontend build
COPY --from=frontend-build --chown=$UID:$GID /app/build /app/build
COPY --from=frontend-build --chown=$UID:$GID /app/CHANGELOG.md /app/CHANGELOG.md
COPY --from=frontend-build --chown=$UID:$GID /app/package.json /app/package.json

# Copy backend files
COPY --chown=$UID:$GID ./backend .

# Permission hardening for OpenShift/Cloud Run
RUN if [ "$USE_PERMISSION_HARDENING" = "true" ]; then \
        chgrp -R 0 /app /home/app && \
        chmod -R g+rwX /app /home/app && \
        find /app -type d -exec chmod g+s {} + 2>/dev/null || true && \
        find /home/app -type d -exec chmod g+s {} + 2>/dev/null || true; \
    fi

EXPOSE 8080

# Health check using curl-minimal
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD curl --silent --fail http://localhost:${PORT:-8080}/health | jq -ne 'input.status == true' || exit 1

ENV WEBUI_BUILD_VERSION=${BUILD_HASH} \
    DOCKER=true

USER $UID:$GID

CMD ["bash", "start.sh"]
