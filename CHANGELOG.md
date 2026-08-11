# Changelog

All notable changes to this add-on are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
- [ ] Cognee API module path verified — `cognee.api.client:app` is the
      current convention; double-check against the installed version.

## [0.1.1] - 2026-08-08

### Fixed

- bashio bootstrap: shebang `#!/usr/bin/bashio` (absolute path) + explicit
  `source /usr/bin/bashio` in `10-config` and `run.sh` — bashio library
  should be loaded into the script shell before `bashio::config` calls.

### Added

- `_bashio_config()` helper with jq fallback to `/data/options.json`.
- `declare -F` guards on `bashio::exit.nok` and `bashio::log.warning`.

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

## v0.1.3 — 2026-08-11

### Fixed
- **Persistence bug**: cognee 0.3.6 was writing to `.cognee_system/` etc. *inside*
  the container image (i.e. `/usr/local/lib/python3.11/site-packages/cognee/.cognee_system/`),
  not the persistent `/share/cognee/` mount. Restart-survival was broken.
- **Root cause**: my run.sh set `HOME=$DATA_PATH` hoping cognee would discover the
  mount from cwd/env, but cognee 0.3.x ignores cwd. It reads three explicit env vars
  via pydantic-settings (see `cognee/base_config.py`):
  - `SYSTEM_ROOT_DIRECTORY` → sqlite metadata
  - `DATA_ROOT_DIRECTORY`   → lancedb vector store
  - `CACHE_ROOT_DIRECTORY`  → caches
- **Fix**: run.sh now exports these three with absolute paths under `/share/cognee/`.
  10-config now also creates the matching subdirs (`.cognee_system`, `.data_storage`,
  `.cognee_cache`) and exports the env vars so the s6 service inherits them.
- **Defensive**: run.sh `mkdir -p`s the dirs in case 10-config didn't run.

### What you'll see in HA logs after update
```
[10-config] data dir ready: drwxrwxrwx ... /share/cognee
[run.sh] SYSTEM_ROOT_DIRECTORY=/share/cognee/.cognee_system
[run.sh] DATA_ROOT_DIRECTORY=/share/cognee/.data_storage
[run.sh] CACHE_ROOT_DIRECTORY=/share/cognee/.cognee_cache
[info] Database storage: /share/cognee/.cognee_system/databases   ← was image-path before
```
