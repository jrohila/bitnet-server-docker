# syntax=docker/dockerfile:1.7

# Minimal dev base with tools you might want later (git, python, build tools)
FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    git python3 python3-venv python3-pip \
    curl ca-certificates \
    build-essential cmake \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /opt

# --- Clone microsoft/BitNet ---
# You can pin later via: --build-arg BITNET_REF=<commit-or-tag>
ARG BITNET_REF=
RUN git clone --recursive https://github.com/microsoft/BitNet.git \
 && if [ -n "$BITNET_REF" ]; then git -C BitNet checkout "$BITNET_REF"; fi \
 && git -C BitNet submodule update --init --recursive

# --- (Optional) Prepare BitNet presets/headers ---
# Toggle with: --build-arg PREPARE_PRESETS=true|false   (default: true)
ARG PREPARE_PRESETS=true
RUN if [ "$PREPARE_PRESETS" = "true" ]; then \
      python3 -m venv /opt/bitnet-venv && \
      . /opt/bitnet-venv/bin/activate && \
      pip install --upgrade pip setuptools wheel && \
      # If requirements.txt references submodule files, recursive clone above ensures they exist
      pip install -r /opt/BitNet/requirements.txt || true && \
      # Try to generate/copy pretuned kernel LUTs if script/args are present in this BitNet revision
      (python /opt/BitNet/setup_env.py -q i2_s -p || true); \
    fi

# Environment for model convenience (used by entrypoint.sh)
ENV MODEL_PATH=/models/ggml-model-i2_s.gguf \
    MODEL_URL=https://huggingface.co/microsoft/bitnet-b1.58-2B-4T-gguf/resolve/main/ggml-model-i2_s.gguf

# Non-root user
RUN useradd -m -u 10001 bitnet && mkdir -p /workspace /models && chown -R bitnet:bitnet /workspace /models
USER bitnet
WORKDIR /workspace

# Entrypoint: ensure model present, then exec passed command (default: bash)
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
# Normalize CRLF to LF in case the file is edited on Windows
USER root
RUN sed -i 's/\r$//' /usr/local/bin/entrypoint.sh && chmod +x /usr/local/bin/entrypoint.sh
USER bitnet

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["bash"]
