# # syntax=docker/dockerfile:1

# # Initialize device type args
# # use build args in the docker build command with --build-arg="BUILDARG=true"
# ARG USE_CUDA=false
# ARG USE_OLLAMA=false
# ARG USE_SLIM=false
# ARG USE_PERMISSION_HARDENING=false

# # Tested with cu117 for CUDA 11 and cu121 for CUDA 12 (default)
# ARG USE_CUDA_VER=cu128

# # any sentence transformer model; models to use can be found at https://huggingface.co/models?library=sentence-transformers
# # Leaderboard: https://huggingface.co/spaces/mteb/leaderboard
# # for better performance and multilangauge support use "intfloat/multilingual-e5-large" (~2.5GB) or "intfloat/multilingual-e5-base" (~1.5GB)
# # IMPORTANT: If you change the embedding model (sentence-transformers/all-MiniLM-L6-v2) and vice versa, you aren't able to use RAG Chat with your previous documents loaded in the WebUI! You need to re-embed them.
# ARG USE_EMBEDDING_MODEL=sentence-transformers/all-MiniLM-L6-v2
# ARG USE_RERANKING_MODEL=""
# ARG USE_AUXILIARY_EMBEDDING_MODEL=TaylorAI/bge-micro-v2

# # Tiktoken encoding name; models to use can be found at https://huggingface.co/models?library=tiktoken
# ARG USE_TIKTOKEN_ENCODING_NAME="cl100k_base"

# ARG BUILD_HASH=dev-build

# # UBI9 default user is 1001, group 0 for OpenShift compatibility
# ARG UID=1001
# ARG GID=0

# ######## WebUI frontend ########
# FROM node:22-alpine3.20 AS build
# ARG BUILD_HASH

# # Set Node.js options (heap limit Allocation failed - JavaScript heap out of memory)
# # ENV NODE_OPTIONS="--max-old-space-size=4096"

# WORKDIR /app

# # to store git revision in build
# RUN apk add --no-cache git

# COPY package.json package-lock.json ./
# RUN npm ci --force

# COPY . .

# ENV APP_BUILD_HASH=${BUILD_HASH}
# RUN npm run build

# ######## WebUI backend ########
# FROM registry.access.redhat.com/ubi9/python-311:latest AS base

# # Use args
# ARG USE_CUDA
# ARG USE_OLLAMA
# ARG USE_CUDA_VER
# ARG USE_SLIM
# ARG USE_PERMISSION_HARDENING
# ARG USE_EMBEDDING_MODEL
# ARG USE_RERANKING_MODEL
# ARG USE_AUXILIARY_EMBEDDING_MODEL
# ARG UID
# ARG GID

# # Python settings
# ENV PYTHONUNBUFFERED=1

# ## Basis ##
# ENV ENV=prod \
#     PORT=8080 \
#     # pass build args to the build
#     USE_OLLAMA_DOCKER=${USE_OLLAMA} \
#     USE_CUDA_DOCKER=${USE_CUDA} \
#     USE_SLIM_DOCKER=${USE_SLIM} \
#     USE_CUDA_DOCKER_VER=${USE_CUDA_VER} \
#     USE_EMBEDDING_MODEL_DOCKER=${USE_EMBEDDING_MODEL} \
#     USE_RERANKING_MODEL_DOCKER=${USE_RERANKING_MODEL} \
#     USE_AUXILIARY_EMBEDDING_MODEL_DOCKER=${USE_AUXILIARY_EMBEDDING_MODEL}

# ## Basis URL Config ##
# ENV OLLAMA_BASE_URL="/ollama" \
#     OPENAI_API_BASE_URL=""

# ## API Key and Security Config ##
# ENV OPENAI_API_KEY="" \
#     WEBUI_SECRET_KEY="" \
#     SCARF_NO_ANALYTICS=true \
#     DO_NOT_TRACK=true \
#     ANONYMIZED_TELEMETRY=false

# #### Other models #########################################################

# ## whisper TTS model settings ##
# ENV WHISPER_MODEL="base" \
#     WHISPER_MODEL_DIR="/app/backend/data/cache/whisper/models"

# ## RAG Embedding model settings ##
# ENV RAG_EMBEDDING_MODEL="$USE_EMBEDDING_MODEL_DOCKER" \
#     RAG_RERANKING_MODEL="$USE_RERANKING_MODEL_DOCKER" \
#     AUXILIARY_EMBEDDING_MODEL="$USE_AUXILIARY_EMBEDDING_MODEL_DOCKER" \
#     SENTENCE_TRANSFORMERS_HOME="/app/backend/data/cache/embedding/models"

# ## Tiktoken model settings ##
# ENV TIKTOKEN_ENCODING_NAME="cl100k_base" \
#     TIKTOKEN_CACHE_DIR="/app/backend/data/cache/tiktoken"

# ## Hugging Face download cache ##
# ENV HF_HOME="/app/backend/data/cache/embedding/models"

# ## Torch Extensions ##
# # ENV TORCH_EXTENSIONS_DIR="/.cache/torch_extensions"

# #### Other models ##########################################################

# WORKDIR /app/backend
# ENV HOME=/root

# # Switch to root for installation
# USER 0

# # Install EPEL repository for additional packages
# RUN dnf install -y \
#     https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm \
#     && dnf clean all

# # Install system dependencies using dnf
# # Note: ffmpeg skipped (requires libSDL2 not available in UBI), curl skipped (curl-minimal already installed)
# RUN dnf install -y --setopt=install_weak_deps=False \
#     git \
#     gcc \
#     gcc-c++ \
#     make \
#     pandoc \
#     jq \
#     python3-devel \
#     nmap-ncat \
#     libSM \
#     libXext \
#     && dnf clean all

# # Create user and group if not using default UBI user (1001)
# RUN if [ $UID -ne 1001 ]; then \
#         if [ $GID -ne 0 ] && ! getent group $GID > /dev/null 2>&1; then \
#             groupadd --gid $GID app; \
#         fi; \
#         useradd --uid $UID --gid $GID --home-dir $HOME --no-create-home --shell /bin/bash app; \
#     fi

# # Create necessary directories
# RUN mkdir -p $HOME/.cache/chroma && \
#     echo -n 00000000-0000-0000-0000-000000000000 > $HOME/.cache/chroma/telemetry_user_id

# # Make sure the user has access to the app and root directory
# RUN chown -R $UID:$GID /app $HOME

# # Install python dependencies
# COPY --chown=$UID:$GID ./backend/requirements.txt ./requirements.txt

# RUN if [ "$USE_CUDA" = "true" ]; then \
#         # If you use CUDA the whisper and embedding model will be downloaded on first use
#         pip3 install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/$USE_CUDA_DOCKER_VER --no-cache-dir && \
#         pip3 install --no-cache-dir -r requirements.txt && \
#         python -c "import os; from sentence_transformers import SentenceTransformer; SentenceTransformer(os.environ['RAG_EMBEDDING_MODEL'], device='cpu')" && \
#         python -c "import os; from sentence_transformers import SentenceTransformer; SentenceTransformer(os.environ.get('AUXILIARY_EMBEDDING_MODEL', 'TaylorAI/bge-micro-v2'), device='cpu')" && \
#         python -c "import os; from faster_whisper import WhisperModel; WhisperModel(os.environ['WHISPER_MODEL'], device='cpu', compute_type='int8', download_root=os.environ['WHISPER_MODEL_DIR'])" && \
#         python -c "import os; import tiktoken; tiktoken.get_encoding(os.environ['TIKTOKEN_ENCODING_NAME'])"; \
#     else \
#         pip3 install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cpu --no-cache-dir && \
#         pip3 install --no-cache-dir -r requirements.txt && \
#         if [ "$USE_SLIM" != "true" ]; then \
#             python -c "import os; from sentence_transformers import SentenceTransformer; SentenceTransformer(os.environ['RAG_EMBEDDING_MODEL'], device='cpu')" && \
#             python -c "import os; from sentence_transformers import SentenceTransformer; SentenceTransformer(os.environ.get('AUXILIARY_EMBEDDING_MODEL', 'TaylorAI/bge-micro-v2'), device='cpu')" && \
#             python -c "import os; from faster_whisper import WhisperModel; WhisperModel(os.environ['WHISPER_MODEL'], device='cpu', compute_type='int8', download_root=os.environ['WHISPER_MODEL_DIR'])" && \
#             python -c "import os; import tiktoken; tiktoken.get_encoding(os.environ['TIKTOKEN_ENCODING_NAME'])"; \
#         fi; \
#     fi && \
#     mkdir -p /app/backend/data && \
#     chown -R $UID:$GID /app/backend/data/ && \
#     dnf clean all

# # Install Ollama if requested
# RUN if [ "$USE_OLLAMA" = "true" ]; then \
#         date +%s > /tmp/ollama_build_hash && \
#         echo "Cache broken at timestamp: $(cat /tmp/ollama_build_hash)" && \
#         curl -fsSL https://ollama.com/install.sh | sh && \
#         dnf clean all; \
#     fi

# # Copy built frontend files
# COPY --chown=$UID:$GID --from=build /app/build /app/build
# COPY --chown=$UID:$GID --from=build /app/CHANGELOG.md /app/CHANGELOG.md
# COPY --chown=$UID:$GID --from=build /app/package.json /app/package.json

# # Copy backend files
# COPY --chown=$UID:$GID ./backend .

# EXPOSE 8080

# HEALTHCHECK CMD curl --silent --fail http://localhost:${PORT:-8080}/health | jq -ne 'input.status == true' || exit 1

# # Permission hardening for OpenShift (arbitrary UID):
# # - Group 0 owns /app and /root
# # - Directories are group-writable and have SGID so new files inherit GID 0
# # This is enabled by default for UBI images to ensure OpenShift compatibility
# RUN chgrp -R 0 /app $HOME && \
#     chmod -R g+rwX /app $HOME && \
#     find /app -type d -exec chmod g+s {} + 2>/dev/null || true && \
#     find $HOME -type d -exec chmod g+s {} + 2>/dev/null || true

# # Switch to non-root user
# USER $UID:$GID

# ARG BUILD_HASH
# ENV WEBUI_BUILD_VERSION=${BUILD_HASH}
# ENV DOCKER=true

# CMD [ "bash", "start.sh"]

# syntax=docker/dockerfile:1
# Initialize device type args
ARG BUILDPLATFORM=linux/amd64
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
FROM --platform=$BUILDPLATFORM node:22-alpine3.20 AS frontend-build
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
ARG USE_EMBEDDING_MODEL
ARG USE_AUXILIARY_EMBEDDING_MODEL

# Copy requirements and install Python dependencies
COPY ./backend/requirements.txt ./requirements.txt

# Install build dependencies
USER root
RUN dnf install -y gcc gcc-c++ git && \
    dnf clean all

# Install Python dependencies as user
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
FROM registry.access.redhat.com/ubi9/ubi-minimal:latest AS base

# Use args
ARG USE_CUDA
ARG USE_OLLAMA
ARG USE_CUDA_VER
ARG USE_SLIM
ARG USE_PERMISSION_HARDENING
ARG USE_EMBEDDING_MODEL
ARG USE_RERANKING_MODEL
ARG USE_AUXILIARY_EMBEDDING_MODEL
ARG UID
ARG GID
ARG BUILD_HASH

# Install Python 3.11 and required system packages
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

# Install additional packages for multimedia support
RUN microdnf install -y \
        # Development tools needed for some Python packages
        gcc \
        gcc-c++ \
        && \
    # Install ffmpeg from EPEL (if needed)
    curl -L -o /tmp/ffmpeg.tar.xz https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz && \
    tar -xf /tmp/ffmpeg.tar.xz -C /tmp && \
    cp /tmp/ffmpeg-*/ffmpeg /usr/local/bin/ && \
    cp /tmp/ffmpeg-*/ffprobe /usr/local/bin/ && \
    rm -rf /tmp/ffmpeg* && \
    microdnf remove -y gcc gcc-c++ && \
    microdnf clean all

# Python settings
ENV PYTHONUNBUFFERED=1

## Application Config ##
ENV ENV=prod \
    PORT=8080 \
    USE_OLLAMA_DOCKER=${USE_OLLAMA} \
    USE_CUDA_DOCKER=${USE_CUDA} \
    USE_SLIM_DOCKER=${USE_SLIM} \
    USE_CUDA_DOCKER_VER=${USE_CUDA_VER} \
    USE_EMBEDDING_MODEL_DOCKER=${USE_EMBEDDING_MODEL} \
    USE_RERANKING_MODEL_DOCKER=${USE_RERANKING_MODEL} \
    USE_AUXILIARY_EMBEDDING_MODEL_DOCKER=${USE_AUXILIARY_EMBEDDING_MODEL}

## URL Config ##
ENV OLLAMA_BASE_URL="/ollama" \
    OPENAI_API_BASE_URL=""

## Security Config ##
ENV OPENAI_API_KEY="" \
    WEBUI_SECRET_KEY="" \
    SCARF_NO_ANALYTICS=true \
    DO_NOT_TRACK=true \
    ANONYMIZED_TELEMETRY=false

## Model Settings ##
ENV WHISPER_MODEL="base" \
    WHISPER_MODEL_DIR="/app/backend/data/cache/whisper/models" \
    RAG_EMBEDDING_MODEL="$USE_EMBEDDING_MODEL_DOCKER" \
    RAG_RERANKING_MODEL="$USE_RERANKING_MODEL_DOCKER" \
    AUXILIARY_EMBEDDING_MODEL="$USE_AUXILIARY_EMBEDDING_MODEL_DOCKER" \
    SENTENCE_TRANSFORMERS_HOME="/app/backend/data/cache/embedding/models" \
    TIKTOKEN_ENCODING_NAME="cl100k_base" \
    TIKTOKEN_CACHE_DIR="/app/backend/data/cache/tiktoken" \
    HF_HOME="/app/backend/data/cache/embedding/models"

WORKDIR /app/backend

# Create user and setup directories
RUN if [ $UID -ne 0 ]; then \
        useradd -u $UID -g $GID -r -m -d /home/app app; \
        HOME=/home/app; \
    else \
        HOME=/root; \
    fi && \
    mkdir -p $HOME/.cache/chroma /app/backend/data && \
    echo -n 00000000-0000-0000-0000-000000000000 > $HOME/.cache/chroma/telemetry_user_id && \
    chown -R $UID:$GID /app $HOME

# Copy Python dependencies from builder
COPY --from=python-builder --chown=$UID:$GID /opt/app-root/src/.local /home/app/.local

# Copy frontend build
COPY --from=frontend-build --chown=$UID:$GID /app/build /app/build
COPY --from=frontend-build --chown=$UID:$GID /app/CHANGELOG.md /app/CHANGELOG.md
COPY --from=frontend-build --chown=$UID:$GID /app/package.json /app/package.json

# Copy backend files
COPY --chown=$UID:$GID ./backend .

# Install Ollama if requested
RUN if [ "$USE_OLLAMA" = "true" ]; then \
        date +%s > /tmp/ollama_build_hash && \
        echo "Cache broken at timestamp: `cat /tmp/ollama_build_hash`" && \
        curl -fsSL https://ollama.com/install.sh | sh; \
    fi

# Download models if not slim build
RUN if [ "$USE_SLIM" != "true" ]; then \
        export PATH="/home/app/.local/bin:$PATH" && \
        python3.11 -c "import os; from sentence_transformers import SentenceTransformer; SentenceTransformer(os.environ['RAG_EMBEDDING_MODEL'], device='cpu')" && \
        python3.11 -c "import os; from sentence_transformers import SentenceTransformer; SentenceTransformer(os.environ.get('AUXILIARY_EMBEDDING_MODEL', 'TaylorAI/bge-micro-v2'), device='cpu')" && \
        python3.11 -c "import os; from faster_whisper import WhisperModel; WhisperModel(os.environ['WHISPER_MODEL'], device='cpu', compute_type='int8', download_root=os.environ['WHISPER_MODEL_DIR'])" && \
        python3.11 -c "import os; import tiktoken; tiktoken.get_encoding(os.environ['TIKTOKEN_ENCODING_NAME'])"; \
    fi

# Permission hardening for OpenShift
RUN if [ "$USE_PERMISSION_HARDENING" = "true" ]; then \
        set -eux; \
        chgrp -R 0 /app /home/app || true; \
        chmod -R g+rwX /app /home/app || true; \
        find /app -type d -exec chmod g+s {} + || true; \
        find /home/app -type d -exec chmod g+s {} + || true; \
    fi

EXPOSE 8080

# Health check
HEALTHCHECK CMD curl --silent --fail http://localhost:${PORT:-8080}/health | jq -ne 'input.status == true' || exit 1

# Environment variables
ENV PATH="/home/app/.local/bin:$PATH"
ENV WEBUI_BUILD_VERSION=${BUILD_HASH}
ENV DOCKER=true

USER $UID:$GID

CMD [ "bash", "start.sh"]
