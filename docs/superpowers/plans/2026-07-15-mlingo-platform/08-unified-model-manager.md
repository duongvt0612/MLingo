# Milestone 08: Unified Model Manager

**Outcome:** Whisper, LLM, embedding, and TTS assets share a safe downloadable lifecycle and native management UI.

## Tasks

- [ ] Define a bundled, revision-pinned catalog for current Whisper, Qwen3 0.6B/1.7B/4B 4-bit, and multilingual embedding models.
- [ ] Add failing state-machine tests for probe, queue, download, verification, install, load, ready, failure, retry, and restart reuse.
- [ ] Implement resumable downloads, integrity/manifest verification, atomic install, cancellation, and bounded concurrent work.
- [ ] Add Keychain-backed Hugging Face tokens and actionable 401/gated-license recovery.
- [ ] Implement custom repository/revision compatibility probes and reject path traversal or unsafe manifests.
- [ ] Add Application Support storage plus persisted security-scoped bookmark storage and lost-folder recovery.
- [ ] Add disk/RAM preflight, corrupt-file quarantine, deletion guards while leased, and cache accounting.
- [ ] Build the Models catalog UI with progress, cancel, retry, delete, status, keyboard, VoiceOver, and reduced-motion support.

## Acceptance

- Clean cache: download -> verify -> infer -> restart reuse -> delete passes.
- Corruption, disk full, insufficient RAM, gated/401, cancel/resume, lost custom storage, and deletion while leased have tests and recovery actions.
- Model identifiers and revisions survive restart without storing tokens in preferences.
