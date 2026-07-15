# Milestone 04: Provider Settings UX

**Status:** Code-complete as of 2026-07-16; manual accessibility acceptance remains
pending. Milestone 03's external loopback proof is deferred by explicit owner waiver and
remains unchecked.

**Outcome:** Users can safely configure profiles and independent capability selections in a native, accessible Settings experience.

## Tasks

- [x] Add view-model tests for sidebar routing, draft editing, Save/Cancel rollback, validation, connection-test state, and secret replacement/removal.
- [x] Split Settings into General, Audio & Speech, AI Providers, Models, Translation, Subtitles, Appearance, and Privacy destinations.
- [x] Implement an AI Providers master-detail editor using `Form`, `Section`, semantic colors, and SF Symbols.
- [x] Keep profile changes in a draft until Save; Cancel must restore persisted state and credentials.
- [x] Mask existing secrets, expose explicit Replace/Remove actions, and never bind full secrets back into UI after save.
- [x] Add independent profile/model selectors for Translation, Chat, Embedding, and TTS, including unavailable-selection recovery.
- [ ] Verify focus order, keyboard-only operation, VoiceOver labels, Light/Dark/System, Dynamic Type, and reduced motion.

## Acceptance

- Invalid drafts cannot be saved and show actionable inline errors.
- Cancelling any edit leaves profile, credential, and selection stores unchanged.
- Connection tests use unsaved draft values without persisting them.
- Accessibility acceptance is recorded with automated coverage where possible and a short manual checklist otherwise.

## Automated acceptance recorded 2026-07-16

- [x] Draft validation is deterministic, ignores the retired `AppSettings.openAIModel`
  field, routes to the affected destination, and requests focus for the first invalid
  control.
- [x] Save/Cancel isolation, all three persistence failure stages, reverse rollback,
  rollback-failure reload, active-session credential protection, shared credentials, and
  unreferenced credential deletion are covered offline.
- [x] Connection tests use unsaved endpoint/style/auth/models, keep unchanged secrets
  inside the probe closure, do not persist discovered models, cancel cleanly, and reject
  stale callbacks by profile ID and generation.
- [x] Translation readiness is derived from the selected provider/model/credential rather
  than the legacy OpenAI key. Successful commits refresh theme, Whisper diagnostics,
  provider readiness, and overlay state.
- [x] Settings uses native system fonts, semantic styles, SF Symbols, scrollable grouped
  forms, a minimum window size, Return as the default Save action, Escape for Cancel, and
  text plus symbols for every status. There are no custom animations or transitions.
- [x] Offline deterministic gate: `rtk swift test --no-parallel` passes 260 tests;
  `rtk swift build -c release` and `rtk git diff --check` pass. The only build warning is
  the already-classified upstream MLXAudioVAD README resource warning.

## Manual accessibility checklist

Run this checklist on a native app build before changing the milestone status to
complete. Do not infer a pass from automated tests.

- [ ] Keyboard-only: traverse the sidebar, provider master/detail forms, menus, model
  fields, Test Connection, Delete, Cancel, and Save using Tab, Shift-Tab, arrow keys,
  Return, and Escape; confirm an invalid Save moves focus to the first invalid control.
- [ ] VoiceOver: confirm every destination, field, icon-bearing action, validation error,
  credential state, connection result, and provider readiness state has an intelligible
  label/hint and logical reading order.
- [ ] Larger text: test the largest supported macOS text size; forms must scroll and no
  control, validation message, or footer may be clipped.
- [ ] Appearance: save and reopen Settings in System, Light, and Dark; semantic contrast
  and focus rings must remain legible.
- [ ] Reduced motion: enable Reduce Motion and repeat navigation, validation, probe, and
  save flows; no nonessential motion may appear.
- [ ] Transaction smoke test: edit a profile and credential then Cancel/reopen to confirm
  no persisted change; repeat with Save and confirm the secret remains masked.
