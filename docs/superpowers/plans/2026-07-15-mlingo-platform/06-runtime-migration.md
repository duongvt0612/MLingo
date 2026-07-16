# Milestone 06: Runtime Migration and Feature Parity

**Outcome:** `SessionOrchestrator` replaces `SubtitlePipeline` while preserving every current user flow.

**Status:** Complete on 2026-07-16 from clean M05 merge-equivalent commit `e0b6a37`.
The audited pre-migration baseline is 285 tests, a passing SwiftPM Release build, and a
clean whitespace check. The owner explicitly allows M06 to proceed while M04 manual
accessibility acceptance remains pending; that waiver does not mark any M04 manual item
as passed. GitNexus cannot parse the repository's Swift sources, so its impact result is
`UNKNOWN`; direct reference audits and runtime characterization tests are the authoritative
blast-radius evidence for this migration.

## Tasks

- [x] Add characterization tests for start/stop/restart, capture failure, Whisper preparation, stale callbacks, translation ordering, overlay updates, and diagnostics.
- [x] Implement `SessionOrchestrator` for command handling, capture ownership, audio windowing, recognizer lifecycle, and session cancellation.
- [x] Keep raw audio on direct session-local calls; publish transcript facts only after recognition.
- [x] Extract `TranslationWorker`, original subtitle sink, translated subtitle sink, and diagnostics subscriber behind testable boundaries.
- [x] Move performance trace identifiers and timestamps into event metadata without logging user content.
- [x] Add an internal runtime seam and run old/new paths against identical deterministic fixtures.
- [x] Switch app composition to the new runtime after parity tests pass.
- [x] Delete `SubtitlePipeline` and obsolete tests only after no production reference remains.

## Acceptance

- Capture -> Whisper -> remote translation -> overlay passes end to end.
- Sound test, transcription test, stop/restart, cancellation, and diagnostics match or improve current behavior.
- Old-session callbacks cannot mutate the active session.
- Repository search finds no `SubtitlePipeline` production usage.

## Completion evidence

- The public `SessionRuntimeProtocol` seam is live in `MLingoViewModel`; live composition
  creates `SessionOrchestrator`. Sound Test remains ViewModel-local and its focused isolation
  regression confirms it never starts or stops the session runtime.
- The original 17 deterministic runtime characterization cases were run against the old
  implementation before cutover and then migrated as permanent orchestrator contracts. The
  focused final gates pass: 1 `SessionRuntimeContract`, 22 `SessionOrchestrator`, 3
  `TranslationWorkerTests` cases (including active-item discard after cancelled success or
  failure), and 3 `MLingoViewModelRuntime` tests. The broader `TranslationWorker` filter reports
  4 because it also matches `stoppedTranslationWorkerIgnoresLateResponse` in the orchestrator
  suite.
- Lifecycle facts are session-scoped and ordered. `SessionStarted` is published only after
  Whisper and audio startup succeed; transcript and translation facts share the Whisper trace;
  cancelled stop publishes `SessionEnded(.cancelled)`; startup failure publishes no fake
  lifecycle fact. Hub publication failure is classified as fatal.
- `SessionTranscriptRouter` delivers the original transcript sink before submitting to the
  actor-owned `TranslationWorker`. Context-two, adjacent dedupe, maximum-eight/drop-oldest,
  permanent-error pause, non-blocking transcript delivery, blocked-provider cancellation and
  stale-result rejection all pass. `TranslatedSubtitleSink` owns ordered overlay rendering.
- Audio chunks, audio/Whisper diagnostics, commands, secrets and draft translation never enter
  event payloads. `SessionDiagnosticsSubscriber` keeps diagnostics on the direct session-local
  path and preserves the final performance snapshot after stop.
- The offline end-to-end fixture passes through fake audio, scripted Whisper,
  `ProviderTranslationEngine`, scripted OpenAI-compatible HTTP transport, typed events and fake
  overlay without network, paid provider, hardware or TCC access.
- Final validation: 297/297 tests pass; SwiftPM Release passes with only the classified upstream
  MLXAudioVAD README resource warning; native arm64 Release archive and strict ad-hoc signature
  validation pass; `git diff --check` passes; repository cleanup search returns no
  `SubtitlePipeline` or `SubtitlePipelineMode` match under `Sources/` or `Tests/`.
- GitNexus was refreshed after implementation and reports 440 nodes/457 edges, but explicitly
  skips 120 Swift files because the Swift parser is unavailable. Its change detector therefore
  sees only documentation symbols; the Swift blast radius was audited directly and covered by
  the focused/full/native gates above.
