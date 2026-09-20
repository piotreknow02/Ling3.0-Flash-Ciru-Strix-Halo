#!/usr/bin/env bash
set -euo pipefail

# Ling 3.0 Flash CIRU INT4 on AMD Strix Halo (gfx1151) — one-command deploy.
#
# Order of operations: preflight -> build image (cached) -> download checkpoint
# (resumable, host-side) -> run container -> wait for /health -> print endpoints.
# Idempotent: re-running skips build/download and reports "already running" if
# the container is up.
#
# Precedence (highest first):
#   1. shell env vars already exported when you run ./start.sh
#   2. values in ./.env
#   3. inline defaults below

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/.env" ]]; then
  # `|| [[ -n "${key}" ]]` so a final line without a trailing newline is not dropped.
  while IFS='=' read -r key value || [[ -n "${key}" ]]; do
    # Tolerate CRLF files and surrounding whitespace, and skip indented comments —
    # otherwise `${!key}` below would be an indirect expansion on an invalid name.
    key="${key%$'\r'}"; value="${value%$'\r'}"
    key="${key#"${key%%[![:space:]]*}"}"; key="${key%"${key##*[![:space:]]}"}"
    [[ -z "${key}" || "${key}" == \#* ]] && continue
    if [[ -z "${!key:-}" ]]; then
      export "${key}=${value}"
    fi
  done < "${SCRIPT_DIR}/.env"
fi

IMAGE="${IMAGE:-ling3-ciru-strix:latest}"
CONTAINER_NAME="${CONTAINER_NAME:-ling3-ciru-strix}"
PORT="${PORT:-8080}"                       # host publish port (container listens on 18081)
MODEL_DIR="${MODEL_DIR:-${SCRIPT_DIR}/models}"
CACHE_DIR="${CACHE_DIR:-${SCRIPT_DIR}/.cache}"
PROFILE="${PROFILE:-256k}"                # 256k (validated) | 1m-yarn (experimental)
# GPU_MEMORY_UTILIZATION intentionally unset by default: the profile default
# (0.72 for 256k, 0.82 for 1m-yarn) comes from the package's config.
LOG_FILE="${LOG_FILE:-${SCRIPT_DIR}/.ling3.log}"
READY_TIMEOUT="${READY_TIMEOUT:-3600}"     # seconds; cold-cache compile is minutes

MODEL_REPO="jcbtc/Ling-3.0-Flash-CIRU-int4-Strix-native"
MODEL_REVISION="936668b83eaf36ae7d57e39c414c07b9a00726ad"
SERVED_MODEL_ID="Ling-3.0-Flash-CIRU-int4-Strix-native"
RUN_SCRIPT="run-256k.sh"
case "${PROFILE}" in
  256k) ;;
  1m-yarn) RUN_SCRIPT="run-1m-yarn-experimental.sh" ;;
  *) echo "PROFILE '${PROFILE}' unsupported (use 256k or 1m-yarn)"; exit 1 ;;
esac

# ---- preflight ---------------------------------------------------------------
command -v podman >/dev/null 2>&1 || { echo "podman is not on PATH"; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "curl is not on PATH"; exit 1; }
[[ -e /dev/kfd && -d /dev/dri ]] || {
  echo "/dev/kfd or /dev/dri missing — is the AMD GPU driver loaded?"
  exit 1
}
if ! id -nG | grep -qw render; then
  echo "warning: current user is not in the 'render' group; rootless /dev/kfd access may fail"
fi

# memlock: informational only. Rootless podman clamps --ulimit memlock to the
# user session's hard limit; the flag below takes effect if it's already raised.
# If the engine later dies with HSA "Cannot allocate memory" pin errors, raise it
# once (optional, needs sudo — see README troubleshooting).
MEMLOCK_HARD="$(systemctl show "user@$(id -u).service" -p LimitMEMLOCK --value 2>/dev/null || echo unknown)"
if [[ "${MEMLOCK_HARD}" != "infinity" ]]; then
  echo "note: memlock hard limit is ${MEMLOCK_HARD} bytes (not infinity);"
  echo "      fine unless the engine reports HSA pin/allocate errors — see README."
fi

# ---- image -----------------------------------------------------------------
if podman image exists "${IMAGE}"; then
  echo "Image ${IMAGE} already present; skipping build"
else
  # The vendor installer checks for /dev/kfd at build time, so the GPU devices
  # are passed to `podman build` as well (keep-groups carries render access in).
  echo "Building ${IMAGE} (first time: ~20-40 min, multi-GB wheel download + vLLM compile)"
  podman build --device /dev/kfd --device /dev/dri --group-add keep-groups -t "${IMAGE}" "${SCRIPT_DIR}"
fi

# ---- model checkpoint (host-side, resumable) ---------------------------------
if [[ ! -f "${MODEL_DIR}/config.json" ]]; then
  if command -v hf >/dev/null 2>&1; then
    HF=(hf)
  elif command -v uvx >/dev/null 2>&1; then
    HF=(uvx --from 'huggingface_hub[cli]' hf)
  else
    echo "Need the HuggingFace CLI to download the checkpoint."
    echo "Install one of:  pip install 'huggingface_hub[cli]'   or   uv (provides uvx)"
    exit 1
  fi
  echo "Downloading ${MODEL_REPO} (${MODEL_REVISION}) -> ${MODEL_DIR} (~77 GB, resumable)"
  mkdir -p "${MODEL_DIR}"
  "${HF[@]}" download "${MODEL_REPO}" --revision "${MODEL_REVISION}" --local-dir "${MODEL_DIR}"
  [[ -f "${MODEL_DIR}/config.json" ]] || { echo "download incomplete: config.json missing"; exit 1; }
  [[ -f "${MODEL_DIR}/model.safetensors.index.json" ]] || {
    echo "download incomplete: model.safetensors.index.json missing"; exit 1
  }
else
  echo "Checkpoint present at ${MODEL_DIR}; skipping download"
fi

# ---- container lifecycle (idempotent) ----------------------------------------
if podman ps -a --format '{{.Names}}' | grep -qx "${CONTAINER_NAME}"; then
  if podman ps --format '{{.Names}}' | grep -qx "${CONTAINER_NAME}"; then
    echo "Container ${CONTAINER_NAME} is already running"
    echo "Log: ${LOG_FILE}"
    exit 0
  fi
  podman rm "${CONTAINER_NAME}" >/dev/null
fi

mkdir -p "${CACHE_DIR}"

echo "Starting ${CONTAINER_NAME} (profile: ${PROFILE}, host port: ${PORT})"
echo "Model: ${MODEL_DIR} -> /models (ro)   Cache: ${CACHE_DIR} -> /cache"

UTIL_ARGS=()
if [[ -n "${GPU_MEMORY_UTILIZATION:-}" ]]; then
  UTIL_ARGS=(-e "GPU_MEMORY_UTILIZATION=${GPU_MEMORY_UTILIZATION}")
fi

# --ipc host is load-bearing (GPU runtime dies at startup without it; no
# shm_size substitutes). --group-add keep-groups carries the host render group
# into the rootless container for /dev/kfd. :z relabels binds for SELinux.
podman run -d \
  --name "${CONTAINER_NAME}" \
  --device /dev/kfd --device /dev/dri \
  --group-add keep-groups \
  --ipc host \
  --ulimit memlock=-1:-1 \
  -p "${PORT}:18081" \
  -v "${MODEL_DIR}:/models:ro,z" \
  -v "${CACHE_DIR}:/cache:z" \
  -e MODEL_PATH=/models -e HOST=0.0.0.0 -e PORT=18081 \
  "${UTIL_ARGS[@]}" \
  "${IMAGE}" bash "/opt/ling3/Ling-3.0-Flash-CIRU-int4-Strix-native/scripts/${RUN_SCRIPT}" \
  >/dev/null

echo "Spawned container ${CONTAINER_NAME}"

# ---- readiness ---------------------------------------------------------------
log_follow_pid=""
cleanup() {
  if [[ -n "${log_follow_pid}" ]] && kill -0 "${log_follow_pid}" 2>/dev/null; then
    kill "${log_follow_pid}" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# Stream the engine log to the terminal AND record it in .ling3.log.
# $! tracks the pipeline group; killing it on exit SIGPIPEs podman logs.
podman logs -f "${CONTAINER_NAME}" 2>&1 | tee -a "${LOG_FILE}" &
log_follow_pid=$!

READY_URL="http://127.0.0.1:${PORT}/health"
echo "Waiting for HTTP readiness at ${READY_URL} (timeout ${READY_TIMEOUT}s)"
deadline=$(( $(date +%s) + READY_TIMEOUT ))
heartbeat=0
until curl -fsS "${READY_URL}" >/dev/null 2>&1; do
  if ! podman ps --format '{{.Names}}' | grep -qx "${CONTAINER_NAME}"; then
    echo "Container exited before becoming ready"
    tail -n 200 "${LOG_FILE}" || true
    exit 1
  fi
  if (( $(date +%s) >= deadline )); then
    echo "Timed out after ${READY_TIMEOUT}s waiting for readiness"
    tail -n 200 "${LOG_FILE}" || true
    exit 1
  fi
  # The log itself is streaming above; only a light heartbeat every ~30s.
  if (( heartbeat % 6 == 0 )); then
    echo "  still starting..."
  fi
  heartbeat=$((heartbeat + 1))
  sleep 5
done

echo "Ling 3.0 Flash CIRU is ready"
echo "OpenAI base URL: http://127.0.0.1:${PORT}/v1"
echo "Served model id: ${SERVED_MODEL_ID}"
echo "Recommended sampling: temperature 0.6, top_p 0.95, top_k 20, chat_template_kwargs {\"enable_thinking\": true}"
echo "Try: curl -s http://127.0.0.1:${PORT}/v1/chat/completions -H 'Content-Type: application/json' -d '{"model":"${SERVED_MODEL_ID}","messages":[{"role":"user","content":"Hello"}],"temperature":0.6,"top_p":0.95,"top_k":20,"max_tokens":64,"chat_template_kwargs":{"enable_thinking":true}}'"
