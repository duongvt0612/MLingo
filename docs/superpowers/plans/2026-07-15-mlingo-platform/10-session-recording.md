# Milestone 10: Opt-in Session Recording

**Outcome:** Users can explicitly record and export text sessions without persisting audio or secrets.

## Tasks

- [ ] Define versioned SwiftData schemas for session, transcript, and translation records with stable IDs and cascade rules.
- [ ] Add in-memory tests proving recording defaults off and unrecorded sessions create no records.
- [ ] Implement a durable transcript/translation sink activated only for an opted-in session.
- [ ] Add migration, interrupted-write, restart, cascade-delete, and concurrent-event tests.
- [ ] Build session library, detail timeline, text search, explicit delete, and empty/error states.
- [ ] Implement JSON, Markdown, SRT, and VTT exports with deterministic escaping and ordering.
- [ ] Add privacy scans proving database and exports contain no raw audio, credentials, secret headers, or endpoint secrets.

## Acceptance

- Unrecorded sessions leave the canonical store unchanged.
- Recorded transcripts and translations remain ordered across restart.
- Deleting a session removes all owned records.
- Every export format passes golden fixtures and privacy scans.
