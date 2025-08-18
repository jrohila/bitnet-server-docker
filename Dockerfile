# syntax=docker/dockerfile:1.7

FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive
# true = fastest (native ISA, LTO, OpenMP, OpenBLAS)
ARG OPTIMIZE=true
ARG USE_PGO=off              # off | gen | use
ARG BITNET_REF=              # optional: git ref/commit/tag to checkout
ARG PREPARE_PRESETS=true     # prepare bitnet LUT/presets via venv
ARG MODEL_URL="https://huggingface.co/microsoft/bitnet-b1.58-2B-4T-gguf/resolve/main/ggml-model-i2_s.gguf"
ARG MODEL_SHA256=            # optional: sha256 of the model for verification

# --- Base deps ---
RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl ca-certificates \
    python3 python3-venv python3-pip \
    build-essential cmake pkg-config \
    libopenblas-dev \
 && rm -rf /var/lib/apt/lists/* \
 && ln -sf /usr/bin/python3 /usr/bin/python

WORKDIR /opt

# --- Clone microsoft/BitNet (with submodules) ---
RUN git clone --recursive https://github.com/microsoft/BitNet.git \
 && if [ -n "$BITNET_REF" ]; then \
      git -C BitNet fetch --all && \
      git -C BitNet checkout "$BITNET_REF"; \
    fi \
 && git -C BitNet submodule update --init --recursive

# --- (Optional) Prepare BitNet presets/headers (venv) ---
RUN if [ "$PREPARE_PRESETS" = "true" ]; then \
      python3 -m venv /opt/bitnet-venv && \
      . /opt/bitnet-venv/bin/activate && \
      pip install --upgrade pip setuptools wheel && \
      pip install -r /opt/BitNet/requirements.txt || true && \
      (python /opt/BitNet/setup_env.py -q i2_s -p || true); \
    fi

# --- Expose headers to bundled llama.cpp (/include) ---
RUN set -eux; \
  mkdir -p /opt/BitNet/include; \
  hdr="$(find /opt/BitNet -type f -name 'bitnet-lut-kernels*.h' | head -n1 || true)"; \
  cfg="$(find /opt/BitNet -type f -name 'kernel_config.ini' | head -n1 || true)"; \
  if [ -n "$hdr" ]; then cp -f "$hdr" /opt/BitNet/include/bitnet-lut-kernels.h; fi; \
  if [ -n "$cfg" ]; then cp -f "$cfg" /opt/BitNet/include/kernel_config.ini; fi; \
  ln -sf /opt/BitNet/include /include || true; \
  ln -sf /opt/BitNet/src     /src     || true

# --- Build bundled llama.cpp (aggressive when OPTIMIZE=true) ---
WORKDIR /opt/BitNet/3rdparty/llama.cpp
RUN set -eux; \
  COMMON_CFLAGS="-O3 -pipe -fno-plt"; \
  COMMON_LDFLAGS="-Wl,-O3 -s"; \
  if [ "$OPTIMIZE" = "true" ]; then \
    NATIVE="-DGGML_NATIVE=ON"; \
    BLAS="-DGGML_BLAS=ON -DGGML_BLAS_VENDOR=OpenBLAS"; \
    OMP="-DGGML_OPENMP=ON"; \
    CFLAGS="$COMMON_CFLAGS -flto -fuse-linker-plugin"; \
    CXXFLAGS="$COMMON_CFLAGS -flto -fuse-linker-plugin"; \
  else \
    NATIVE="-DGGML_NATIVE=OFF"; \
    BLAS="-DGGML_BLAS=OFF"; \
    OMP="-DGGML_OPENMP=ON"; \
    CFLAGS="$COMMON_CFLAGS"; \
    CXXFLAGS="$COMMON_CFLAGS"; \
  fi; \
  if [ "$USE_PGO" = "gen" ]; then \
    CFLAGS="$CFLAGS -fprofile-generate"; \
    CXXFLAGS="$CXXFLAGS -fprofile-generate"; \
  elif [ "$USE_PGO" = "use" ]; then \
    CFLAGS="$CFLAGS -fprofile-use -fprofile-correction"; \
    CXXFLAGS="$CXXFLAGS -fprofile-use -fprofile-correction"; \
  fi; \
  cmake -S . -B build \
    -DCMAKE_BUILD_TYPE=Release \
    $NATIVE $BLAS $OMP \
    -DCMAKE_C_FLAGS_RELEASE="$CFLAGS" \
    -DCMAKE_CXX_FLAGS_RELEASE="$CXXFLAGS" \
    -DCMAKE_EXE_LINKER_FLAGS="$COMMON_LDFLAGS" ; \
  cmake --build build -j"$(nproc)"

# Link where run_inference_server expects it
RUN ln -sf /opt/BitNet/3rdparty/llama.cpp/build /opt/BitNet/build || true

# --- Wrap llama-server to allow default + extra flags ---
# Default LLAMA_ARGS baked at build-time when OPTIMIZE=true, but still overridable at runtime.
ENV LLAMA_ARGS=
RUN set -eux; \
  srv="/opt/BitNet/3rdparty/llama.cpp/build/bin/llama-server"; \
  if [ -f "$srv" ]; then \
    mv "$srv" "${srv}.real"; \
    if [ "$OPTIMIZE" = "true" ]; then DEFAULT_ARGS="--no-mmap --mlock"; else DEFAULT_ARGS=""; fi; \
    { \
      echo '#!/usr/bin/env bash'; \
      echo 'set -e'; \
      echo "exec \"\$(dirname \"\$0\")/llama-server.real\" ${DEFAULT_ARGS} \${LLAMA_ARGS:-} \"\$@\""; \
    } > "$srv"; \
    chmod +x "$srv"; \
  fi

# --- Bake model into image ---
RUN set -eux; \
  mkdir -p /models; \
  if [ -n "$MODEL_URL" ]; then \
    curl -L --fail --retry 3 --retry-delay 2 "$MODEL_URL" -o /tmp/model.gguf; \
    if [ -n "$MODEL_SHA256" ]; then \
      echo "${MODEL_SHA256}  /tmp/model.gguf" | sha256sum -c -; \
    fi; \
    mv /tmp/model.gguf /models/ggml-model-i2_s.gguf; \
  fi

# --- Environment defaults ---
ENV MODEL_PATH=/models/ggml-model-i2_s.gguf \
    HOST=0.0.0.0 \
    PORT=8080 \
    THREADS=2 \
    CTX_SIZE=2048 \
    N_PREDICT=4096 \
    TEMPERATURE=0.8 \
    OMP_PROC_BIND=close \
    OMP_PLACES=cores

# --- Non-root user & workspace ---
RUN useradd -m -u 10001 bitnet && mkdir -p /workspace && chown -R bitnet:bitnet /workspace /models /opt/BitNet

# --- Use your entrypoint.sh (normalize CRLF -> LF) ---
USER root
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN sed -i 's/\r$//' /usr/local/bin/entrypoint.sh && chmod +x /usr/local/bin/entrypoint.sh

USER bitnet
WORKDIR /workspace

EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
