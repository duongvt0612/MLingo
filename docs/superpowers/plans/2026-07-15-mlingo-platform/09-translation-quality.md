# Milestone 09: Translation Quality

**Outcome:** Translation is sentence-complete, ordered, measurable, and consistent across providers.

## Tasks

- [ ] Create a synthetic multilingual corpus covering fragments, punctuation, names, terminology, rapid turns, cancellation, and provider errors.
- [ ] Add failing assembler tests for sentence boundaries, timeouts, language-specific punctuation, and final flush.
- [ ] Implement a sentence-fragment assembler before `TranslationProvider`.
- [ ] Preserve atomic subtitle commit; keep streaming revisions internal to provider diagnostics.
- [ ] Normalize context budgets and language instructions while retaining provider-specific wire adapters.
- [ ] Measure queue delay, internal time-to-first-token, total latency, and token usage when available.
- [ ] Record device/model/provider benchmark baselines and explicit p50/p95 gates before enabling quality regressions in CI.

## Acceptance

- No duplicate or reordered completed translations across stress fixtures.
- Names and terminology remain stable within the documented corpus expectation.
- Overlay and TTS never observe draft tokens.
- Cloud and local benchmark results meet the recorded milestone gates or fail with an approved, documented exception.
