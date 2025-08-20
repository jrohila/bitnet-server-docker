#!/usr/bin/env bash
set -euo pipefail

# Tunables (user can override at docker run)
: "${MODEL_PATH:=/models/ggml-model-i2_s.gguf}"
: "${HOST:=0.0.0.0}"
: "${PORT:=8080}"
: "${THREADS:=}"           # may be "", "auto", or a number
: "${CTX_SIZE:=2048}"
: "${N_PREDICT:=4096}"
: "${TEMPERATURE:=0.8}"
: "${SYSTEM_PROMPT:=}"
: "${LLAMA_ARGS:=}"

# If image was built with OPTIMIZE=true, choose fast defaults automatically
if [ "${OPTIMIZE_DEFAULT:-false}" = "true" ]; then
  # 1) Default extra flags if user didn’t override (pairs with your wrapper)
  if [ -z "${LLAMA_ARGS}" ]; then
    LLAMA_ARGS="--no-mmap --mlock"
  fi

  # 2) Auto-detect threads only if user didn’t set THREADS
  if [ -z "${THREADS}" ]; then
    # Try physical core count first
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

  # 3) Avoid oversubscription (OpenBLAS + OpenMP)
  : "${OPENBLAS_NUM_THREADS:=1}"
  : "${OMP_PLACES:=cores}"
  : "${OMP_PROC_BIND:=close}"
fi

# --- Robust thread selection even when OPTIMIZE_DEFAULT is false ---
THREADS_RAW="${THREADS:-}"
if [ -z "${THREADS_RAW}" ] || [ "${THREADS_RAW}" = "auto" ]; then
  if command -v nproc >/dev/null 2>&1; then
    THREADS_EFF="$(nproc)"
  else
    THREADS_EFF="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)"
  fi
else
  THREADS_EFF="${THREADS_RAW}"
fi
# Validate/clamp
if ! [[ "${THREADS_EFF}" =~ ^[0-9]+$ ]] || [ "${THREADS_EFF}" -lt 1 ]; then
  THREADS_EFF=1
fi

export THREADS="${THREADS_EFF}"
export LLAMA_ARGS OPENBLAS_NUM_THREADS OMP_PLACES OMP_PROC_BIND

echo "[entrypoint] BitNet at /opt/BitNet"
echo "[entrypoint] Model at ${MODEL_PATH}"
echo "[entrypoint] Starting server on ${HOST}:${PORT} (threads=${THREADS})"
echo "[entrypoint] OPTIMIZE_DEFAULT=${OPTIMIZE_DEFAULT:-false} LLAMA_ARGS='${LLAMA_ARGS}'"

cd /opt/BitNet

# Ensure llama build symlink exists
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

# Pass-through extra server flags (the wrapper will inject LLAMA_ARGS before "$@")
exec python /opt/BitNet/run_inference_server.py "${args[@]}"

