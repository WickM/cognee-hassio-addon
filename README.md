# Cognee Hass.io Add-on

Home Assistant Supervisor add-on that runs the [Cognee](https://github.com/topoteretes/cognee)
graph-memory API server as a sidecar — designed to live next to
[OpenClaw](https://github.com/openclaw/openclaw) or any agent framework.

> **Status:** v0.1.0 — Phase 0/1 (Phase 0 is the file you're looking at).
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
| `embedding_base_url` | str? | `https://api.kilo.ai/api/gateway/v1` | Same as LLM base URL by default. |
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

### B. Voyage AI + OpenAI

If you want high-quality embeddings (voyage-3-large) and a separate
LLM key:

```yaml
llm_api_key: <openai-key>
embedding_api_key: <voyage-key>

llm_provider: openai
llm_model: gpt-4o-mini
# llm_base_url: leave blank (default OpenAI)

embedding_provider: voyage
embedding_model: voyage-3-large
embedding_dimensions: 1024
# embedding_base_url: leave blank (default Voyage)
```

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
- [ ] **Cognee version pin** — currently `0.3.6`. Bump intentionally,
      test before publish.

## License

MIT — same as the surrounding OpenClaw ecosystem.
