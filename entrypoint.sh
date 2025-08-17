#!/usr/bin/env bash
set -euo pipefail

echo "[entrypoint] MODEL_PATH=${MODEL_PATH}"
if [ ! -f "${MODEL_PATH}" ]; then
  if [ -n "${MODEL_URL:-}" ]; then
    echo "[entrypoint] downloading model from: ${MODEL_URL}"
    mkdir -p "$(dirname "${MODEL_PATH}")"
    curl -L --fail --retry 3 -o "${MODEL_PATH}" "${MODEL_URL}"
  else
    echo "[entrypoint] MODEL_URL not set and model file missing; continuing without download."
  fi
fi

echo "[entrypoint] BitNet repo is at /opt/BitNet ; model at ${MODEL_PATH}"
exec "$@"
