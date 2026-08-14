#!/usr/bin/bashio
# Cognee API server entrypoint.
# Reads env set by /etc/cont-init.d/10-config, maps to cognee's expected
# variable names, and launches uvicorn against cognee's FastAPI app.
set -e



# ---- Sanity & diagnostics ----
echo "[run.sh] uid=$(id -u) cwd=$(pwd) PATH=$PATH"
echo "[run.sh] python: $(command -v python || command -v python3 || echo 'NOT FOUND')"
echo "[run.sh] cognee on PATH: $(command -v cognee || echo 'NOT FOUND')"
echo "[run.sh] DATA_PATH=${DATA_PATH:-<unset>}"
echo "[run.sh] SYSTEM_ROOT_DIRECTORY=${SYSTEM_ROOT_DIRECTORY:-<unset>}"
echo "[run.sh] DATA_ROOT_DIRECTORY=${DATA_ROOT_DIRECTORY:-<unset>}"
echo "[run.sh] CACHE_ROOT_DIRECTORY=${CACHE_ROOT_DIRECTORY:-<unset>}"
echo "[run.sh] COGNEE_PORT=${COGNEE_PORT:-8000} LLM_PROVIDER=${LLM_PROVIDER:-<unset>} LLM_MODEL=${LLM_MODEL:-<unset>}"
echo "[run.sh] EMBEDDING_PROVIDER=${EMBEDDING_PROVIDER:-<unset>} EMBEDDING_MODEL=${EMBEDDING_MODEL:-<unset>} DIM=${EMBEDDING_DIMENSIONS:-<unset>}"
echo "[run.sh] AGENT_MODE=${AGENT_MODE:-false} LOG_LEVEL=${LOG_LEVEL:-INFO}"

# ---- Defensive defaults in case 10-config didn't run ----
: "${DATA_PATH:=/share/cognee}"
: "${COGNEE_PORT:=8000}"
: "${AGENT_MODE:=true}"
: "${LOG_LEVEL:=INFO}"

mkdir -p "${DATA_PATH}/.cognee" "${DATA_PATH}/logs"

# ---- Map addon options to cognee's env vars ----
# Cognee reads LLM_* / EMBEDDING_* prefix vars for provider config.
# See: https://docs.cognee.ai/configuration/environment-variables
export LLM_API_KEY="${LLM_API_KEY:-}"
export EMBEDDING_API_KEY="${EMBEDDING_API_KEY:-${LLM_API_KEY:-}}"

# Provider + model hints — cognee uses these to pick the right client
# v0.1.5: defaults aligned with config.yaml schema defaults so that even if
# 10-config's bashio/jq reads failed, the values are still correct.
export LLM_PROVIDER="${LLM_PROVIDER:-openai}"
export LLM_MODEL="${LLM_MODEL:-minimax/minimax-m3}"
if [ -n "${LLM_BASE_URL:-}" ]; then
    export LLM_ENDPOINT="${LLM_BASE_URL}"
fi

export EMBEDDING_PROVIDER="${EMBEDDING_PROVIDER:-openai}"
export EMBEDDING_MODEL="${EMBEDDING_MODEL:-text-embedding-3-small}"
export EMBEDDING_DIMENSIONS="${EMBEDDING_DIMENSIONS:-1536}"
# v0.2.0: cognee 1.x reads `EMBEDDING_ENDPOINT` for `openai_compatible`.
# Prefer the explicit endpoint if set, else fall back to `EMBEDDING_BASE_URL`
# (kept for backwards-compat with v0.1.x configs and the `openai` provider).
if [ -n "${EMBEDDING_ENDPOINT:-}" ]; then
    :  # already exported by 10-config / s6 service-run
elif [ -n "${EMBEDDING_BASE_URL:-}" ]; then
    export EMBEDDING_ENDPOINT="${EMBEDDING_BASE_URL}"
fi

# Cognee data root — point all file-based backends (sqlite, kuzu, lancedb)
# at the persistent /share/cognee mount so restart-survival is guaranteed.
# Cognee 0.3.6 reads these three env vars (see cognee/base_config.py):
#   - SYSTEM_ROOT_DIRECTORY  → sqlite metadata
#   - DATA_ROOT_DIRECTORY    → lancedb vector store
#   - CACHE_ROOT_DIRECTORY   → caches
# Without these, cognee falls back to .cognee_system / .data_storage /
# .cognee_cache *relative to the cognee package directory* — which is
# inside the container image and is wiped on restart.
export SYSTEM_ROOT_DIRECTORY="${DATA_PATH}/.cognee_system"
export DATA_ROOT_DIRECTORY="${DATA_PATH}/.data_storage"
export CACHE_ROOT_DIRECTORY="${DATA_PATH}/.cognee_cache"
export HOME="${DATA_PATH}"
# Create all three before uvicorn starts (pydantic-settings validates
# that they're absolute; cognee's lifespan will fail if dirs missing).
mkdir -p "${SYSTEM_ROOT_DIRECTORY}" "${DATA_ROOT_DIRECTORY}" "${CACHE_ROOT_DIRECTORY}" "${DATA_PATH}/.data" "${DATA_PATH}/logs"

# ---- Launch ----
PY="$(command -v python || command -v python3)"
echo "[run.sh] starting cognee API on 0.0.0.0:${COGNEE_PORT}"
echo "[run.sh] agent_mode=${AGENT_MODE} (auto-shutdown when no agent is active)"

# Cognee exposes a FastAPI app under cognee.api. Use uvicorn directly.
# AGENT_MODE=true tells cognee to idle-sleep when no client is connected,
# which is the addon-friendly behavior for a sidecar memory service.
exec "${PY}" -m uvicorn cognee.api.client:app \
    --host 0.0.0.0 \
    --port "${COGNEE_PORT}" \
    --log-level "$(echo "${LOG_LEVEL}" | tr '[:upper:]' '[:lower:]')" \
    --no-access-log
