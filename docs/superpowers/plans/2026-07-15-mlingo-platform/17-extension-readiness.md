# Milestone 17: Extension Readiness

**Outcome:** Stable capability/event contracts support compile-time feature modes without loading unsigned dynamic code.

## Tasks

- [ ] Review and freeze public capability, event, session, model, and persistence contracts after the first public release.
- [ ] Define an internal compile-time feature-module protocol with lifecycle, declared capabilities, settings namespace, and event subscriptions.
- [ ] Add contract tests preventing modules from publishing commands as facts or bypassing provider/privacy selection.
- [ ] Implement one sample mode in a separate target to exercise isolation, lifecycle, settings, and teardown.
- [ ] Verify the sample requires no edits to provider protocols, registry, event envelope, or hub implementation.
- [ ] Document post-v1 Meeting, Podcast, Developer, OCR, Vision Pro, and dynamic-plugin work without exposing a runtime plugin loader.

## Acceptance

- A sample mode compiles, runs, and tears down through the module contract.
- Removing the sample target leaves the core unchanged.
- No unsigned dynamic code is discovered or loaded.
- Provider and event contracts are versioned and accompanied by compatibility tests.
