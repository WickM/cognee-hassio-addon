#!/usr/bin/bashio
# Cognee API server entrypoint.
# Reads env set by /etc/cont-init.d/10-config, maps to cognee's expected
# variable names, and launches uvicorn against cognee's FastAPI app.
set -e

# ---- v0.2.1: cognee 1.x default auth bypass ----
# Cognee 1.x enables multi-tenant + auth by default. For a single-user
# hassio-addon we want neither. Both flags must be set BEFORE any cognee
# import (they're read at module-import time by get_authenticated_user.py).
# Setting only REQUIRE_AUTHENTICATION=false is not enough — cognee forces
# it back on if ENABLE_BACKEND_ACCESS_CONTROL stays true. See
# cognee/modules/users/methods/get_authenticated_user.py::_resolve_auth_posture.
export ENABLE_BACKEND_ACCESS_CONTROL=false
export REQUIRE_AUTHENTICATION=false



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
echo "[run.sh] LLM_INSTRUCTOR_MODE=${LLM_INSTRUCTOR_MODE:-<unset>}"
echo "[run.sh] AGENT_MODE=${AGENT_MODE:-false} LOG_LEVEL=${LOG_LEVEL:-INFO}"

# ---- Defensive defaults in case 10-config didn't run ----
: "${DATA_PATH:=/share/cognee}"
: "${COGNEE_PORT:=8000}"
: "${AGENT_MODE:=true}"
: "${LOG_LEVEL:=INFO}"
: "${ENABLE_MCP:=true}"

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
# v0.2.3: don't default EMBEDDING_DIMENSIONS to anything — cognee/embedding
# provider picks its own default (e.g. Voyage 4-large → 1024). Earlier
# versions defaulted to 1536 which broke Voyage/OpenAI non-default models.
if [ -n "${EMBEDDING_DIMENSIONS:-}" ]; then
    export EMBEDDING_DIMENSIONS
else
    unset EMBEDDING_DIMENSIONS
fi
# v0.2.1: cognee 1.x reads `EMBEDDING_ENDPOINT` for `openai_compatible`.
# Resolve *before* exporting so we can log the final value. Prefer the
# explicit endpoint (set via v0.2.0+ schema field `embedding_endpoint`),
# else fall back to `EMBEDDING_BASE_URL` (v0.1.x compat + the `openai`
# provider, which uses the same field name).
if [ -z "${EMBEDDING_ENDPOINT:-}" ] && [ -n "${EMBEDDING_BASE_URL:-}" ]; then
    export EMBEDDING_ENDPOINT="${EMBEDDING_BASE_URL}"
fi
export EMBEDDING_ENDPOINT

# v0.2.3: instructor mode override. Empty means "cognee default".
# Kilo's BYOK MiniMax routing rejects `response_format: json_object` so
# `md_json` (Instructor's markdown_json_mode) is required for Kilo+M3.
if [ -n "${LLM_INSTRUCTOR_MODE:-}" ]; then
    export LLM_INSTRUCTOR_MODE
else
    unset LLM_INSTRUCTOR_MODE
fi

# v0.2.1: same for LLM. Kilo is exposed OpenAI-compatible but the `openai`
# provider works against any /v1/chat/completions endpoint via LLM_BASE_URL.
# If the user picked `openai_compatible`, cognee 1.x also wants LLM_ENDPOINT.
if [ -z "${LLM_ENDPOINT:-}" ] && [ -n "${LLM_BASE_URL:-}" ]; then
    export LLM_ENDPOINT="${LLM_BASE_URL}"
fi
export LLM_ENDPOINT

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
echo "[run.sh] effective endpoints: LLM_ENDPOINT=${LLM_ENDPOINT:-<unset>} EMBEDDING_ENDPOINT=${EMBEDDING_ENDPOINT:-<unset>}"
echo "[run.sh] auth bypass: ENABLE_BACKEND_ACCESS_CONTROL=${ENABLE_BACKEND_ACCESS_CONTROL} REQUIRE_AUTHENTICATION=${REQUIRE_AUTHENTICATION}"
echo "[run.sh] mcp: ENABLE_MCP=${ENABLE_MCP}"
echo "[run.sh] starting cognee API on 0.0.0.0:${COGNEE_PORT}"
echo "[run.sh] agent_mode=${AGENT_MODE} (auto-shutdown when no agent is active)"

# Cognee exposes a FastAPI app under cognee.api. Use uvicorn directly.
# AGENT_MODE=true tells cognee to idle-sleep when no client is connected,
# which is the addon-friendly behavior for a sidecar memory service.
#
# v0.3.0: when ENABLE_MCP=true (default), launch the combined ASGI app
# that mounts cognee's FastAPI + MCP Streamable HTTP + SSE on a single
# port. The MCP adapter lives at /usr/sbin/cognee_combined_app.py and
# dispatches based on path (/mcp, /sse, /messages/* → MCP; everything
# else → cognee). When disabled, fall back to cognee-only as before.
if [ "${ENABLE_MCP}" = "true" ]; then
    echo "[run.sh] MCP enabled — launching combined app (cognee + MCP on /mcp, /sse)"
    exec "${PY}" -m uvicorn cognee_combined_app:app \
        --app-dir /usr/sbin \
        --host 0.0.0.0 \
        --port "${COGNEE_PORT}" \
        --log-level "$(echo "${LOG_LEVEL}" | tr '[:upper:]' '[:lower:]')" \
        --no-access-log
else
    echo "[run.sh] MCP disabled — launching cognee API only"
    exec "${PY}" -m uvicorn cognee.api.client:app \
        --host 0.0.0.0 \
        --port "${COGNEE_PORT}" \
        --log-level "$(echo "${LOG_LEVEL}" | tr '[:upper:]' '[:lower:]')" \
        --no-access-log
fi
