# syntax=docker/dockerfile:1.7

#############################
# Build stage
#############################
FROM ubuntu:24.04 AS build
ARG DEBIAN_FRONTEND=noninteractive
ARG OPTIMIZE=true

RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl ca-certificates \
    python3 python3-venv python3-pip \
    build-essential cmake pkg-config \
    libopenblas-dev \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /opt

# BitNet sources (with llama.cpp submodule)
RUN git clone --recursive "https://github.com/jrohila/BitNet.git" BitNet \
 && git -C BitNet fetch --all --tags \
 && git -C BitNet checkout "v1.0.0-docker" \
 && git -C BitNet submodule update --init --recursive

# Optional Python env + helper setup (non-fatal if these fail)
RUN if [ "${OPTIMIZE}" = "true" ]; then \
      python3 -m venv /opt/bitnet-venv && \
      . /opt/bitnet-venv/bin/activate && \
      pip install --upgrade pip setuptools wheel && \
      pip install -r /opt/BitNet/requirements.txt || true && \
      (python /opt/BitNet/setup_env.py -q i2_s -p || true); \
    fi

# Export kernel header (if present)
RUN set -eux; \
    mkdir -p /opt/BitNet/include; \
    hdr="$(find /opt/BitNet -type f -name 'bitnet-lut-kernels*.h' | head -n1 || true)"; \
    [ -n "$hdr" ] && cp -f "$hdr" /opt/BitNet/include/bitnet-lut-kernels.h || true; \
    mkdir -p /opt/out/include; \
    [ -f /opt/BitNet/include/bitnet-lut-kernels.h ] && cp -f /opt/BitNet/include/bitnet-lut-kernels.h /opt/out/include/ || true

# Fetch a small-ish default model
RUN mkdir -p /opt/out/models \
 && curl -L --fail --retry 3 --retry-delay 2 \
      "https://huggingface.co/microsoft/bitnet-b1.58-2B-4T-gguf/resolve/main/ggml-model-i2_s.gguf" \
      -o /opt/out/models/ggml-model-i2_s.gguf

# ---- PGO build using llama-cli (NOT the server) ----
WORKDIR /opt/BitNet/3rdparty/llama.cpp
RUN set -eux; \
  COMMON_CFLAGS="-O3 -march=native -mtune=native -pipe -fno-plt -DNDEBUG"; \
  COMMON_LDFLAGS_GEN="-Wl,-O3"; \
  COMMON_LDFLAGS_USE="-Wl,-O3 -s"; \
  PROFILE_DIR="$(pwd)/build-pgo-gen/pgo-profile"; \
  if [ "${OPTIMIZE}" = "true" ]; then \
    NATIVE="-DGGML_NATIVE=ON"; BLAS="-DGGML_BLAS=ON -DGGML_BLAS_VENDOR=OpenBLAS"; OMP="-DGGML_OPENMP=ON"; \
    GEN_FLAGS="-fprofile-generate -fprofile-dir=${PROFILE_DIR}"; \
    cmake -S . -B build-pgo-gen -DCMAKE_BUILD_TYPE=Release $NATIVE $BLAS $OMP \
      -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=ON -DLLAMA_BUILD_SERVER=ON \
      -DCMAKE_C_FLAGS_RELEASE="${COMMON_CFLAGS} ${GEN_FLAGS}" \
      -DCMAKE_CXX_FLAGS_RELEASE="${COMMON_CFLAGS} ${GEN_FLAGS}" \
      -DCMAKE_EXE_LINKER_FLAGS="${COMMON_LDFLAGS_GEN}"; \
    cmake --build build-pgo-gen --target llama-cli -j"$(nproc)"; \
    echo '[PGO] Exercising llama-cli to generate .gcda profiles' >&2; \
    mkdir -p "${PROFILE_DIR}"; \
    for i in 1 2 3; do \
      ./build-pgo-gen/bin/llama-cli -m /opt/out/models/ggml-model-i2_s.gguf -p "hello $i" -n 64 >/dev/null 2>&1 || true; \
    done; \
    PGO_COUNT="$(find "${PROFILE_DIR}" -type f -name '*.gcda' | wc -l || true)"; \
    if [ "${PGO_COUNT:-0}" -gt 0 ]; then \
      echo "[PGO] SUCCESS: found ${PGO_COUNT} .gcda files" >&2; \
      USE_FLAGS="-flto -fuse-linker-plugin -fprofile-use -fprofile-correction -Wno-missing-profile -fprofile-dir=${PROFILE_DIR}"; \
      CFLAGS_USE="${COMMON_CFLAGS} ${USE_FLAGS}"; \
      CXXFLAGS_USE="${COMMON_CFLAGS} ${USE_FLAGS}"; \
    else \
      echo "[PGO] WARNING: no profile data generated; building WITHOUT -fprofile-use (keeping -O3 -march=native -flto)" >&2; \
      CFLAGS_USE="${COMMON_CFLAGS} -flto -fuse-linker-plugin"; \
      CXXFLAGS_USE="${COMMON_CFLAGS} -flto -fuse-linker-plugin"; \
    fi; \
    echo '[PGO] Pass 2: final build (llama-server)' >&2; \
    cmake -S . -B build -DCMAKE_BUILD_TYPE=Release $NATIVE $BLAS $OMP \
      -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=ON -DLLAMA_BUILD_SERVER=ON \
      -DCMAKE_C_FLAGS_RELEASE="${CFLAGS_USE}" \
      -DCMAKE_CXX_FLAGS_RELEASE="${CXXFLAGS_USE}" \
      -DCMAKE_EXE_LINKER_FLAGS="${COMMON_LDFLAGS_USE}"; \
    cmake --build build --target llama-server -j"$(nproc)"; \
  else \
    echo '[PGO] Disabled: OPTIMIZE=false → building without PGO' >&2; \
    NATIVE="-DGGML_NATIVE=OFF"; BLAS="-DGGML_BLAS=OFF"; OMP="-DGGML_OPENMP=ON"; \
    cmake -S . -B build -DCMAKE_BUILD_TYPE=Release $NATIVE $BLAS $OMP \
      -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_SERVER=ON \
      -DCMAKE_C_FLAGS_RELEASE="${COMMON_CFLAGS}" \
      -DCMAKE_CXX_FLAGS_RELEASE="${COMMON_CFLAGS}" \
      -DCMAKE_EXE_LINKER_FLAGS="${COMMON_LDFLAGS_USE}"; \
    cmake --build build --target llama-server -j"$(nproc)"; \
  fi

# --- Collect artifacts (FIX: no self-copy of /opt/out/models) ---
RUN mkdir -p /opt/out \
 && cp -a /opt/BitNet /opt/out/BitNet \
 && cp -a /opt/BitNet/3rdparty/llama.cpp/build /opt/out/llama-build

#############################
# Runtime stage
#############################
FROM ubuntu:24.04 AS runtime
ARG OPTIMIZE=true
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates python3-minimal \
    libstdc++6 libgcc-s1 libgomp1 libopenblas0 libjemalloc2 \
 && rm -rf /var/lib/apt/lists/*

RUN ln -s /usr/bin/python3 /usr/bin/python

# Bring artifacts
COPY --from=build /opt/out /opt/out

# Place artifacts in final layout
RUN set -eux; \
    mv /opt/out/BitNet /opt/BitNet; \
    mv /opt/out/llama-build /opt/BitNet/3rdparty/llama.cpp/build; \
    mkdir -p /models; \
    cp -a /opt/out/models/* /models/

# Ensure llama shared libs are found at runtime (no undefined-var usage)
ENV LD_LIBRARY_PATH=/opt/BitNet/3rdparty/llama.cpp/build

# Defaults exposed to container users
ENV OPTIMIZE_DEFAULT=${OPTIMIZE} \
    MODEL_PATH=/models/ggml-model-i2_s.gguf \
    HOST=0.0.0.0 \
    PORT=8080 \
    CTX_SIZE=2048 \
    N_PREDICT=4096 \
    TEMPERATURE=0.8 \
    LLAMA_ARGS=

# ---------------- entrypoint ----------------
COPY <<'EOF' /usr/local/bin/entrypoint.sh
#!/usr/bin/env bash
set -euo pipefail

: "${MODEL_PATH:=/models/ggml-model-i2_s.gguf}"
: "${HOST:=0.0.0.0}"
: "${PORT:=8080}"
: "${THREADS:=}"
: "${CTX_SIZE:=2048}"
: "${N_PREDICT:=4096}"
: "${TEMPERATURE:=0.8}"
: "${SYSTEM_PROMPT:=}"
: "${LLAMA_ARGS:=}"

# Always set THREADS if not provided (fixes empty -t)
if [ -z "${THREADS}" ]; then
  if command -v lscpu >/dev/null 2>&1; then
    phys="$(lscpu -p=Core,Socket 2>/dev/null | grep -v '^#' | awk -F, '{print $1"-"$2}' | sort -u | wc -l || echo 0)"
  else
    phys=0
  fi
  if [ "${phys}" -gt 0 ]; then
    THREADS="${phys}"
  else
    THREADS="$(nproc)"
  fi
fi

# Optional perf knobs if image built with OPTIMIZE=true
if [ "${OPTIMIZE_DEFAULT:-false}" = "true" ]; then
  if [ -z "${LLAMA_ARGS}" ]; then
    LLAMA_ARGS="--no-mmap --mlock"
  fi
  : "${OPENBLAS_NUM_THREADS:=1}"
  : "${OMP_PLACES:=cores}"
  : "${OMP_PROC_BIND:=close}"
fi

export THREADS LLAMA_ARGS OPENBLAS_NUM_THREADS OMP_PLACES OMP_PROC_BIND

echo "[entrypoint] BitNet at /opt/BitNet"
echo "[entrypoint] Model at ${MODEL_PATH}"
echo "[entrypoint] Starting server on ${HOST}:${PORT} (threads=${THREADS})"
echo "[entrypoint] OPTIMIZE_DEFAULT=${OPTIMIZE_DEFAULT:-false} LLAMA_ARGS='${LLAMA_ARGS}'"

cd /opt/BitNet

# Ensure llama build symlink exists (for scripts expecting /opt/BitNet/build)
if [ ! -e /opt/BitNet/build ] && [ -d /opt/BitNet/3rdparty/llama.cpp/build ]; then
  ln -s /opt/BitNet/3rdparty/llama.cpp/build /opt/BitNet/build || true
fi

args=(
  -m "${MODEL_PATH}"
  --host "${HOST}"
  --port "${PORT}"
  -t "${THREADS}"
  -c "${CTX_SIZE}"
  -n "${N_PREDICT}"
  --temperature "${TEMPERATURE}"
)

if [ -n "${SYSTEM_PROMPT}" ]; then
  args+=( -p "${SYSTEM_PROMPT}" )
fi

exec python /opt/BitNet/run_inference_server.py "${args[@]}"
EOF
RUN sed -i 's/\r$//' /usr/local/bin/entrypoint.sh \
 && chmod +x /usr/local/bin/entrypoint.sh

WORKDIR /opt/BitNet
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
