# Milestone 06: Runtime Migration and Feature Parity

**Outcome:** `SessionOrchestrator` replaces `SubtitlePipeline` while preserving every current user flow.

## Tasks

- [ ] Add characterization tests for start/stop/restart, capture failure, Whisper preparation, stale callbacks, translation ordering, overlay updates, and diagnostics.
- [ ] Implement `SessionOrchestrator` for command handling, capture ownership, audio windowing, recognizer lifecycle, and session cancellation.
- [ ] Keep raw audio on direct session-local calls; publish transcript facts only after recognition.
- [ ] Extract `TranslationWorker`, original subtitle sink, translated subtitle sink, and diagnostics subscriber behind testable boundaries.
- [ ] Move performance trace identifiers and timestamps into event metadata without logging user content.
- [ ] Add an internal runtime seam and run old/new paths against identical deterministic fixtures.
- [ ] Switch app composition to the new runtime after parity tests pass.
- [ ] Delete `SubtitlePipeline` and obsolete tests only after no production reference remains.

## Acceptance

- Capture -> Whisper -> remote translation -> overlay passes end to end.
- Sound test, transcription test, stop/restart, cancellation, and diagnostics match or improve current behavior.
- Old-session callbacks cannot mutate the active session.
- Repository search finds no `SubtitlePipeline` production usage.
