# MLingo Platform Migration Design

**Status:** Accepted

**Date:** 2026-07-15
**Target:** macOS 14+, Apple Silicon, Swift 6.3

## Goal

Replace the monolithic `SubtitlePipeline` with a capability-first, event-driven platform while preserving the current capture, local Whisper, translation, overlay, diagnostics, and restart behavior.

```text
Audio -> Speech Recognition -> Typed Event Hub
                              |-> Translation
                              |-> Subtitles
                              |-> Session Recording
                              |-> Knowledge
                              |-> TTS
                              `-> AI Companion
```

Raw audio stays on the session-local execution path. The global hub carries immutable facts, never commands. Start, stop, overlay, and model-download commands call services directly.

## Provider boundary

`ModelCapability` contains speech recognition, translation, chat, embedding, and text-to-speech. Each capability has a narrow provider protocol. `ProviderRegistry` resolves an explicit profile and model for a capability and returns a typed error with a recovery action if resolution fails. It never silently falls back.

A `ProviderProfile` stores provider kind, endpoint, API style, authentication reference, and model identifiers by capability. Secrets live only in Keychain and are addressed by credential ID. Remote hosts require HTTPS; HTTP is allowed only for loopback. Authentication v1 supports none, bearer, and one custom secret header.

Remote providers support OpenAI-compatible Responses and Chat Completions APIs. Local providers can be OpenAI-compatible servers such as Ollama or LM Studio, or built-in actor-isolated MLX providers. Capability selections are independent, so speech recognition, translation, chat, embedding, and TTS may use different profiles and models.

## Event and session runtime

Every event is wrapped in an `EventEnvelope` containing event ID, session ID, sequence, timestamp, and trace ID. Typed realtime subscriptions use bounded mailboxes and explicit drop-oldest or coalescing policies. Durable subscriptions suspend when full and never drop. Subscriber failure and cancellation are isolated.

`SessionOrchestrator` owns start/stop, capture, audio windowing, recognizer lifecycle, worker cancellation, and stale-session rejection. Translation consumes completed transcript units and publishes only completed translations. Internal provider streaming may measure time-to-first-token but draft revisions never reach overlay or TTS.

## Models and persistence

`ModelManager` manages Whisper, LLM, embedding, and TTS assets through probe, queued, downloading, verifying, installed, loading, ready, and failed states. Bundled catalog entries pin repository and revision; custom Hugging Face models require a compatibility probe. Tokens and gated access credentials live in Keychain. Storage defaults to Application Support; custom folders use persisted security-scoped bookmarks.

SwiftData is canonical for opt-in recorded sessions, transcripts, translations, bookmarks, vocabulary, notes, and saved companion artifacts. Raw audio, credentials, and endpoint secrets are never persisted or exported. Embeddings are derived, model-scoped data that can be deleted and rebuilt. Remote embeddings require per-profile explicit consent.

## User experience

Settings uses a native SwiftUI sidebar with General, Audio & Speech, AI Providers, Models, Translation, Subtitles, Appearance, and Privacy destinations. Provider editing is transactional and secrets are always masked. Model operations expose progress, cancellation, retry, verification, and recovery using native controls, semantic colors, keyboard navigation, VoiceOver, and reduced-motion behavior.

TTS first ships through `AVSpeechSynthesizer`, then remote and built-in providers. It consumes completed translations in order, cancels by session, and uses a separate output path. Ducking is opt-in and must restore system state after success, stop, or error.

## Privacy and distribution

Recording is off by default and retained until explicit deletion. AI Companion sends only the scope selected by the user and persists nothing until Save. Remote destinations remain visible at the point of use. There is no local-to-cloud fallback.

Direct distribution keeps App Sandbox disabled, enables Hardened Runtime, and grants only the MLX JIT exception required in Release. Nested code is Developer ID signed, notarized, and stapled. Sparkle is introduced only after the first notarized release. Dynamic third-party code, voice cloning, OCR, and Vision Pro remain post-v1.

## Delivery discipline

Each runtime task starts with a targeted failing test, confirms the failure, adds the smallest implementation, then reruns targeted and milestone gates. Default tests remain offline and deterministic. Network, paid API, model download, TCC, hardware TTS, and notarization tests are opt-in.
