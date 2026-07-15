# Milestone 13: AI TTS Providers

**Outcome:** Remote and built-in AI voices can replace system TTS through capability selection alone.

## Tasks

- [ ] Add OpenAI-compatible audio-speech request/response fixtures, auth redaction, cancellation, and typed error mapping.
- [ ] Implement the remote audio-speech adapter without changing session orchestration.
- [ ] Add local MLXAudioTTS loading, synthesis, lease, cancellation, and offline-network tests.
- [ ] Register TTS models with Model Manager and surface gated/storage/runtime failures consistently.
- [ ] Add voice profiles, bounded synthesis queue, session-scoped short-lived audio cache, and cache privacy tests.
- [ ] Record queue, synthesis, and playback latency diagnostics without retaining translated audio after expiry.
- [ ] Verify switching among system, remote, and local profiles changes only capability selection.

## Acceptance

- All three TTS implementations pass one provider contract suite.
- Remote secrets and synthesized content are absent from diagnostics by default.
- Local installed-model synthesis works offline.
- Voice cloning remains absent from UI, protocols, and model catalog.
