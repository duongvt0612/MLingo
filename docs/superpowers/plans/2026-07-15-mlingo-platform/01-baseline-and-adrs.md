# Milestone 01: Baseline and ADRs

**Outcome:** Establish one current, executable source of truth without changing runtime behavior.

## Tasks

- [x] Replace product references in the new concept notes with MLingo and mark the old eight-step roadmap as historical.
- [x] Add the accepted platform design, master index, and 17 independently gated milestone plans.
- [x] Record ADRs for capability providers, hybrid typed events, unified model storage, opt-in recording, and isolated TTS.
- [x] Capture the exact baseline test/build result and classify upstream warnings in `baseline-2026-07-15.md`.
- [x] Verify all internal documentation links and ensure no active plan contradicts the locked decisions.
- [x] Run the final diff gate and record the result in the master status log.

## Acceptance

- Runtime source and package dependencies are unchanged.
- Product-facing documentation consistently calls the app MLingo.
- Old MVP roadmap is explicitly historical, not represented as pending work.
- Test, release build, and diff check pass; third-party warnings are named and separated from project failures.
