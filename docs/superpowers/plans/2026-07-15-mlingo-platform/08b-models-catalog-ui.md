# Milestone 08b: Models Catalog UI

**Outcome:** Users manage model downloads, storage, and deletion from a native, accessible Models pane.

**Design:** [Model Manager design](../../specs/2026-07-28-model-manager-design.md)

**Depends on:** [08a](08a-model-manager-core.md)

**Starting point:** `SettingsDestination.models` already exists and its page is a placeholder naming this milestone. No new destination is added.

## Tasks

- [ ] Replace the Models placeholder with a catalog list showing per-model status, size, revision, and storage usage.
- [ ] Wire download, cancel, retry, and delete actions to `ModelManager`, with confirmation before deletion.
- [ ] Render determinate progress and surface every typed recovery action as an actionable control.
- [ ] Compose `ModelManager` into `MLingoViewModel.live()` and pass the directory resolver to `MLXWhisperEngine`.
- [ ] Add Hugging Face token entry reusing the transactional credential pattern, with the secret always masked.
- [ ] Add the new source files to the Xcode application target and keep the membership regression green.
- [ ] Verify keyboard-only operation, focus order, VoiceOver labels, largest text size, Light/Dark/System, and Reduce Motion.

## Acceptance

- [ ] Every model state is conveyed by text and symbol, never by colour alone.
- [ ] Cancelling or deleting is impossible to trigger accidentally and impossible while a model is in use.
- [ ] Errors appear next to the affected model with a working recovery action.
- [ ] Native Release archive, signature, and export checks pass.
