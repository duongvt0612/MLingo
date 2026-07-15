# Milestone 02: AI Capability Core

**Outcome:** Current OpenAI translation runs through explicit capability/profile resolution without changing observable behavior.

## Task 1: Capability contracts

- [ ] Add failing tests for all `ModelCapability` cases and narrow provider protocol contracts.
- [ ] Implement request/result types for speech recognition, translation, chat, embedding, and TTS.
- [ ] Prove protocol mocks compile under Swift 6 strict concurrency.

## Task 2: Profiles and resolution

- [ ] Add failing tests for profile validation, endpoint policy, capability models, missing selection, and no-fallback behavior.
- [ ] Implement `ProviderProfile`, provider/auth/API-style types, capability selections, typed recovery actions, and `ProviderRegistry`.
- [ ] Reject non-loopback HTTP and invalid custom secret-header names before transport execution.

## Task 3: Persistence and credentials

- [ ] Add failing tests for profile CRUD, transactional replacement, credential references, and secret deletion.
- [ ] Implement profile storage keyed by stable profile ID and Keychain-backed credential storage.
- [ ] Ensure profile serialization contains only credential IDs, never secret values.

## Task 4: Existing OpenAI adapter and migration

- [ ] Add characterization tests for request privacy, translation ordering, response parsing, cancellation, and error mapping.
- [ ] Wrap `OpenAITranslationEngine` with `TranslationProvider` and route the existing runtime through the registry selection.
- [ ] Add one-time migration tests for legacy API key/model, idempotency, partial failure, and legacy-key cleanup.
- [ ] Implement migration to a default OpenAI profile; remove long-term legacy reads after successful migration.

## Acceptance

- Existing translation fixtures produce identical results and typed failures.
- No profile failure selects another provider.
- Keychain is the only secret store.
- Default tests are offline and deterministic.
