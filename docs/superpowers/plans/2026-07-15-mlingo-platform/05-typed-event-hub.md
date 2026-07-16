# Milestone 05: Typed Event Hub

**Status:** Complete as of 2026-07-16. Milestone 04's
manual accessibility acceptance remains pending, and the owner has explicitly waived
that gate only to allow Milestone 05 to proceed. The unchecked M04 items are not treated
as passed.

**Outcome:** A standalone event hub provides explicit typed delivery semantics before any runtime migration.

## Scope audit

| Requirement | Result | Evidence |
|---|---|---|
| Standalone typed core | Verified | `Sources/MLingoCore/Events/` contains the envelope, immutable facts, and actor-managed hub. No runtime owner imports or integration were added. |
| Metadata and routing | Verified | Deterministic tests cover injected clock/IDs, per-session cross-type sequence, root and propagated traces, exact concrete-type routing, session scope, and no replay. |
| Realtime semantics | Verified | A gated slow-subscriber test proves capacity 2 with drop-oldest delivers sequences `1, 4, 5`; coalescing preserves incoming envelope metadata and exposes overflow metrics. |
| Durable semantics | Verified | Capacity-1 tests prove the third publisher suspends, producers resume in sequence order, and delivery remains lossless. Durable means in-process backpressure only, not disk persistence or crash recovery. |
| Failure and cancellation isolation | Verified | Tests cover handler throw, idempotent cancel, cancel-vs-publish, shutdown-vs-backpressure, queue discard, cooperative handler cancellation, and unaffected peer subscriptions. |
| Initial event facts | Verified | Only `SessionStarted`, `SessionEnded`, `TranscriptCompleted`, and `TranslationCompleted` were added. Raw audio, commands, secrets, and draft translation are excluded. |
| Runtime migration | Not applicable | Milestone 06 owns `SessionOrchestrator` integration and replacement of `SubtitlePipeline`; M05 does not modify the current pipeline. |
| UI/UX and accessibility | Not applicable | M05 has no user-facing surface. Observability is exposed through typed subscription metrics. |

## Tasks

- [x] Add failing tests for envelope metadata, per-session sequence, trace propagation, and typed subscription filtering.
- [x] Implement `EventEnvelope<Event>`, session/trace identifiers, clock/ID seams, and subscription tokens.
- [x] Add gated stress tests for realtime drop-oldest and coalescing policies under slow subscribers.
- [x] Implement bounded realtime mailboxes with observable overflow metrics.
- [x] Add tests proving durable mailboxes suspend producers, preserve order, and never drop.
- [x] Implement durable subscription backpressure and cancellation-safe teardown.
- [x] Define session lifecycle, transcript, and translation facts.
- [x] Test subscriber failure isolation, cancellation races, stale/cross-session filtering, and shutdown races.
- [x] Pass the focused filters, full Swift test suite, Release build, whitespace check, and unchanged-pipeline diff gate.

## Acceptance

- [x] Realtime overflow follows the selected policy deterministically.
- [x] Durable delivery is ordered and lossless under backpressure.
- [x] Sequence, trace, event type, and session filtering are deterministic.
- [x] One subscriber failure or cancellation cannot terminate other subscriptions.
- [x] No raw audio, commands, persistence, runtime migration, UI, or package dependency was added.
- [x] `SubtitlePipeline` remains unchanged and all final validation gates pass.

## Validation evidence

- Starting baseline at `31fadb1`: `rtk swift test --no-parallel` passed 268 tests.
- Focused implementation tests: 2 `EventEnvelope`, 1 `EventFacts`, and 14
  `TypedEventHub` tests pass without timing sleeps or polling.
- Final `rtk swift test --no-parallel`: 285 tests pass.
- `rtk swift build -c release` passes with only the previously classified upstream
  MLXAudioVAD README resource warning.
- `rtk git diff --check` and the explicit unchanged-`SubtitlePipeline.swift` diff gate pass.
- A native Xcode archive is not required: M05 adds only SwiftPM-auto-discovered
  `MLingoCore` source and tests, with no dependency, resource, entitlement, or project
  membership change.
