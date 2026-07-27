# Model Manager Design

**Status:** Accepted

**Date:** 2026-07-28
**Implements:** [ADR 0003](../adrs/0003-unified-model-storage.md)
**Milestones:** [08a](../plans/2026-07-15-mlingo-platform/08a-model-manager-core.md) core, [08b](../plans/2026-07-15-mlingo-platform/08b-models-catalog-ui.md) UI

## Goal

Give Whisper, LLM, and embedding assets one lifecycle: probe, download, verify, atomically install, load, lease, and delete. Every failure path carries a typed recovery action. Today Whisper is downloaded implicitly by `mlx-audio-swift` at an unpinned revision with no progress or verification, and built-in MLX models require the user to type an absolute path.

## Storage

```
~/Library/Application Support/MLingo/Models/
├── installed.json              # ModelReceiptIndex — the only persisted state
├── installed/<slug>/           # real files, ready for fromDirectory / loadContainer
├── staging/<slug>-<runUUID>/
├── quarantine/<slug>-<runUUID>/
└── hub-cache/                  # MLingo's own HubCache
```

`ModelID` is the logical identifier and may contain `/`. `ModelStorageSlug` is the only value permitted inside a path and is validated against `^[a-z0-9][a-z0-9._-]{0,63}$`. `ModelStorageLayout` accepts only a slug, so a path built from unvalidated data cannot compile.

Only `installed` and `quarantined` are persisted. Every transitional state is in-memory; after a restart an interrupted download is `notInstalled`. Directories are written before receipts: a directory without a receipt is a recoverable orphan, while a receipt without a directory has already handed out a path that does not exist.

## Download

The catalog pins repository and commit SHA. `ModelSnapshotDownloading` is the single seam; the default implementation wraps `HubClient` from swift-huggingface and is the only file that imports `HuggingFace`.

Downloads do not use `downloadSnapshot(to:)`. That parameter copies every file out of the cache, costing twice the model size, and passing `cache: nil` to avoid it throws only after the whole download has completed. Instead the snapshot is fetched into MLingo's own `HubCache`, whose entries are symlinks into `blobs/`. Each entry is hardlinked into staging, verified, and moved into place; the cache repository directory is then removed so the blob link count drops to one. Peak disk is one times the model size.

Byte-range resume is not available: `resumeDownloadFile` has no call site in the package, and the incomplete blob only receives content after a partial response has already been appended. Per-file resume is real — a completed file stays in `blobs/` and is skipped on retry.

`downloadSnapshot` silently falls back to a cached snapshot when the file listing fails, including on 401. Its return value is never trusted; verification always runs afterward.

Hugging Face tokens live in Keychain through the existing `ProviderCredentialStoreProtocol`. `HubClient` is always constructed with an explicit bearer token, never through the default token provider, which would otherwise read `~/.cache/huggingface/token` and make results depend on the developer's machine.

## Verification

Verification runs on staging and never loads MLX. It checks required files exist and are non-empty, at least one `*.safetensors` is present, `config.json` parses, file count and total bytes stay within bounds, no entry is a symlink or escapes the staging root, and optional SHA-256 digests match. Upstream verifies no hashes at all, so this is the only such layer.

`tokenizer.json` is required for speech recognition entries. Without it `WhisperModel.fromDirectory` silently downloads `openai/whisper-large-v3` to obtain a tokenizer, which would mean an unannounced 1.5 GB transfer during a live session.

Catalog entries list exact filenames rather than extension globs. Upstream matches globs with `fnmatch` and no `FNM_PATHNAME`, so `*` crosses `/` and `*.json` would pull in nested files such as `onnx/config.json`.

## Leases and residency

`ModelLeaseRegistry` counts directory usage and refuses deletion while a lease is held. That is necessary but not sufficient: `BuiltInMLXRuntime` keeps weights resident for an idle interval after the last lease is released, and `MLXWhisperEngine` caches its model with no lease and no unload. `LocalModelResidencyReporting` exposes resident directories, a per-directory lease count, and a request to evict, so deletion can wait for memory to actually be released.

The runtime keeps sole authority over RAM. Model Manager never loads MLX, never warms a model, and its preflight covers disk only.

## Engine integration

`WhisperEngineProtocol` is unchanged. `MLXAudioWhisperBackend` gains an optional `ModelDirectoryResolving`; when it resolves an installed directory the backend uses `WhisperModel.fromDirectory`, otherwise it falls back to `fromPretrained` exactly as before. Existing installations therefore keep working offline, and no test double changes.

Built-in MLX profiles continue to store an absolute path in `CapabilitySelection.model`. `UserDefaultsProviderProfileStore` validates on load and throws on anything it cannot resolve, so changing the stored format without migration would discard a user's provider configuration at launch. When identifiers replace paths, they arrive as a `mlingo-model://<id>` scheme handled where `BuiltInMLXRuntime` already classifies URL schemes.

## Progress

Model Manager exposes `snapshot()` and an `AsyncStream` with `bufferingNewest(1)`, which coalesces, applies no backpressure, and replays the latest value to late subscribers. `TypedEventHub` is deliberately not used: it requires a session identifier, never replays history, suspends the publisher when a durable subscription fills, and is instantiated per `SessionOrchestrator`.

Upstream delivers progress on the main actor and polls every 100 ms. Updates are throttled, guarded to be monotonic, and tagged with a run identifier so a late callback cannot revive a finished download.

## Testing

The default suite is fully offline and proves it: a `URLProtocol` spy asserts zero requests across the whole happy path. Real downloads run only under `MLINGO_RUN_MODEL_DOWNLOAD_TESTS=1`, and a missing companion variable throws rather than skipping silently.

`ModelManager` takes every dependency through its initializer. A shared instance exists only where the app is composed, because tests that touch it would write to the real Application Support directory and leak state between runs — `--no-parallel` prevents interference within a run, not across runs.

## Out of scope

Custom Hugging Face repositories and their compatibility probe, custom storage folders and security-scoped bookmarks, importing models already present in the shared Hugging Face cache, byte-range resume, and TTS catalog entries.
