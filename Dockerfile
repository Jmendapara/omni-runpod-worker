ARG BASE_IMAGE=nvidia/cuda:12.6.3-cudnn-runtime-ubuntu24.04

# Stage 1: Base image with common dependencies
FROM ${BASE_IMAGE} AS base

ARG COMFYUI_VERSION=latest
ARG CUDA_VERSION_FOR_COMFY
ARG ENABLE_PYTORCH_UPGRADE=false
ARG PYTORCH_INDEX_URL

ENV DEBIAN_FRONTEND=noninteractive
ENV PIP_PREFER_BINARY=1
ENV PYTHONUNBUFFERED=1
ENV CMAKE_BUILD_PARALLEL_LEVEL=8

RUN apt-get update && apt-get install -y \
    python3.12 \
    python3.12-venv \
    python3.12-dev \
    git \
    wget \
    curl \
    libgl1 \
    libglib2.0-0 \
    libsm6 \
    libxext6 \
    libxrender1 \
    ffmpeg \
    libsndfile1 \
    && ln -sf /usr/bin/python3.12 /usr/bin/python \
    && ln -sf /usr/bin/pip3 /usr/bin/pip

RUN apt-get autoremove -y && apt-get clean -y && rm -rf /var/lib/apt/lists/*

RUN wget -qO- https://astral.sh/uv/install.sh | sh \
    && ln -s /root/.local/bin/uv /usr/local/bin/uv \
    && ln -s /root/.local/bin/uvx /usr/local/bin/uvx \
    && uv venv /opt/venv

ENV PATH="/opt/venv/bin:${PATH}"

RUN uv pip install comfy-cli pip setuptools wheel

RUN if [ -n "${CUDA_VERSION_FOR_COMFY}" ]; then \
      /usr/bin/yes | comfy --workspace /comfyui install --version "${COMFYUI_VERSION}" --cuda-version "${CUDA_VERSION_FOR_COMFY}" --nvidia; \
    else \
      /usr/bin/yes | comfy --workspace /comfyui install --version "${COMFYUI_VERSION}" --nvidia; \
    fi

RUN if [ "$ENABLE_PYTORCH_UPGRADE" = "true" ]; then \
      uv pip install --force-reinstall torch torchvision torchaudio --index-url ${PYTORCH_INDEX_URL}; \
    fi

WORKDIR /comfyui

ADD src/extra_model_paths.yaml ./

WORKDIR /

RUN uv pip install runpod requests websocket-client

ADD src/start.sh src/network_volume.py handler.py test_input.json ./
RUN chmod +x /start.sh

COPY scripts/comfy-node-install.sh /usr/local/bin/comfy-node-install
RUN chmod +x /usr/local/bin/comfy-node-install

ENV PIP_NO_INPUT=1

# Install ComfyUI-OmniVoice-TTS custom node
WORKDIR /comfyui
RUN comfy-node-install https://github.com/Saganaki22/ComfyUI-OmniVoice-TTS

# Install OmniVoice dependencies carefully to avoid breaking PyTorch
RUN uv pip install omnivoice --no-deps && \
    uv pip install \
    pydub \
    soundfile \
    scipy \
    lazy_loader \
    librosa \
    sentencepiece \
    jieba \
    soxr \
    "transformers>=5.3.0" && \
    rm -rf /root/.cache/pip /root/.cache/uv /tmp/* && \
    uv cache clean

WORKDIR /

COPY scripts/comfy-manager-set-mode.sh /usr/local/bin/comfy-manager-set-mode
RUN chmod +x /usr/local/bin/comfy-manager-set-mode

CMD ["/start.sh"]

# Stage 2: Download models
FROM base AS downloader

ARG HUGGINGFACE_ACCESS_TOKEN
ARG MODEL_TYPE=omnivoice-bf16

WORKDIR /comfyui

RUN mkdir -p models/omnivoice models/audio_encoders

RUN uv pip install "huggingface_hub[hf_xet]"

RUN if [ "$MODEL_TYPE" = "omnivoice-bf16" ]; then \
      python3 -c "from huggingface_hub import snapshot_download; snapshot_download('drbaph/OmniVoice-bf16', local_dir='/comfyui/models/omnivoice/OmniVoice-bf16')" && \
      rm -rf /root/.cache/huggingface /tmp/hf_xet* /tmp/tmp*; \
    fi

RUN if [ "$MODEL_TYPE" = "omnivoice-fp32" ]; then \
      python3 -c "from huggingface_hub import snapshot_download; snapshot_download('k2-fsa/OmniVoice', local_dir='/comfyui/models/omnivoice/OmniVoice')" && \
      rm -rf /root/.cache/huggingface /tmp/hf_xet* /tmp/tmp*; \
    fi

RUN python3 -c "from huggingface_hub import snapshot_download; snapshot_download('openai/whisper-large-v3-turbo', local_dir='/comfyui/models/audio_encoders/openai_whisper-large-v3-turbo')" && \
    rm -rf /root/.cache/huggingface /tmp/hf_xet* /tmp/tmp* && \
    uv cache clean

# Stage 3: Final image
FROM base AS final

COPY --from=downloader /comfyui/models /comfyui/models
