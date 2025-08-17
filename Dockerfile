# syntax=docker/dockerfile:1.7

FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    git python3 python3-venv python3-pip \
    curl ca-certificates \
    build-essential cmake \
 && rm -rf /var/lib/apt/lists/* \
 && ln -s /usr/bin/python3 /usr/bin/python || true

WORKDIR /opt

# --- Clone microsoft/BitNet (with submodules) ---
ARG BITNET_REF=
RUN git clone --recursive https://github.com/microsoft/BitNet.git \
 && if [ -n "$BITNET_REF" ]; then \
      git -C BitNet fetch --all && \
      git -C BitNet checkout "$BITNET_REF"; \
    fi \
 && git -C BitNet submodule update --init --recursive

# --- (Optional) Prepare BitNet presets/headers ---
ARG PREPARE_PRESETS=true
RUN if [ "$PREPARE_PRESETS" = "true" ]; then \
      python3 -m venv /opt/bitnet-venv && \
      . /opt/bitnet-venv/bin/activate && \
      pip install --upgrade pip setuptools wheel && \
      pip install -r /opt/BitNet/requirements.txt || true && \
      (python /opt/BitNet/setup_env.py -q i2_s -p || true); \
    fi

# --- Make LUT/header visible where bundled llama.cpp expects it (/include) ---
RUN set -eux; \
  mkdir -p /opt/BitNet/include; \
  hdr="$(find /opt/BitNet -type f -name 'bitnet-lut-kernels*.h' | head -n1 || true)"; \
  cfg="$(find /opt/BitNet -type f -name 'kernel_config.ini' | head -n1 || true)"; \
  if [ -n "$hdr" ]; then cp -f "$hdr" /opt/BitNet/include/bitnet-lut-kernels.h; fi; \
  if [ -n "$cfg" ]; then cp -f "$cfg" /opt/BitNet/include/kernel_config.ini; fi; \
  ln -sf /opt/BitNet/include /include || true; \
  ln -sf /opt/BitNet/src     /src     || true

# --- Build bundled llama.cpp so run_inference.py can call build/bin/llama-cli ---
WORKDIR /opt/BitNet/3rdparty/llama.cpp
RUN cmake -S . -B build -DCMAKE_BUILD_TYPE=Release \
 && cmake --build build -j "$(nproc)"

# Link to where run_inference.py expects it
RUN ln -s /opt/BitNet/3rdparty/llama.cpp/build /opt/BitNet/build || true

# --- Bake the model into the image (self-contained) ---
# If HF changes the location or requires auth, you can host the file elsewhere.
RUN mkdir -p /models
ADD https://huggingface.co/microsoft/bitnet-b1.58-2B-4T-gguf/resolve/main/ggml-model-i2_s.gguf /models/ggml-model-i2_s.gguf

# Environment (kept for scripts that reference it)
ENV MODEL_PATH=/models/ggml-model-i2_s.gguf

# Non-root user & workspace
RUN useradd -m -u 10001 bitnet && mkdir -p /workspace && chown -R bitnet:bitnet /workspace /models
USER bitnet
WORKDIR /workspace

# Minimal entrypoint: no downloading; just exec what you pass (default: bash)
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
USER root
RUN sed -i 's/\r$//' /usr/local/bin/entrypoint.sh && chmod +x /usr/local/bin/entrypoint.sh
USER bitnet

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["bash"]
