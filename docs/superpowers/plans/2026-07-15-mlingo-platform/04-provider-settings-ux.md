# Milestone 04: Provider Settings UX

**Status:** Code-complete as of 2026-07-16; manual accessibility acceptance remains
pending. Milestone 03's external loopback proof is deferred by explicit owner waiver and
remains unchecked.

**Outcome:** Users can safely configure profiles and independent capability selections in a native, accessible Settings experience.

## Audit matrix recorded 2026-07-16

Checkboxes were not treated as evidence. `Verified` means the current implementation,
regression coverage, and any required native UI evidence agree. `Gap` means acceptance
evidence is still missing; it does not imply a product defect unless one is named.

| Requirement | Status | Current evidence |
|---|---|---|
| Eight locked Settings destinations | Verified | `SettingsDestination.allCases` regression plus the native accessibility tree show General, Audio & Speech, AI Providers, Models, Translation, Subtitles, Appearance, and Privacy in order. |
| Draft isolation, Cancel, normalization, deterministic validation, legacy-model exclusion, unavailable-selection recovery, and invalid-focus routing | Verified | `SettingsEditorDomainTests.swift` covers the snapshot/draft boundary, normalized profiles/models, `AppSettings.openAIModel` exclusion, explicit clearing, and first-invalid-field routing before persistence. |
| Transactional persistence and rollback | Verified | `SettingsPersistenceCoordinatorTests.swift` covers credential -> provider configuration -> app settings writes, failures at every stage, reverse rollback, rollback-failure reload, and no-write invalid drafts. |
| Credential lifecycle and secret containment | Verified | Shared and unreferenced credentials, active-session mutation protection, empty replacement rejection, Keychain account usage, secret-free serialized settings/configuration, and probe-closure-only secret reads are covered offline. |
| Unsaved connection probe | Verified | `SettingsConnectionProbeTests.swift` covers unsaved endpoint/models/replacement secret, unchanged-secret closure reads, cancellation, discovered-model non-persistence, and stale callback rejection. |
| Independent capability assignments and no fallback | Verified | Native accessibility output shows independent Translation, Chat, Embedding, and Text to Speech provider controls with valid `Not configured` states; registry/editor tests enforce explicit selection without fallback. |
| Native provider/settings UX | Verified | Native Release QA shows the master-detail profile editor, grouped scrollable forms, semantic Light/Dark rendering, endpoint/API style/authentication/model controls, Test Connection, Delete, Cancel, and Save. |
| Xcode application target contains all M04 sources | Verified | The audit first reproduced a native Release archive compile failure because four M04 files were absent from `MLingo.xcodeproj`; target membership is fixed and `XcodeProjectMembershipTests.swift` prevents recurrence. |
| Keyboard-only and invalid-focus manual acceptance | Gap | Return/Escape wiring and focus routing are automated. A full native traversal still requires macOS Keyboard Navigation to be enabled and has not been recorded. |
| VoiceOver manual acceptance | Gap | Accessibility labels/order are visible in the native accessibility tree, but an actual VoiceOver reading-order pass has not been recorded. |
| Largest supported text size | Gap | Scroll containers are verified in code/native tree; the largest macOS text-size run has not been recorded. |
| System, Light, and Dark appearance | Gap | Dark and Light are legible in the QA build, and Cancel/reopen plus Light Save/reopen were exercised. Dark Save/reopen and a complete focus-ring sweep are still missing. |
| Reduced Motion | Gap | No custom animations/transitions were found, but the native flow has not been repeated with Reduce Motion enabled. |
| Profile/credential transaction smoke | Gap | Automated rollback/secret masking passes and appearance Cancel/Save/reopen passes. A native profile plus fake-credential Cancel/Save/reopen run is still missing. |

No requirement is currently classified `Not applicable`.

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
- [x] Xcode target membership is checked against every Swift source under
  `Sources/MLingoApp`; the four missing M04 source entries found by the audit are fixed.
- [x] Offline deterministic gate: `rtk swift test --no-parallel` passes 268 tests;
  `rtk swift build -c release` and `rtk git diff --check` pass. The only build warning is
  the already-classified upstream MLXAudioVAD README resource warning.
- [x] Native application gate: `./scripts/build-local-rc.sh` archives the Release app,
  copies the artifact, and verifies its ad-hoc signature after the Xcode membership fix.

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

### Partial native run recorded 2026-07-16

- Native accessibility inspection confirmed the sidebar order, destination labels,
  independent capability controls, profile editor labels/hints, credential state, and
  scrollable provider form.
- Appearance Cancel/reopen preserved the snapshot. Light Save/reopen persisted, and the
  QA profile was restored to System afterward. Light and Dark semantic rendering were
  visually legible at the default text size.
- Tab reached Cancel and Save, but the machine's macOS Keyboard Navigation setting was
  not enabled, so this is not accepted as a keyboard-only pass.
- VoiceOver, largest text, Reduce Motion, Dark Save/reopen, and the fake-credential
  transaction smoke remain unaccepted. Milestone 04 therefore remains code-complete,
  not acceptance-complete.
