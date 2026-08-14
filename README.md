# Cognee Hass.io Add-on

Home Assistant Supervisor add-on that runs the [Cognee](https://github.com/topoteretes/cognee)
graph-memory API server as a sidecar — designed to live next to
[OpenClaw](https://github.com/openclaw/openclaw) or any agent framework.

> **Status:** v0.2.1 — Cognee 1.4.2, auth bypass for single-user addon,
> robust `EMBEDDING_ENDPOINT` / `LLM_ENDPOINT` resolution from the v0.1.x
> `*_base_url` fields. See [CHANGELOG](CHANGELOG.md) for the full diff.
> embedding support. Defaults stay on Kilo/OpenAI for safe upgrades;
> see the [Kilo + Voyage recipe](#b-voyage-ai-via-openai_compatible) for
> switching embeddings to Voyage (`voyage-4-large`, 1024-dim).
> Restart-survival, JWT-secret persistence, and 7-day capacity validation
> are still pending. See [`brain/plans/2026-08-06-cognee-memory-hassio-addon.md`](https://github.com/WickM/openclaw-backup)
> for the full plan.

---

## Why this exists

Cognee stores embeddings + knowledge graph in local files (SQLite, Kuzu,
LanceDB). If you run it in-process inside another addon (e.g. embedded
in the OpenClaw container), a single container restart blows away
in-memory state and risks losing write-ahead logs that haven't been
checkpointed.

Side-by-side — separate addon, shared `/share/cognee` volume — gives:

- **Restart isolation** — OpenClaw updates don't kill the memory service.
- **Persistent storage** on `/share/cognee` (HA's `share` map).
- **Independent upgrade path** for cognee itself.
- **Clean resource accounting** — cognee RAM/CPU doesn't compete with
  the agent.

## Install

1. Add this repo as a custom add-on repository in Home Assistant:
   - HA UI → **Settings → Add-ons → Add-on Store → ⋮ → Repositories**
   - URL: `https://github.com/WickM/cognee-hassio-addon`
2. Refresh, install **Cognee** from the new "Cognee Add-on Repository" section.
3. Open the **Configuration** tab and fill in:
   - **API keys** — your provider keys (masked)
   - **Embedding** — provider, model, dimensions
   - **LLM** — provider, model
   - **Add-on** — port (default 8000), agent_mode, log level, data path
4. Start the add-on. Health-check the API:
   ```bash
   curl http://<addon-host>:8000/health
   ```

## Configuration

| Field | Type | Default | Notes |
|---|---|---|---|
| `llm_api_key` | password | `""` | **Required.** LLM provider key. |
| `embedding_api_key` | password? | `""` | Optional. Falls back to `llm_api_key`. |
| `llm_provider` | str | `openai` | `openai` for openai-compatible endpoints. |
| `llm_model` | str | `minimax/minimax-m3` | Model id (kilocode gateway in default). |
| `llm_base_url` | str? | `https://api.kilo.ai/api/gateway/v1` | Required for non-OpenAI gateways. |
| `embedding_provider` | str | `openai` | Same as above. |
| `embedding_model` | str | `text-embedding-3-small` | 1536-dim, cheap, good for graph. |
| `embedding_dimensions` | int? | `1536` | Must match the model. |
| `embedding_base_url` | str? | `https://api.kilo.ai/api/gateway/v1` | Same as LLM base URL by default. (v0.1.x field, still used by the `openai` provider and as the v0.2.1 fallback for `embedding_endpoint`.) |
| `embedding_endpoint` | str? | *(empty)* | **v0.2.0** — cognee 1.x variable name. **Required** when `embedding_provider=openai_compatible`. For `openai` provider, leave blank and `embedding_base_url` is used instead. v0.2.1 resolves the endpoint from `embedding_base_url` automatically when this is empty, so existing v0.1.x configs keep working without edits. |
| `cognee_port` | int | `8000` | API listen port. |
| `agent_mode` | bool | `true` | Auto-shutdown when no agent connected. |
| `log_level` | str | `INFO` | `DEBUG`/`INFO`/`WARNING`/`ERROR`. |
| `data_path` | str | `/share/cognee` | Persistent host-bound mount. |

## Recipes

### A. KiloCode gateway + MiniMax (default)

This is the recommended setup. One API key, two endpoints:

```yaml
llm_api_key: <your-kilocode-key>
embedding_api_key: ""  # falls back to llm_api_key

llm_provider: openai
llm_model: minimax/minimax-m3
llm_base_url: https://api.kilo.ai/api/gateway/v1

embedding_provider: openai
embedding_model: text-embedding-3-small
embedding_dimensions: 1536
embedding_base_url: https://api.kilo.ai/api/gateway/v1
```

### B. Voyage AI via `openai_compatible` (v0.2.0+)

LLM stays on Kilo, embeddings go directly to Voyage via cognee's
`openai_compatible` provider. Cognee 1.x talks to any OpenAI-spec
`/v1/embeddings` endpoint with no LiteLLM indirection.

```yaml
llm_api_key: <your-kilocode-key>
embedding_api_key: <your-voyage-key>     # Voyage keys start with `pa-`

llm_provider: openai
llm_model: minimax/minimax-m3
llm_base_url: https://api.kilo.ai/api/gateway/v1

embedding_provider: openai_compatible
embedding_model: voyage-4-large          # 1024-dim default; use voyage-3-large if you want cheaper
embedding_dimensions: 1024
embedding_endpoint: https://api.voyageai.com/v1
# embedding_base_url: leave blank — openai_compatible uses embedding_endpoint
```

After saving, **rebuild the vector index** if you previously had a
different embedding model/dimension (delete `/share/cognee/.data_storage/lancedb_data`).

### B'. Legacy Voyage + OpenAI LLM (v0.1.x recipe — no longer recommended)

Kept for historical reference. The `voyage` provider on cognee 0.3.6
crashed with tiktoken errors; the v0.2.0 recipe above replaces this.

### C. Local Ollama

No cloud calls. Requires the Ollama add-on or external host reachable
from the cognee container.

```yaml
llm_api_key: ollama  # not validated, but must be non-empty
embedding_api_key: ""

llm_provider: ollama
llm_model: llama3.1
llm_base_url: http://homeassistant.local:11434/v1

embedding_provider: ollama
embedding_model: nomic-embed-text
embedding_dimensions: 768
embedding_base_url: http://homeassistant.local:11434/v1
```

## Authentication (v0.2.1)

Cognee 1.x enables multi-tenant + authentication by default, which would
break a single-user hassio-addon (every request gets `401 Unauthorized`
unless a Bearer token is supplied). v0.2.1 bypasses both flags at startup:

```bash
export ENABLE_BACKEND_ACCESS_CONTROL=false
export REQUIRE_AUTHENTICATION=false
```

Both must be set: `REQUIRE_AUTHENTICATION=false` alone is silently
overridden by cognee when backend access control stays on. If you want
multi-tenant + auth, remove these two exports from `rootfs/run.sh` and
configure cognee's auth router manually.

## Architecture

```
Home Assistant host
├── addon: ha-openclaw (alfred)
│   └── @cognee/cognee-openclaw plugin
│        └── COGNEE_BASE_URL=http://cognee:8000
│
├── addon: cognee   ◀── you are here
│   ├── uvicorn → cognee.api.client:app
│   ├── file backends (SQLite + Kuzu + LanceDB)
│   └── /share/cognee ◀── persistent volume
│
└── /share/cognee  (HA's share map, rw)
    ├── .cognee (auth/JWT secret)
    ├── .data    (sqlite, kuzu, lancedb)
    ├── logs
    └── cache
```

**`init: false`** is mandatory — HA Supervisor wraps the container with
its own PID 1 (tini), so adding s6-overlay as PID 1 inside the container
breaks `s6-overlay-suexec` (env vars `UID/EUID/GID/EGID` won't be set
and `addenv()` fails). This pattern is taken from the
[`mlflow-hassio-addon`](https://github.com/WickM/mlflow-hassio-addon)
project.

## Security

- **API keys live in the HA UI**, persisted by HA in
  `addon_data_local/cognee/options.json` (HA's encrypted store).
- **Never commit** API keys to this repo. `.gitignore` blocks `.env`,
  `*.key`, `*.pem`, `secrets.yaml`, `options.json` as defense-in-depth.
- The `10-config` cont-init script writes a non-secret summary to
  `data_path/logs/options.env` for post-mortem debugging.

## Open questions / known gaps

- [ ] **Restart-survival test** — Phase 3 of the plan. Verify `.cognee`
      JWT secret persists across addon restarts.
- [ ] **7-day capacity validation** — Phase 5.
- [ ] **Multi-arch** — currently `amd64` only. Add `aarch64` when a
      Pi-based HA host is in play.
- [ ] **Cognee version pin** — bumped to `1.4.2` in v0.2.0 (LadybugDB as
      graph backend, `openai_compatible` for embeddings). Validate
      `voyage-4-large` embeddings against a fresh vector index before
      shipping further.

## License

MIT — same as the surrounding OpenClaw ecosystem.
