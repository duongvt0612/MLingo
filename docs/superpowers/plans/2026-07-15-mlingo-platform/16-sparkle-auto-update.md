# Milestone 16: Sparkle Auto-update

**Outcome:** A notarized MLingo release updates securely to the next version without losing user state.

## Tasks

- [ ] Add Sparkle 2.9.2 only after Milestone 15 produces the first accepted notarized release.
- [ ] Configure HTTPS appcast, EdDSA archive signatures, signed feed, and strictly increasing bundle versions.
- [ ] Add native Check for Updates and update-preference controls; use Sparkle's standard updater UI.
- [ ] Build deterministic feed/signature tests plus opt-in end-to-end update fixtures.
- [ ] Test valid N -> N+1, invalid archive/feed signatures, interrupted download/resume, unavailable feed, and downgrade rejection.
- [ ] Verify migration preserves provider profiles, Keychain credentials, model library/bookmarks, capability selections, and SwiftData schemas.
- [ ] Document offline/manual recovery and key-rotation procedure without storing private keys in the repository.

## Acceptance

- A notarized N build updates to notarized N+1 and relaunches successfully.
- Invalid or downgraded artifacts cannot install.
- User profiles, secrets, models, and recorded data remain usable after update.
- No custom updater UI or non-HTTPS feed is introduced in v1.
