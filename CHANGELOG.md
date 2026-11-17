# Changelog

All notable changes to this add-on are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.3.3] - 2026-10-01

### Changed — Cognee 1.4.2 → 1.6.1

Version bump of the pinned upstream `cognee` package. Config and REST
surface consumed by this add-on and by `@cognee/cognee-openclaw` are unchanged.

**Why 1.6.1 and not 1.6.2:** 1.6.2 shipped 2026-09-29, two days before this
pin. 1.6.1 carries the full 1.5 → 1.6 jump and had a week of field reports;
1.6.2 was 14 PRs old at pin time. The 1.4.2 → 1.6.x jump is the risky part,
not the `.1` vs `.2` patch, so take the version with more soak time.

**Verification method** — the 1.6.1 wheel was downloaded and inspected rather
than inferred from release notes. `ImprovePayloadDTO`
(`cognee/api/v1/improve/routers/get_improve_router.py`) keeps every field this
add-on and the OpenClaw plugin send:

- unchanged: `dataset_name`, `dataset_id`, `session_ids`, `node_name`,
  `build_global_context_index`, `run_in_background`, `feedback_alpha`
- added (additive, no breakage): `build_truth_subspace`, `extraction_tasks`,
  `enrichment_tasks`

`POST /api/v1/remember` (multipart: `datasetName`, `file`, `session_id`) and
`GET /health` are likewise unchanged.

**Dependency deltas across 1.5.x / 1.6.x** (all transitive, none pinned here):

- `litellm` capped `<1.97`
- `pydantic-settings` floor raised to `2.7.0`
- `instructor` capped `<1.15.3`
- `lancedb >=0.24.3`
- `fastapi >=0.116.2`
- Python floor unchanged: `<3.15, >=3.10`
- LadybugDB 0.19.0 remains the graph backend; do **not** add `kuzu` on top

### Notes

- No add-on code changed — this release is the dependency pin only.
- Persisted data at `data_path` (`/share/cognee`) is untouched; HA handles the
  volume across add-on updates (`backup: hot`).
- The add-on install/update itself stays a manual HA step; this tag only
  publishes the image to GHCR.

## [0.3.2] - 2026-09-09

### Fixed — single-port ASGI middleware (force HA update)

Version bump from 0.3.1 → 0.3.2. The previous 0.3.1 tag was force-pushed
with the same version string, which HA ignores (it compares the config.yaml
version string, not the git tag). This release has the correct image.

No code changes vs. 0.3.1 final:
- Single-port ASGI middleware on port 8000
- MCP SSE at `/sse` + `/messages/`
- Cognee REST API unchanged

## [0.3.1] - 2026-09-09

### Fixed — MCP integration (single-port ASGI middleware)

**Problem (v0.3.0):** The MCP server returned 500 Internal Server Error on
all requests. Root cause: the ASGI dispatcher used `mcp.streamable_http_app()`
which requires a session-manager initialized via ASGI lifespan — a raw
dispatcher doesn't forward lifespan events, so the session manager never
started.

**Fix:** Rewrote the combined app as an ASGI middleware that intercepts
only `/sse` and `/messages/` paths and routes them to the MCP SSE app.
Everything else goes to cognee's unmodified FastAPI app. Both on port
8000, single uvicorn.

Only SSE transport is used (not StreamableHTTP). SSE creates a fresh
session per connection and does NOT need lifespan initialization — making
it the simplest reliable integration path.

**Architecture:**
```
Port 8000 — single uvicorn
  /sse, /messages/* → MCP SSE (ASGI middleware intercept)
  /api/v1/*, /health, /docs → cognee FastAPI (passthrough)
```

**Agent configuration:**

OpenClaw:
```bash
openclaw mcp add cognee --url http://cognee:8000/sse --transport sse
```

Cline:
```json
{
  "mcpServers": {
    "cognee": {
      "url": "http://cognee:8000/sse",
      "transport": "sse"
    }
  }
}
```

### Fixed — MCP SDK version pin

`mcp>=2.0` pulled in MCP SDK 2.x, which renamed `FastMCP` to `MCPServer`
and changed the import path. Pinned to `mcp>=1.0,<2` (latest 1.x = 1.30.0).

### Changed files

- `rootfs/usr/sbin/cognee_combined_app.py` — rewritten: asyncio launcher
  (two uvicorn instances) instead of ASGI dispatcher.
- `rootfs/run.sh` — simplified: just exec the combined launcher script.
- `config.yaml` — added port 8001/tcp, updated descriptions.
- `Dockerfile` — pin `mcp>=1.0,<2`.

### Added — MCP (Model Context Protocol) server

The addon now exposes a native MCP server alongside cognee's REST API on the
same port (8000). This allows MCP-capable agents — OpenClaw, Cline, Kilo —
to use cognee as a graph memory tool without a separate plugin or REST
client.

**Transports:** SSE on port 8001 (`/sse` + `/messages/`)

**MCP tools exposed:**

| Tool | Cognee API | Purpose |
|------|-----------|--------|
| `cognee_search` | `POST /api/v1/search` | Semantic graph search |
| `cognee_add_text` | `POST /api/v1/add` | Ingest text into a dataset |
| `cognee_cognify` | `POST /api/v1/cognify` | Process data into knowledge graph |
| `cognee_recall` | `POST /api/v1/recall` | Memory-oriented recall |
| `cognee_list_datasets` | `GET /api/v1/datasets` | List datasets |
| `cognee_create_dataset` | `POST /api/v1/datasets` | Create a dataset |
| `cognee_get_dataset_data` | `GET /api/v1/datasets/{id}/data` | Get raw data |
| `cognee_get_graph` | `GET /api/v1/datasets/{id}/graph` | Get graph structure |

**Architecture:** The combined ASGI app (`cognee_combined_app.py`) uses an
ASGI middleware to intercept `/sse` and `/messages/` paths and route them to
the MCP SSE app. Everything else goes to cognee's FastAPI. Both on port
8000, single uvicorn. The MCP adapter (`cognee_mcp_server.py`) calls
cognee's REST API internally via `httpx`.

**Agent configuration:**

OpenClaw:
```bash
openclaw mcp add cognee --url http://cognee:8000/sse --transport sse
```

Cline (`cline_mcp_settings.json`):
```json
{
  "mcpServers": {
    "cognee": {
      "url": "http://cognee:8000/sse",
      "transport": "sse"
    }
  }
}
```

Kilo: analogous, same URL.

**Configuration:**
- `config.yaml`: new schema option `enable_mcp: bool` (default `true`).
- `Dockerfile`: added `mcp` and `httpx` to pip install.
- `rootfs/usr/sbin/cognee_mcp_server.py`: MCP adapter with 8 tools (new).
- `rootfs/usr/sbin/cognee_combined_app.py`: ASGI middleware (new).
- `rootfs/run.sh`: uvicorn with combined app.
- `rootfs/etc/cont-init.d/10-config`: reads and exports `ENABLE_MCP`.

## [0.2.3] - 2026-08-19

### Fixed — `cognify` crashes on Kilo + MiniMax-M3 BYOK routing

Cognee's `GenericAPIAdapter` defaults to `instructor_mode: "json_mode"`
for the `generic` provider, which sends `response_format: {type: "json_object"}`
in every LLM call. Kilo's BYOK route to MiniMax-M3 strips OpenAI-specific
features (`response_format`, `tools`) and returns HTTP 400
`Invalid input param: response_format`. Symptom in cognee log:

```
Retrying GenericAPIAdapter.acreate_structured_output ...
  litellm.APIConnectionError: MinimaxException - {"error":{"message":"Invalid input","type":"invalid_request_error","param":"response_format"}}
```

Switch to Instructor's `markdown_json_mode` (`MD_JSON`) which parses JSON
out of Markdown code-blocks and never sends `response_format`. Verified
working live with Instructor 1.15.1 + LiteLLM + Kilo + MiniMax-M3.

- `config.yaml`: new schema option `llm_instructor_mode: str?`.
- `config.yaml`: `options:` default is now `llm_instructor_mode: md_json`.
- `rootfs/etc/cont-init.d/10-config`: read `llm_instructor_mode` from
  HA options, export to env if non-empty.
- `rootfs/run.sh`: export `LLM_INSTRUCTOR_MODE` for cognee if set.
- Cognee reads it via `LLMConfig.llm_instructor_mode` (Pydantic-Settings,
  auto-loads from `LLM_INSTRUCTOR_MODE` env var).

### Fixed — Voyage 4-large rejects `output_dimension=0`

HA-UI auto-fills `int?` schema fields with `0` if the user leaves them
blank. cognee then sends `output_dimension=0` to Voyage, which returns
HTTP 422 (`accepted values: [256, 512, 1024, 2048]`). Symptom: a long
retry-loop followed by `Embedding connection test timed out after 30s`.

- `config.yaml`: removed `embedding_dimensions` from the addon's
  `options:` defaults block (was `1536`; was also forcing a non-default
  dimension on providers like Voyage that pick their own).
- `rootfs/etc/cont-init.d/10-config`: if `embedding_dimensions` is empty
  OR `0`, treat as unset (don't export). Provider falls back to its
  default (1024 for `voyage-4-large`).
- `rootfs/run.sh`: defense-in-depth — same unset-when-zero logic.

### Changed — sensible defaults for Kilo + MiniMax + Voyage

The addon's `options:` defaults previously hard-coded OpenAI's
`text-embedding-3-small` (1536 dim) and the `openai` provider, which
crashes with every MiniMax / Voyage combination. Updated defaults now
match a working Kilo + MiniMax-M3 + Voyage-4-large setup.

- `config.yaml` `options:`:
  - `llm_provider: custom` (was `openai`)
  - `embedding_provider: voyageai` (was `openai`)
  - `embedding_model: voyage/voyage-4-large` (was `text-embedding-3-small`)
  - `embedding_endpoint: https://api.voyageai.com/v1` (new)
  - `embedding_dimensions:` removed (was `1536`)
  - `llm_instructor_mode: md_json` (new)

## [0.2.1] - 2026-08-14

### Fixed — cognee 1.x default auth + endpoint resolution

Cognee 1.x enables multi-tenant + auth by default. For a single-user
hassio-addon this means every request (including OpenClaw's plugin) gets
`401 Unauthorized` until a Bearer token is supplied. `0.2.1` bypasses
both flags before any cognee import so the addon behaves like the
`0.1.x` series (no auth, single-user).

- `rootfs/run.sh`: `export ENABLE_BACKEND_ACCESS_CONTROL=false` and
  `export REQUIRE_AUTHENTICATION=false` immediately at startup. Both
  must be set: `REQUIRE_AUTHENTICATION=false` alone is silently
  overridden by cognee when backend access control is on. See
  `cognee/modules/users/methods/get_authenticated_user.py::_resolve_auth_posture`.

### Fixed — `EMBEDDING_ENDPOINT` / `LLM_ENDPOINT` not resolved reliably

Symptom in `/share/cognee/logs/options.env`:
`EMBEDDING_ENDPOINT=<unset>` even when `embedding_base_url` was set in HA.
Cause: `10-config` only sets `EMBEDDING_ENDPOINT` if `embedding_endpoint`
was present in HA options (new v0.2.0 schema field). For users who
configured `embedding_base_url` (the v0.1.x field) the variable was
empty and cognee saw no endpoint.

- `rootfs/etc/cont-init.d/10-config`: explicit fallback
  `EMBEDDING_BASE_URL → EMBEDDING_ENDPOINT` and `LLM_BASE_URL → LLM_ENDPOINT`.
- `rootfs/run.sh`: same fallback applied as a safety net, with
  diagnostic log lines so the final resolved endpoint is visible.
- `options.env` now includes `ENABLE_BACKEND_ACCESS_CONTROL`,
  `REQUIRE_AUTHENTICATION`, and the resolved `LLM_ENDPOINT` /
  `EMBEDDING_ENDPOINT` (or `<fallback-via-run.sh>` marker) for
  post-mortem verification.

### Verified

With `embedding_provider: openai_compatible`,
`embedding_model: voyage-4-large`,
`embedding_base_url: https://api.voyageai.com/v1`,
`embedding_dimensions: 1024`, and either the `pa-...` Voyage key in
`embedding_api_key` or the LLM key as fallback, the addon now boots
into cognee 1.4.2 with no `authentication=required` block, and
embedding calls hit `https://api.voyageai.com/v1/embeddings` directly
(no LiteLLM detour).

## [0.2.0] - 2026-08-14

### Changed — cognee 0.3.6 → 1.4.2

- Pin Cognee to `1.4.2`. The `0.3.x → 1.x` bump is required to use Voyage
  (or any non-OpenAI embedding model): `0.3.6` runs every embedding through
  a tiktoken tokenizer that only knows OpenAI model names and crashes with
  `'Could not automatically map <model> to a tokeniser'`. `1.x` adds
  `openai_compatible` as a first-class provider that talks any
  OpenAI-spec `/v1/embeddings` endpoint directly (Voyage, OpenRouter, etc.).
- Graph-database backend: `0.3.6` shipped Kuzu directly; `1.4.2` uses
  **LadybugDB** (Kuzu fork) as the primary backend, pulled in as a
  transitive cognee dependency. **Do not** add `pip install kuzu` to the
  Dockerfile — that would install the legacy package and mix incompatible
  backends with the Ladybug adapter cognee uses internally. The provider
  name `kuzu` is still accepted by cognee and routed to the Ladybug
  adapter, so no config change is needed there.

### Added — `embedding_endpoint` (cognee 1.x variable name)

- `embedding_endpoint: str?` added to `config.yaml` schema. Required when
  `embedding_provider: openai_compatible` (cognee does not fall back to
  `embedding_base_url` for that provider).
- `embedding_base_url` is kept for backwards-compat with `openai` provider
  and existing v0.1.x configs.
- `rootfs/etc/cont-init.d/10-config` reads the new field and exports
  `EMBEDDING_ENDPOINT` to env.
- `rootfs/run.sh` prefers `EMBEDDING_ENDPOINT` and falls back to
  `EMBEDDING_BASE_URL` when unset, so v0.1.x configs continue to work.

### Migration: Kilo (LLM) + Voyage (embeddings) — recipe

Defaults stay on Kilo/OpenAI for safe upgrades; switch to Voyage
explicitly via:

```yaml
llm_provider: openai
llm_model: minimax/minimax-m3
llm_base_url: https://api.kilo.ai/api/gateway/v1

embedding_provider: openai_compatible
embedding_model: voyage-4-large
embedding_dimensions: 1024
embedding_endpoint: https://api.voyageai.com/v1
embedding_api_key: <your-voyage-key>
```

Voyage API keys start with `pa-`. The `embedding_dimensions` must stay
at `1024` for `voyage-4-large`; changing the dimension requires a clean
rebuild of the LanceDB vector index (delete
`/share/cognee/.data_storage/lancedb_data` before re-indexing).

### Notes for existing installs

- Schema gains one optional field (`embedding_endpoint`). HA UI surfaces
  it automatically as an empty text input on the Configuration tab. Leave
  blank if you are on the Kilo/OpenAI defaults — nothing breaks.
- No `services.d/cognee/run` change (v0.1.6's re-source fix stays).
- No `10-config` schema-change for existing fields — purely additive.

## [0.1.6] - 2026-08-12

### Fixed

- **s6-overlay env-pass-through bug**: cont-init scripts run as a
  separate process tree under s6-supervision, so the `export LLM_API_KEY=...`
  statements in `/etc/cont-init.d/10-config` never reach the supervised
  service. Symptom: cognee's startup log shows
  `LLM_PROVIDER=<unset> LLM_MODEL=<unset>`, and the first call to
  `/api/v1/settings` raises
  `pydantic_core.ValidationError: llm.api_key Input should be a valid string`.
  The s6 service-run script now re-reads `/data/options.json` and sources
  it into the service environment with `set -a; . <tmpfile>; set +a`.
  The tmpfile is mode 0600 and removed immediately after, so secrets
  don't linger on disk (HA's `/data/options.json` itself is the
  authoritative store and is the only persistent copy).

- **JWT-safe value transport**: `export KEY=value` from jq output would
  truncate values containing `=` (e.g. `eyJhbGc….kUT9spvaU-L64c=`) at
  the first `=`. The new approach uses `set -a; . file; set +a` which
  parses each line as a complete assignment regardless of `=` chars in
  the value.

### Notes

- No schema change. No HA UI change. Pure server-side fix.
- This is the fix for the "cognee starts then crashes on first
  settings call" symptom visible in the v0.1.5 addon log.

## [0.1.5] - 2026-08-12

### Fixed

- **`_bashio_config()` default-fallback**: when bashio returned an empty
  string (silent Supervisor 403 / fallback) for non-`llm_api_key` keys
  like `llm_model`, the user-supplied default was ignored, so the env
  vars `LLM_MODEL`, `LLM_PROVIDER`, etc. propagated to cognee as
  `<unset>` — even though config.yaml had explicit defaults. Cognee's
  LLMConfig then errored with `Missing credentials` because it could
  not resolve a model. The helper now applies the default locally
  when bashio returns empty.

- **`run.sh` default mismatch**: the fallback defaults in run.sh
  (`gpt-4o-mini`, no embedding dims) did not match the config.yaml
  schema defaults (`minimax/minimax-m3`, 1536 dims). Now they match,
  so even if 10-config failed entirely, cognee still gets the
  kilocode-gateway / voyage-compatible defaults the user expects.

## [0.1.4] - 2026-08-11

### Fixed

- **Persistence**: cognee 0.3.6's `base_config.py` reads three env
  vars (`SYSTEM_ROOT_DIRECTORY`, `DATA_ROOT_DIRECTORY`,
  `CACHE_ROOT_DIRECTORY`) for sqlite/lancedb/kuzu storage. Without
  them set, cognee falls back to `.cognee_system/` relative to its
  package directory — i.e. inside the container image, wiped on every
  addon restart. `run.sh` now exports all three pointing at
  `${DATA_PATH}` (`/share/cognee/.cognee_system` etc.), and 10-config
  creates the dirs at boot.

### Notes

- No schema change. No HA UI change. Pure server-side fix.

## [0.1.3] - 2026-08-11

### Fixed

- **Supervisor API 403 fallback**: when the addon is installed as a static
  / sideloaded image (no Supervisor token), `bashio::config` calls silently
  return empty even though bashio itself loaded fine. This caused the
  container to fatall with "llm_api_key is empty" even when the user
  *had* filled in the key. `_bashio_config()` now probes `llm_api_key`
  once: if bashio returns empty but `/data/options.json` has a value,
  latches jq mode for the rest of the script (via flag file at
  `/tmp/.cognee-use-jq` — flag file needed because the helper is invoked
  via `$(...)` command substitution which runs in a subshell and doesn't
  propagate in-memory var assignments to the parent). One log line on
  stderr surfaces the fallback so it's not silent.

### Notes

- No `config.yaml` schema change. No env-var change. Pure client-side fix
  in `10-config`.
- `bashio readonly variable` cascade at startup remains harmless noise
  from bashio's `const.sh` being sourced twice in the addon init
  sequence. Does not affect service startup.

## [0.1.2] - 2026-08-08

### Fixed

- bashio double-source bug from v0.1.1: the manual `source /usr/bin/bashio`
  in script body combined with the `#!/usr/bin/bashio` shebang caused
  bashio's `const.sh` to load twice → `readonly variable` errors →
  bootstrap abort ("script to source must be provided"). Removed manual
  source; shebang alone is sufficient.
- Replaced broken `bashio --version` probe with `declare -F bashio::config`
  check that confirms whether bashio actually loaded.

### Changed

- No file or env-var changes vs. v0.1.1; same `_bashio_config()` fallback.

## [0.1.1] - 2026-08-08

### Fixed

- bashio bootstrap: shebang `#!/usr/bin/bashio` (absolute path) + explicit
  `source /usr/bin/bashio` in `10-config` and `run.sh` — bashio library
  should be loaded into the script shell before `bashio::config` calls.

### Added

- `_bashio_config()` helper with jq fallback to `/data/options.json`.
- `declare -F` guards on `bashio::exit.nok` and `bashio::log.warning`.

## [0.1.0] - 2026-08-06

### Added

- Initial scaffold.
- Cognee 0.3.6 pinned in Dockerfile.
- s6-overlay v3.2.1.0 + bashio v0.18.1 + tempio 2024.11.2 base layout
  (mirrored from `mlflow-hassio-addon`).
- `init: false` — required for HA Supervisor compatibility.
- 10-config cont-init schema mapping (HA addon options → cognee env vars).
- Single-API-key fallback (`embedding_api_key` falls back to `llm_api_key`).
- Default config: kilocode gateway + MiniMax + `text-embedding-3-small`.
- Defensive `.gitignore` blocking `.env`, `*.key`, `*.pem`, `secrets.yaml`.
- GitHub Actions build-and-push workflow (amd64 → `ghcr.io/wickm/cognee-hassio-addon`).
- README with 3 working recipes (kilocode, voyage+openai, ollama).

### Known gaps (do not ship v0.2.0 until resolved)

- [ ] Restart-survival validation (Phase 3 of plan).
- [ ] JWT-secret persistence test.
- [ ] 7-day capacity validation (Phase 5).
- [ ] `aarch64` build matrix entry.

## v0.1.4 — 2026-08-12

### Changed
- No functional changes vs. v0.1.3.
- Version bump to force the Home Assistant add-on store to surface the update
  (HA only re-checks the GHCR manifest when the version string differs).
- Resolves a stale rebase state in this repo from prior session.

### Why this release exists
v0.1.3 (commit `3ca3acf`) already contains the persistence fix
(`SYSTEM_ROOT_DIRECTORY` / `DATA_ROOT_DIRECTORY` / `CACHE_ROOT_DIRECTORY`).
If you already updated to v0.1.3 and the log shows
`Database storage: /share/cognee/.cognee_system/databases`, you're done —
v0.1.4 brings no new behavior.

## [0.2.4] - 2026-08-19

### Fixed
- **`llm_instructor_mode` default corrected**: `md_json` → `MD_JSON`. Cognee calls `instructor.Mode(self.instructor_mode)` which is a Python `enum.Enum` and only accepts the **enum member name** (case-sensitive), not the string value. The string `"md_json"` is invalid; the correct value is `"MD_JSON"` (the enum-name maps to value `"markdown_json_mode"`).

### Verified
- Live-tested against Kilo + MiniMax-M3 (BYOK) with `MD_JSON` mode: returns valid JSON extracted from `\`\`\`json{...}\`\`\`` code block. No `response_format` header sent. ✅
- TOOLS mode: M3 ignores tool_choice / makes multiple tool calls (Instructor can't parse). ❌
- JSON mode: Kilo returns 400 `Invalid input param: response_format`. ❌
