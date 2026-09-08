# Changelog

All notable changes to this add-on are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.3.0] - 2026-09-08

### Added — MCP (Model Context Protocol) server

The addon now exposes a native MCP server alongside cognee's REST API on the
same port (8000). This allows MCP-capable agents — OpenClaw, Cline, Kilo —
to use cognee as a graph memory tool without a separate plugin or REST
client.

**Transports** (both on port 8000):
- `Streamable HTTP` at `/mcp` (modern MCP spec, single endpoint)
- `SSE` at `/sse` + `/messages/` (legacy HTTP, broader compatibility)

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

**Architecture:** A single ASGI dispatcher (`cognee_combined_app.py`) routes
requests by path: `/mcp` → MCP Streamable HTTP, `/sse` + `/messages/*` → MCP
SSE, everything else → cognee's unmodified FastAPI app. The MCP adapter
(`cognee_mcp_server.py`) calls cognee's REST API internally via `httpx`.

**Agent configuration:**

OpenClaw:
```bash
openclaw mcp add cognee --url http://cognee:8000/mcp --transport streamable-http
```

Cline (`cline_mcp_settings.json`):
```json
{
  "mcpServers": {
    "cognee": {
      "url": "http://cognee:8000/mcp",
      "transport": "streamable-http"
    }
  }
}
```

Kilo: analogous, same URL.

**Configuration:**
- `config.yaml`: new schema option `enable_mcp: bool` (default `true`).
  When disabled, the addon launches cognee-only as before (v0.2.x behavior).
- `Dockerfile`: added `mcp>=2.0` and `httpx>=0.27` to the pip install.
- `rootfs/usr/sbin/cognee_mcp_server.py`: MCP adapter with 8 tools (new).
- `rootfs/usr/sbin/cognee_combined_app.py`: ASGI dispatcher (new).
- `rootfs/run.sh`: conditional combined-app launch when `ENABLE_MCP=true`.
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
