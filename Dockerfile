ARG USE_CUDA=false
ARG USE_OLLAMA=false
ARG USE_SLIM=false
ARG USE_PERMISSION_HARDENING=false
ARG USE_CUDA_VER=cu128
ARG USE_EMBEDDING_MODEL=sentence-transformers/all-MiniLM-L6-v2
ARG USE_RERANKING_MODEL=""
ARG USE_AUXILIARY_EMBEDDING_MODEL=TaylorAI/bge-micro-v2
ARG USE_TIKTOKEN_ENCODING_NAME="cl100k_base"
ARG BUILD_HASH=dev-build
ARG UID=1001
ARG GID=0

######## WebUI frontend ########
FROM node:22-alpine3.20 AS frontend-build
ARG BUILD_HASH
WORKDIR /app
RUN apk add --no-cache git
COPY package.json package-lock.json ./
RUN npm ci --force
COPY . .
ENV APP_BUILD_HASH=${BUILD_HASH}
RUN npm run build

######## Python dependencies builder ########
FROM registry.access.redhat.com/ubi9/python-311:latest AS python-builder
ARG USE_CUDA
ARG USE_CUDA_VER
ARG USE_SLIM

# Copy requirements
COPY ./backend/requirements.txt ./requirements.txt

# Install build dependencies
USER root
RUN dnf install -y gcc gcc-c++ git && \
    dnf clean all

# Install Python dependencies as default user
USER 1001
RUN pip install --no-cache-dir --user uv && \
    if [ "$USE_CUDA" = "true" ]; then \
        pip install --user --no-cache-dir torch torchvision torchaudio --index-url https://download.pytorch.org/whl/$USE_CUDA_VER && \
        ~/.local/bin/uv pip install --user -r requirements.txt --no-cache-dir; \
    else \
        pip install --user --no-cache-dir torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cpu && \
        ~/.local/bin/uv pip install --user -r requirements.txt --no-cache-dir; \
    fi

######## WebUI backend - UBI Minimal Runtime ########
FROM registry.access.redhat.com/ubi9/ubi-minimal:latest

# Use args
ARG USE_CUDA
ARG USE_OLLAMA
ARG USE_SLIM
ARG USE_PERMISSION_HARDENING
ARG UID=1001
ARG GID=0
ARG BUILD_HASH

# Install Python 3.11 dan system packages
RUN microdnf install -y \
        python3.11 \
        python3.11-pip \
        git \
        curl \
        tar \
        gzip \
        jq \
        findutils \
        which \
        bash \
        shadow-utils && \
    microdnf clean all

# Install ffmpeg
RUN curl -L -o /tmp/ffmpeg.tar.xz https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz && \
    tar -xf /tmp/ffmpeg.tar.xz -C /tmp && \
    cp /tmp/ffmpeg-*/ffmpeg /usr/local/bin/ && \
    cp /tmp/ffmpeg-*/ffprobe /usr/local/bin/ && \
    rm -rf /tmp/ffmpeg* && \
    microdnf clean all

# Set environment variables
ENV PYTHONUNBUFFERED=1 \
    ENV=prod \
    PORT=8080 \
    PATH="/home/app/.local/bin:$PATH"

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
    mkdir -p /home/app/.cache/chroma /app/backend/data && \
    echo -n 00000000-0000-0000-0000-000000000000 > /home/app/.cache/chroma/telemetry_user_id && \
    chown -R $UID:$GID /app /home/app

# Copy Python dependencies - PERBAIKAN PATH
COPY --from=python-builder --chown=$UID:$GID /home/default/.local /home/app/.local

# Copy frontend build
COPY --from=frontend-build --chown=$UID:$GID /app/build /app/build
COPY --from=frontend-build --chown=$UID:$GID /app/CHANGELOG.md /app/CHANGELOG.md
COPY --from=frontend-build --chown=$UID:$GID /app/package.json /app/package.json

# Copy backend files
COPY --chown=$UID:$GID ./backend .

# Permission hardening for OpenShift
RUN if [ "$USE_PERMISSION_HARDENING" = "true" ]; then \
        chgrp -R 0 /app /home/app && \
        chmod -R g+rwX /app /home/app && \
        find /app -type d -exec chmod g+s {} + && \
        find /home/app -type d -exec chmod g+s {} +; \
    fi

EXPOSE 8080

# Health check
HEALTHCHECK CMD curl --silent --fail http://localhost:${PORT:-8080}/health | jq -ne 'input.status == true' || exit 1

ENV WEBUI_BUILD_VERSION=${BUILD_HASH} \
    DOCKER=true

USER $UID:$GID

CMD ["bash", "start.sh"]