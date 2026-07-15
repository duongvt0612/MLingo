# Milestone 04: Provider Settings UX

**Status:** In progress as of 2026-07-16. Milestone 03's external loopback proof is
deferred by explicit owner waiver and remains unchecked.

**Outcome:** Users can safely configure profiles and independent capability selections in a native, accessible Settings experience.

## Tasks

- [ ] Add view-model tests for sidebar routing, draft editing, Save/Cancel rollback, validation, connection-test state, and secret replacement/removal.
- [ ] Split Settings into General, Audio & Speech, AI Providers, Models, Translation, Subtitles, Appearance, and Privacy destinations.
- [ ] Implement an AI Providers master-detail editor using `Form`, `Section`, semantic colors, and SF Symbols.
- [ ] Keep profile changes in a draft until Save; Cancel must restore persisted state and credentials.
- [ ] Mask existing secrets, expose explicit Replace/Remove actions, and never bind full secrets back into UI after save.
- [ ] Add independent profile/model selectors for Translation, Chat, Embedding, and TTS, including unavailable-selection recovery.
- [ ] Verify focus order, keyboard-only operation, VoiceOver labels, Light/Dark/System, Dynamic Type, and reduced motion.

## Acceptance

- Invalid drafts cannot be saved and show actionable inline errors.
- Cancelling any edit leaves profile, credential, and selection stores unchanged.
- Connection tests use unsaved draft values without persisting them.
- Accessibility acceptance is recorded with automated coverage where possible and a short manual checklist otherwise.
