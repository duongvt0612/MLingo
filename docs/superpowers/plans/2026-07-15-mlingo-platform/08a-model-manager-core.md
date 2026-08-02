# Milestone 08a: Model Manager Core

**Outcome:** Whisper, LLM, and embedding assets share one headless downloadable lifecycle with typed recovery, proven entirely offline.

**Design:** [Model Manager design](../../specs/2026-07-28-model-manager-design.md)

**Scope:** production code is confined to `Sources/MLingoCore` — no UI, no `Sources/MLingoApp`
change, and therefore no `MLingo.xcodeproj` change. Tests and documentation change as the tasks
and acceptance criteria below require.

## Tasks

- [x] Add shared async test support (`eventually`, temporary directory, call counter) for new suites only.
- [x] Add `ModelStoreError` with a recovery action per issue, a `models` logger category, and `PersistenceBackend.fileSystem`.
- [x] Add `ModelStorageSlug` validation and a `ModelStorageLayout` that accepts only slugs and asserts containment.
- [x] Define a bundled catalog of three entries pinned to repository and commit SHA, listing exact filenames rather than extension globs.
- [x] Add a file-backed receipt index with atomic writes, repair-on-load, and schema versioning.
- [x] Add a lease registry that counts directory usage per model and releases idempotently.
- [x] Add the `ModelSnapshotDownloading` seam and a scripted fake that records requests, progress, and cancellation.
- [x] Add manifest and digest verification: required files, safetensors presence, parseable config, bounded file count and size, no symlink or root escape, optional SHA-256.
- [x] Add an installer that hardlinks snapshot entries into staging, swaps atomically into place, quarantines failures, and deletes safely.
- [x] Add storage accounting per bucket and a disk preflight with headroom.
- [x] Implement `ModelManager`: state machine, single-slot queue, cancellation, reconciliation, and a coalescing snapshot stream.
- [x] Add Keychain-backed Hugging Face tokens with actionable 401 and gated-license recovery, and prove the token never reaches the receipt index or the environment.
- [x] Implement `HubModelSnapshotDownloader` with explicit bearer-token construction and typed error mapping.
- [x] Add residency reporting and eviction so deletion cannot race the runtime's idle unload window.
- [x] Add the Whisper directory-resolver seam without changing `WhisperEngineProtocol` or any existing initializer.
- [x] Add the opt-in real-download suite and a default-suite proof that no network request occurs.

## Acceptance

- [x] Clean store: download → verify → install → restart reuse → delete passes.
- [x] Corruption, disk exhaustion, gated access, 401, cancellation, and deletion while leased each have a test and a recovery action.
- [x] Model identifiers and revisions survive restart without storing tokens in preferences.
- [x] The default suite makes zero network requests, proven by a `URLProtocol` spy.
- [x] The existing suite stays green with no test double or protocol signature changed.

## Recorded 2026-07-28

- `swift test --no-parallel`: **433 tests pass**, up from the 310 baseline. Repeated clean runs
  and one run under saturating CPU load all passed.
- `swift build -c release`: passes with the one classified upstream MLXAudioVAD README warning.
- `git diff --check`: clean.
- Offline proof: `theDefaultModelStoreSuiteMakesNoNetworkRequest` runs install, snapshot, lease,
  resolve, delete and reconcile with a `URLProtocol` spy registered and records zero requests.
- Real download gate, `MLINGO_RUN_MODEL_DOWNLOAD_TESTS=1`: the whisper-base cycle passed in
  37.5s — download, verify, hardlink install, restart reuse, cache purge, delete. Storage
  accounting confirmed the model is held once rather than twice, and a request for an unknown
  revision mapped to `repositoryNotFound` against the live API.
- Milestone 07's twelve `BuiltInMLX` tests pass unchanged; the residency conformance added no
  edits to existing lines.
- `./scripts/build-local-rc.sh` was not required: no dependency, resource, entitlement, or
  `Sources/MLingoApp` file changed, so `MLingo.xcodeproj` is untouched.

One intermittent failure was seen once, in `typedEventHubSerializesConcurrentPublishersByAssignedSequence`
and `typedEventHubCancelPublishRaceDoesNotDisturbOtherSubscription`. Both belong to Milestone 05
and were not modified here. They passed on every subsequent attempt — three in isolation, four
full-suite runs including one under saturating load — so the cause was not reproduced and is
recorded rather than explained.

## Deliberate non-goals

Byte-range resume is not available: `resumeDownloadFile` has no call site in swift-huggingface 0.9.0, and the incomplete blob only receives content after a partial response has already been appended. Cancellation therefore restarts a file from zero. Per-file resume is real and is what the retry test asserts.

Custom Hugging Face repositories, compatibility probing, custom storage folders, security-scoped bookmarks, importing models from the shared Hugging Face cache, and TTS catalog entries are all out of scope.
