#!/usr/bin/env bash
set -euo pipefail

# Tunables (override with -e VAR=value on docker run)
: "${MODEL_PATH:=/models/ggml-model-i2_s.gguf}"
: "${HOST:=0.0.0.0}"
: "${PORT:=8080}"
: "${THREADS:=2}"
: "${CTX_SIZE:=2048}"
: "${N_PREDICT:=4096}"
: "${TEMPERATURE:=0.8}"
: "${SYSTEM_PROMPT:=}"    # optional

echo "[entrypoint] BitNet at /opt/BitNet"
echo "[entrypoint] Model at ${MODEL_PATH}"
echo "[entrypoint] Starting server on ${HOST}:${PORT}"

cd /opt/BitNet

# Ensure run_inference_server sees the built llama-server at /opt/BitNet/build/...
# (Your Dockerfile already creates this symlink; keeping as a safety check)
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

# Launch the server (OpenAI-compatible endpoints on /v1/*)
exec python /opt/BitNet/run_inference_server.py "${args[@]}"
