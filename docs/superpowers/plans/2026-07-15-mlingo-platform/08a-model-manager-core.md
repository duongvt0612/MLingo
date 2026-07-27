# Milestone 08a: Model Manager Core

**Outcome:** Whisper, LLM, and embedding assets share one headless downloadable lifecycle with typed recovery, proven entirely offline.

**Design:** [Model Manager design](../../specs/2026-07-28-model-manager-design.md)

**Scope:** `Sources/MLingoCore` only. No UI, no `Sources/MLingoApp` change, no `MLingo.xcodeproj` change.

## Tasks

- [ ] Add shared async test support (`eventually`, temporary directory, call counter) for new suites only.
- [ ] Add `ModelStoreError` with a recovery action per issue, a `models` logger category, and `PersistenceBackend.fileSystem`.
- [ ] Add `ModelStorageSlug` validation and a `ModelStorageLayout` that accepts only slugs and asserts containment.
- [ ] Define a bundled catalog of three entries pinned to repository and commit SHA, listing exact filenames rather than extension globs.
- [ ] Add a file-backed receipt index with atomic writes, repair-on-load, and schema versioning.
- [ ] Add a lease registry that counts directory usage per model and releases idempotently.
- [ ] Add the `ModelSnapshotDownloading` seam and a scripted fake that records requests, progress, and cancellation.
- [ ] Add manifest and digest verification: required files, safetensors presence, parseable config, bounded file count and size, no symlink or root escape, optional SHA-256.
- [ ] Add an installer that hardlinks snapshot entries into staging, swaps atomically into place, quarantines failures, and deletes safely.
- [ ] Add storage accounting per bucket and a disk preflight with headroom.
- [ ] Implement `ModelManager`: state machine, single-slot queue, cancellation, reconciliation, and a coalescing snapshot stream.
- [ ] Add Keychain-backed Hugging Face tokens with actionable 401 and gated-license recovery, and prove the token never reaches the receipt index or the environment.
- [ ] Implement `HubModelSnapshotDownloader` with explicit bearer-token construction and typed error mapping.
- [ ] Add residency reporting and eviction so deletion cannot race the runtime's idle unload window.
- [ ] Add the Whisper directory-resolver seam without changing `WhisperEngineProtocol` or any existing initializer.
- [ ] Add the opt-in real-download suite and a default-suite proof that no network request occurs.

## Acceptance

- [ ] Clean store: download → verify → install → restart reuse → delete passes.
- [ ] Corruption, disk exhaustion, gated access, 401, cancellation, and deletion while leased each have a test and a recovery action.
- [ ] Model identifiers and revisions survive restart without storing tokens in preferences.
- [ ] The default suite makes zero network requests, proven by a `URLProtocol` spy.
- [ ] The existing suite stays green with no test double or protocol signature changed.

## Deliberate non-goals

Byte-range resume is not available: `resumeDownloadFile` has no call site in swift-huggingface 0.9.0, and the incomplete blob only receives content after a partial response has already been appended. Cancellation therefore restarts a file from zero. Per-file resume is real and is what the retry test asserts.

Custom Hugging Face repositories, compatibility probing, custom storage folders, security-scoped bookmarks, importing models from the shared Hugging Face cache, and TTS catalog entries are all out of scope.
