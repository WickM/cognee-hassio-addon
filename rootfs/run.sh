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
export LLM_PROVIDER="${LLM_PROVIDER:-openai}"
export LLM_MODEL="${LLM_MODEL:-gpt-4o-mini}"
if [ -n "${LLM_BASE_URL:-}" ]; then
    export LLM_ENDPOINT="${LLM_BASE_URL}"
fi

export EMBEDDING_PROVIDER="${EMBEDDING_PROVIDER:-openai}"
export EMBEDDING_MODEL="${EMBEDDING_MODEL:-text-embedding-3-small}"
export EMBEDDING_DIMENSIONS="${EMBEDDING_DIMENSIONS:-1536}"
if [ -n "${EMBEDDING_BASE_URL:-}" ]; then
    export EMBEDDING_ENDPOINT="${EMBEDDING_BASE_URL}"
fi

# Cognee data root — point all file-based backends (sqlite, kuzu, lancedb)
# at the persistent /share/cognee mount so restart-survival is guaranteed.
export HOME="${DATA_PATH}"
# Cognee 0.3+ uses .data/ subdirectory by default; mkdir first.
mkdir -p "${DATA_PATH}/.data"

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
