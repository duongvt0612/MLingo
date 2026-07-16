# MLingo Platform Migration Master Plan

**Design:** [Platform design](../../specs/2026-07-15-mlingo-platform-design.md)

**Status:** Milestones 01-02 and 05-06 complete; Milestone 03 implementation complete with its
loopback live proof deferred by owner waiver; Milestone 04 code-complete with manual
accessibility acceptance pending; Milestone 06 started.
**Execution rule:** Complete and verify one milestone before starting the next. The owner
has explicitly waived the external loopback proof for Milestone 03 until Ollama or LM
Studio is installed. The owner has also explicitly allowed Milestones 05 and 06 to start
while Milestone 04's manual accessibility acceptance remains pending. Neither waived gate
is treated as passed.

## Locked decisions

- Product name is MLingo.
- Provider and model selection is independent per capability.
- Remote OpenAI-compatible and built-in MLX runtimes coexist.
- No silent fallback between local and cloud providers.
- Raw audio never enters the global event hub and is never persisted.
- Translation overlay and TTS consume complete sentences only.
- Recording and remote embeddings are explicit opt-ins.
- Model Manager owns speech, language, embedding, and TTS models.
- Direct distribution is signed and notarized; Sparkle follows the first notarized release.

## Milestones

| # | Milestone | Independent acceptance gate |
|---|---|---|
| 01 | [Baseline and ADRs](01-baseline-and-adrs.md) | Documentation-only diff; current runtime remains green |
| 02 | [AI Capability Core](02-ai-capability-core.md) | Existing OpenAI translation behavior preserved through provider abstraction |
| 03 | [Remote OpenAI-Compatible Providers](03-remote-openai-compatible.md) | Same fixture succeeds via Responses and Chat Completions transports |
| 04 | [Provider Settings UX](04-provider-settings-ux.md) | Transactional, accessible profile and capability settings |
| 05 | [Typed Event Hub](05-typed-event-hub.md) | Ordering, overflow, isolation, and durable backpressure proven |
| 06 | [Runtime Migration](06-runtime-migration.md) | New orchestrator reaches feature parity and old pipeline is removed |
| 07 | [Built-in MLX Runtime](07-built-in-mlx-runtime.md) | Installed local model translates and chats offline |
| 08 | [Unified Model Manager](08-unified-model-manager.md) | Clean-cache lifecycle and failure recovery pass |
| 09 | [Translation Quality](09-translation-quality.md) | Atomic, ordered translation meets recorded quality and latency gates |
| 10 | [Opt-in Session Recording](10-session-recording.md) | Only opted-in sessions persist; export contains no secrets/audio |
| 11 | [Knowledge Engine](11-knowledge-engine.md) | Offline semantic search and vector-space isolation pass |
| 12 | [Live TTS Foundation](12-live-tts-foundation.md) | System voice is ordered, session-safe, and provider-independent |
| 13 | [AI TTS Providers](13-ai-tts-providers.md) | System, remote, and local TTS switch through capability selection |
| 14 | [AI Companion](14-ai-companion.md) | Explicit context and save-only persistence are enforced |
| 15 | [Signed Distribution](15-signed-distribution.md) | Signing, notarization, clean-machine runtime and downloads pass |
| 16 | [Sparkle Auto-update](16-sparkle-auto-update.md) | Signed N to N+1 update preserves user state |
| 17 | [Extension Readiness](17-extension-readiness.md) | Sample compile-time mode needs no provider/event-core changes |

## Gate required after every milestone

```bash
rtk swift test --no-parallel
rtk swift build -c release
rtk git diff --check
```

Run a native Xcode Release build whenever a dependency, resource, entitlement, signing setting, or distribution path changes. External-network, paid API, model download, TCC, audio hardware, and notarization checks are opt-in and must be explicitly labeled.

## Status log

- 2026-07-15: Milestone 01 complete. Baseline: 175 tests pass, Release build passes with one classified upstream MLXAudioVAD README resource warning, and documentation diff/whitespace checks pass.
- 2026-07-15: Milestone 02 complete. Capability protocols, explicit provider profiles, no-fallback registry resolution, profile/Keychain stores, OpenAI adapter, and idempotent legacy migration are live. Full suite: 191 tests pass; Release build and diff checks pass.
- 2026-07-15: Milestone 03 transport core landed (Responses + Chat Completions, presets, auth modes, connection probe). Full suite: 217 tests pass. **Not acceptance-complete** (see later log entries).
- 2026-07-15: Milestone 03 review fixes. Migration no longer overwrites non-OpenAI selections; none-auth profiles can start without an API key; live suites require `MLINGO_RUN_LIVE_PROVIDER_TESTS=1`; provider error copy is neutral; added cancellation, migration, and local-profile integration coverage. Full suite: 222 tests pass.
- 2026-07-15: Milestone 03 follow-up. Start resolves the selected profile's CredentialID; `preparingTranslation` is stoppable; quota recovery is OpenAI-only; loopback live gate unchecked; checklist matches HTTPClient fixtures. Full suite: 225 tests pass.
- 2026-07-15: Milestone 03 still open. Preflight errors no longer leave stale Stop recovery; privacy copy uses resolved destination; transport sanitizes `x-request-id` via redactor; master status corrected to in-progress.
- 2026-07-16: Milestone 03 implementation is code-complete. The production logging audit and redactor tests confirm request bodies, user text, bearer secrets, custom-header secrets, and unsafe request IDs are not emitted by default. The real loopback integration proof remains unchecked and deferred because neither Ollama nor LM Studio is installed. By explicit owner waiver, Milestone 04 may start without representing that external proof as passed.
- 2026-07-16: Milestone 04 started. Work is scoped to transactional provider settings, independent capability assignments, native macOS Settings navigation, and accessibility acceptance.
- 2026-07-16: Milestone 04 implementation is code-complete. Native eight-destination Settings, transactional provider/profile/Keychain persistence, draft connection probing, independent capability assignments, provider-based runtime readiness, deterministic validation/focus routing, and rollback recovery are implemented. Audit found four M04 files missing from the Xcode application target even though SwiftPM passed; project membership is fixed and guarded by a source-membership regression. The offline suite now passes 268 tests; SwiftPM Release build, native Release archive/signature validation, and diff checks pass. Native accessibility-tree and partial appearance/transaction evidence is recorded in the milestone file, but full VoiceOver, keyboard-only, largest-text, reduced-motion, Dark reopen, and fake-credential smoke acceptance remains unchecked, so Milestone 04 is not yet marked complete.
- 2026-07-16: By explicit owner waiver, Milestone 05 started while Milestone 04 remains code-complete/manual-pending; the remaining M04 manual checks stay unchecked. M05 is scoped to a standalone actor-managed typed event hub in `MLingoCore`, with no runtime migration, UI, persistence, dependency, or `SubtitlePipeline` change.
- 2026-07-16: Milestone 05 complete. Immutable typed envelopes and four initial facts, per-session sequence and trace metadata, exact type/session routing, bounded realtime drop-oldest/coalescing, lossless durable backpressure, typed metrics, handler-failure isolation, idempotent cancellation, and shutdown race handling are implemented in standalone `MLingoCore`. Focused tests pass (2 EventEnvelope, 14 TypedEventHub, 1 EventFacts); the full suite passes 285 tests, Release build passes with the classified upstream MLXAudioVAD README warning, and whitespace plus unchanged-`SubtitlePipeline.swift` gates pass. M04's manual acceptance remains pending under the recorded owner waiver.
- 2026-07-16: By explicit owner waiver, Milestone 06 started while Milestone 04 remains code-complete/manual-pending; no M04 manual item is represented as passed. The clean starting point is M05 merge-equivalent commit `e0b6a37`; the audited baseline remains 285 tests with passing Release and whitespace gates. GitNexus reports `UNKNOWN` impact because its parser skips Swift, so M06 uses direct source-reference auditing and parity contracts for the high-risk runtime cutover.
- 2026-07-16: Milestone 06 complete. `MLingoViewModel` now depends on `SessionRuntimeProtocol` and live composition uses the event-driven `SessionOrchestrator`. Session-scoped lifecycle/transcript/translation facts preserve ordering and Whisper trace metadata; raw audio and diagnostics remain direct; actor-owned translation retains context-two, dedupe, bounded drop-oldest, permanent-error pause and stale-result rejection; Sound Test remains isolated. The old runtime types and obsolete tests are removed. Focused runtime gates and the offline scripted-provider end-to-end fixture pass; the full suite passes 293 tests; SwiftPM Release, native arm64 archive/signature, whitespace and legacy-symbol cleanup gates pass. GitNexus was refreshed but still skips Swift (120 files), so direct diff/reference auditing remains the authoritative blast-radius evidence. M04 manual accessibility acceptance remains pending under the owner waiver.
