# Milestone 08b: Models Catalog UI

**Outcome:** Users manage model downloads, storage, and deletion from a native, accessible Models pane.

**Design:** [Model Manager design](../../specs/2026-07-28-model-manager-design.md)

**Depends on:** [08a](08a-model-manager-core.md)

**Status:** Code-complete as of 2026-08-03; manual accessibility acceptance remains pending, as it
does for Milestone 04.

**Starting point:** `SettingsDestination.models` already exists and its page is a placeholder naming this milestone. No new destination is added.

## Tasks

- [x] Replace the Models placeholder with a catalog list showing per-model status, size, revision, and storage usage.
- [x] Wire download, cancel, retry, and delete actions to `ModelManager`, with confirmation before deletion.
- [x] Render determinate progress and surface every typed recovery action as an actionable control.
- [x] Compose `ModelManager` into `MLingoViewModel.live()` and pass the directory resolver to `MLXWhisperEngine`.
- [x] Add Hugging Face token entry reusing the transactional credential pattern, with the secret always masked.
- [x] Add the new source files to the Xcode application target and keep the membership regression green.
- [ ] Verify keyboard-only operation, focus order, VoiceOver labels, largest text size, Light/Dark/System, and Reduce Motion.

## Acceptance

- [x] Every model state is conveyed by text and symbol, never by colour alone.
- [x] Cancelling or deleting is impossible to trigger accidentally and impossible while a model is in use.
- [x] Errors appear next to the affected model with a working recovery action.
- [x] Native Release archive, signature, and export checks pass.

## Decisions

- The pane is **not** transactional. Downloading and deleting take effect immediately, because a
  draft of a 148 MB transfer means nothing. The one value that stays in the settings draft is the
  Hugging Face token, so downloads are blocked with a stated reason while an unsaved token is
  pending rather than silently using the previous one.
- The Whisper model identifier keeps its free-text field. An installed catalog entry offers
  **Use This Model**, which writes the identifier into that field; anything else still resolves
  through the engine's previous download path.
- Deletion while a model is in use is refused in three independent places: the lease registry,
  `LocalModelResidencyReporting` (Whisper refuses eviction mid-transcription), and the pane, which
  disables Delete outright while a session runs. `SessionOrchestrator` is untouched.

## Architecture notes

- `ModelCatalogManaging` is the seam between the pane and `ModelManager`. Without it an app test
  would have to construct the actor, which writes into the real Application Support directory.
- `CompositeModelResidencyReporter` speaks for both runtimes that hold model files. It is built
  empty and filled afterwards because composition is circular: `MLXWhisperEngine` needs the
  manager as its resolver, and the manager needs the engine's residency.
- `BuiltInMLXProvider.residencyReporting` exists because `BuiltInMLXRuntime` is internal; it is
  the only way the composition root can reach chat and embedding residency.
- `ModelStoreComposition` returns `nil` when storage cannot be opened. The app still launches,
  Whisper falls back to its previous download path, and the pane says so.

## Recorded 2026-08-03

- `swift test --no-parallel`: **470 tests pass**, up from the 433 baseline of 08a.
- `swift build -c release`: passes with the one classified upstream MLXAudioVAD README warning.
- `git diff --check`: clean.
- `./scripts/build-local-rc.sh`: `ARCHIVE SUCCEEDED`, arm64 signature and export checks pass, app
  exported to `.build/release/MLingo.app`. Required because `MLingo.xcodeproj` gained four files.
- Launched the exported Release app: it starts, reports `Whisper: Idle`, and creates
  `~/Library/Application Support/MLingo/Models/{installed,staging,quarantine,hub-cache}` — the new
  composition runs in the real app, not only under test.
- Evidence for the acceptance items above is unit-level: `ModelPresentationTests` walks every
  `ModelLifecycleState` and every `ModelStoreIssue`, asserting a non-empty title, symbol, message,
  and a runnable recovery command for each; `ModelsCatalogViewModelTests` proves deletion needs a
  separate confirmation, that a refused deletion is attached to its own row with the
  `stopActiveSession` action, and that the subscription stops when the pane closes.
- `typedEventHubSerializesConcurrentPublishersByAssignedSequence` (Milestone 05) fails
  intermittently — roughly one run in three in isolation. Nothing under `Sources/MLingoCore/Events`
  was touched here, so it predates this milestone; 08a recorded the same test as flaky. It is a
  real defect in either the hub's delivery ordering or the test's expectation and is left open.

## Not done

The manual accessibility pass — keyboard-only traversal, focus order, VoiceOver labels for every
state, progress value and action, the largest supported text size, Light/Dark/System, and Reduce
Motion — has not been run. It needs a person at the machine and is the only item between this
milestone and complete.
