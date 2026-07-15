# Milestone 12: Live TTS Foundation

**Outcome:** macOS system voices speak completed translations in order without coupling TTS to translation internals.

## Tasks

- [ ] Add provider and queue tests for ordering, deduplication, stale sessions, cancellation, stop/restart, and incomplete translations.
- [ ] Implement `AVSpeechSynthesizer` behind `TTSProvider` with actor-isolated delegate bridging.
- [ ] Subscribe TTS to completed translation facts and maintain a bounded synthesis/playback queue.
- [ ] Add voice, rate, volume, enablement, and output controls with unavailable-voice recovery.
- [ ] Keep translated speech on an isolated output path; default ducking to off.
- [ ] If ducking is enabled, test and implement restoration after normal completion, cancellation, stop, and every error path.
- [ ] Add opt-in hardware acceptance tests while keeping default tests synthesizer-free and deterministic.

## Acceptance

- System TTS works without an API key or model download.
- TTS never speaks duplicates, drafts, or stale-session translations.
- Stopping a session cancels pending speech and prevents later delegate callbacks from resuming it.
- Output/ducking state is restored after all termination paths.
