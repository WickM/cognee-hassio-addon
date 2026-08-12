# Changelog

All notable changes to this add-on are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
