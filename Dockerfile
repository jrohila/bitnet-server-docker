# syntax=docker/dockerfile:1.7

############################################
# 1) BUILDER: compile llama-server + fetch model
############################################
FROM ubuntu:24.04 AS build
ARG DEBIAN_FRONTEND=noninteractive
ARG OPTIMIZE=true
ARG USE_PGO=off
ARG BITNET_REPO=https://github.com/jrohila/BitNet.git
ARG BITNET_REF=v1.0.0-docker
ARG PREPARE_PRESETS=true
ARG MODEL_URL="https://huggingface.co/microsoft/bitnet-b1.58-2B-4T-gguf/resolve/main/ggml-model-i2_s.gguf"
ARG MODEL_SHA256=

RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl ca-certificates \
    python3 python3-venv python3-pip \
    build-essential cmake pkg-config \
    libopenblas-dev \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /opt

# Clone BitNet
RUN git clone --recursive "$BITNET_REPO" BitNet \
 && git -C BitNet fetch --all --tags \
 && git -C BitNet checkout "$BITNET_REF" \
 && git -C BitNet submodule update --init --recursive

# (Optional) generate BitNet LUT/presets
RUN if [ "$PREPARE_PRESETS" = "true" ]; then \
      python3 -m venv /opt/bitnet-venv && \
      . /opt/bitnet-venv/bin/activate && \
      pip install --upgrade pip setuptools wheel && \
      pip install -r /opt/BitNet/requirements.txt || true && \
      (python /opt/BitNet/setup_env.py -q i2_s -p || true); \
    fi

# Put generated headers where ggml expects them
RUN set -eux; \
  mkdir -p /opt/BitNet/include; \
  hdr="$(find /opt/BitNet -type f -name 'bitnet-lut-kernels*.h' | head -n1 || true)"; \
  cfg="$(find /opt/BitNet -type f -name 'kernel_config.ini' | head -n1 || true)"; \
  if [ -n "$hdr" ]; then cp -f "$hdr" /opt/BitNet/include/bitnet-lut-kernels.h; fi; \
  if [ -n "$cfg" ]; then cp -f "$cfg" /opt/BitNet/include/kernel_config.ini; fi; \
  mkdir -p /opt/out/include; \
  [ -f /opt/BitNet/include/bitnet-lut-kernels.h ] && cp -f /opt/BitNet/include/bitnet-lut-kernels.h /opt/out/include/ || true; \
  [ -f /opt/BitNet/include/kernel_config.ini ] && cp -f /opt/BitNet/include/kernel_config.ini /opt/out/include/ || true

# === minimal patch starts: build llama.cpp with PGO, -DNDEBUG, fixed bench flags, fewer targets ===
WORKDIR /opt/BitNet/3rdparty/llama.cpp
RUN set -eux; \
  COMMON_CFLAGS="-O3 -march=native -mtune=native -pipe -fno-plt -DNDEBUG"; \
  COMMON_LDFLAGS="-Wl,-O3 -s"; \
  if [ "$OPTIMIZE" = "true" ]; then \
    NATIVE="-DGGML_NATIVE=ON"; BLAS="-DGGML_BLAS=ON -DGGML_BLAS_VENDOR=OpenBLAS"; OMP="-DGGML_OPENMP=ON"; \
    GEN_FLAGS="-flto -fuse-linker-plugin -fprofile-generate"; \
    USE_FLAGS="-flto -fuse-linker-plugin -fprofile-use -fprofile-correction -Wno-missing-profile"; \
    echo '[PGO] Pass 1: building with -fprofile-generate' >&2; \
    cmake -S . -B build-pgo-gen -DCMAKE_BUILD_TYPE=Release $NATIVE $BLAS $OMP \
      -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=ON -DLLAMA_BUILD_SERVER=ON \
      -DCMAKE_C_FLAGS_RELEASE="$COMMON_CFLAGS $GEN_FLAGS" \
      -DCMAKE_CXX_FLAGS_RELEASE="$COMMON_CFLAGS $GEN_FLAGS" \
      -DCMAKE_EXE_LINKER_FLAGS="$COMMON_LDFLAGS"; \
    cmake --build build-pgo-gen --target llama-cli llama-server -j"$(nproc)"; \
    echo '[PGO] Exercising instrumented binary to generate profiles' >&2; \
    (./build-pgo-gen/bin/llama-bench -m /opt/out/models/ggml-model-i2_s.gguf -pg 512,128 -b 2048 -ub 512 -t 2 -r 1 || \
     ./build-pgo-gen/bin/llama-cli   -m /opt/out/models/ggml-model-i2_s.gguf -n 32 -p "hello" || true); \
    PGO_COUNT="$(find build-pgo-gen -type f -name '*.gcda' | wc -l || true)"; \
    if [ "${PGO_COUNT:-0}" -gt 0 ]; then \
      echo "[PGO] SUCCESS: found ${PGO_COUNT} .gcda files; building with -fprofile-use" >&2; \
      CFLAGS_USE="$COMMON_CFLAGS $USE_FLAGS"; \
      CXXFLAGS_USE="$COMMON_CFLAGS $USE_FLAGS"; \
    else \
      echo "[PGO] WARNING: no profile data generated; building WITHOUT -fprofile-use (keeping -O3 -march=native -flto)" >&2; \
      CFLAGS_USE="$COMMON_CFLAGS -flto -fuse-linker-plugin"; \
      CXXFLAGS_USE="$COMMON_CFLAGS -flto -fuse-linker-plugin"; \
    fi; \
    echo '[PGO] Pass 2: final build' >&2; \
    cmake -S . -B build -DCMAKE_BUILD_TYPE=Release $NATIVE $BLAS $OMP \
      -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=ON -DLLAMA_BUILD_SERVER=ON \
      -DCMAKE_C_FLAGS_RELEASE="$CFLAGS_USE" \
      -DCMAKE_CXX_FLAGS_RELEASE="$CXXFLAGS_USE" \
      -DCMAKE_EXE_LINKER_FLAGS="$COMMON_LDFLAGS"; \
    cmake --build build --target llama-server -j"$(nproc)"; \
  else \
    echo '[PGO] Disabled: OPTIMIZE=false → building without PGO' >&2; \
    NATIVE="-DGGML_NATIVE=OFF"; BLAS="-DGGML_BLAS=OFF"; OMP="-DGGML_OPENMP=ON"; \
    cmake -S . -B build -DCMAKE_BUILD_TYPE=Release $NATIVE $BLAS $OMP \
      -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_SERVER=ON \
      -DCMAKE_C_FLAGS_RELEASE="$COMMON_CFLAGS" \
      -DCMAKE_CXX_FLAGS_RELEASE="$COMMON_CFLAGS" \
      -DCMAKE_EXE_LINKER_FLAGS="$COMMON_LDFLAGS"; \
    cmake --build build --target llama-server -j"$(nproc)"; \
  fi
# === minimal patch ends ===

# Install server binary
RUN install -D -m0755 build/bin/llama-server /opt/out/bin/llama-server

# Collect shared libs needed at runtime (libllama.so, libggml*.so, etc.) and strip
RUN set -eux; \
  mkdir -p /opt/out/lib; \
  find build -type f -name '*.so' -exec cp -a {} /opt/out/lib/ \; || true; \
  strip --strip-unneeded /opt/out/lib/*.so || true

# Bake the model
RUN set -eux; mkdir -p /opt/out/models; \
  if [ -n "$MODEL_URL" ]; then \
    curl -L --fail --retry 3 --retry-delay 2 "$MODEL_URL" -o /opt/out/models/ggml-model-i2_s.gguf; \
    if [ -n "$MODEL_SHA256" ]; then \
      echo "${MODEL_SHA256}  /opt/out/models/ggml-model-i2_s.gguf" | sha256sum -c -; \
    fi; \
  fi

# Copy Python server
RUN install -D -m0644 /opt/BitNet/run_inference_server.py /opt/out/run_inference_server.py

# Normalize entrypoint here (still root) and export
COPY entrypoint.sh /opt/out/entrypoint.sh
RUN tr -d '\r' < /opt/out/entrypoint.sh > /opt/out/entrypoint.lf \
 && mv /opt/out/entrypoint.lf /opt/out/entrypoint.sh \
 && chmod 0755 /opt/out/entrypoint.sh


############################################
# 2) RUNTIME: minimal, CPU-quiet, production-safe
############################################
FROM ubuntu:24.04 AS runtime
ARG DEBIAN_FRONTEND=noninteractive

# Only runtime deps
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates python3-minimal \
    libstdc++6 libgcc-s1 libgomp1 libopenblas0 libjemalloc2 \
 && rm -rf /var/lib/apt/lists/*

# Provide "python" symlink for scripts (python3-minimal only installs python3)
RUN ln -s /usr/bin/python3 /usr/bin/python

# Copy artifacts from build (still root)
COPY --from=build /opt/out/bin/llama-server /usr/local/bin/llama-server
COPY --from=build /opt/out/lib/ /usr/local/lib/
COPY --from=build /opt/out/models/ggml-model-i2_s.gguf /models/ggml-model-i2_s.gguf
COPY --from=build /opt/out/include /include
COPY --from=build /opt/out/run_inference_server.py /opt/BitNet/run_inference_server.py
COPY --from=build /opt/out/entrypoint.sh /usr/local/bin/entrypoint.sh

# Compat symlink: script expects /opt/BitNet/build/bin/llama-server
RUN mkdir -p /opt/BitNet/build/bin \
 && ln -sf /usr/local/bin/llama-server /opt/BitNet/build/bin/llama-server

# Non-root + writable dirs for read-only rootfs usage
RUN useradd -m -u 10001 bitnet \
 && mkdir -p /workspace /tmp \
 && chown -R bitnet:bitnet /workspace /tmp /models

# Make sure the loader sees our copied libs without ldconfig
ENV LD_LIBRARY_PATH=/usr/local/lib:${LD_LIBRARY_PATH}

USER bitnet
WORKDIR /workspace

# ==== CPU-quiet defaults ====
ENV MODEL_PATH=/models/ggml-model-i2_s.gguf \
    HOST=0.0.0.0 \
    PORT=8080 \
    THREADS=2 \
    CTX_SIZE=2048 \
    N_PREDICT=4096 \
    TEMPERATURE=0.8 \
    LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libjemalloc.so.2 \
    MALLOC_ARENA_MAX=2 \
    JE_MALLOC_CONF=background_thread:true,dirty_decay_ms:5000,muzzy_decay_ms:5000 \
    OMP_WAIT_POLICY=passive \
    GOMP_SPINCOUNT=0 \
    OMP_DYNAMIC=false \
    OMP_PROC_BIND=close \
    OMP_PLACES=cores \
    OPENBLAS_NUM_THREADS=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONOPTIMIZE=2 \
    PYTHONNOUSERSITE=1 \
    PYTHONUNBUFFERED=1

EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
