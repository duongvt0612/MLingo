# MLingo Platform Migration Master Plan

**Design:** [Platform design](../../specs/2026-07-15-mlingo-platform-design.md)

**Status:** Milestone 01 complete; Milestone 02 next
**Execution rule:** Complete and verify one milestone before starting the next.

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
