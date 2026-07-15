# Milestone 14: AI Companion

**Outcome:** Explain, Summary, Q&A, and Flashcards use only user-selected context and persist only explicit saves.

## Tasks

- [ ] Define explicit context scopes: current session, selected range, or selected sessions.
- [ ] Add prompt/input tests proving no hidden history, unrelated session, credential, or metadata is included.
- [ ] Implement companion operations through `ChatProvider` with streaming, cancellation, and provider destination metadata.
- [ ] Build ephemeral result UI with visible remote destination, scope summary, cancel, retry, copy, and Save.
- [ ] Add cancellation/error tests proving partial output is never persisted.
- [ ] Implement saved notes/flashcards with source-scope provenance and cascade behavior.
- [ ] Add accessibility and privacy acceptance for local and remote providers.

## Acceptance

- Requests contain only the scope explicitly selected by the user.
- Remote calls clearly identify their destination before submission.
- Unsaved and partial results disappear without durable artifacts.
- Saved artifacts trace back to their source session/range selection.
