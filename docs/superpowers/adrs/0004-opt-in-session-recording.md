# ADR 0004: Opt-in session recording

**Status:** Accepted

## Decision

Recording is off by default and enabled per session. SwiftData stores transcripts, translations, and user-created knowledge artifacts until explicit deletion. Raw audio, credentials, and endpoint secrets are never stored or exported. Embeddings are derived and rebuildable.

## Consequences

Unrecorded sessions create no durable records. Recorded sessions require cascade deletion and versioned migration coverage. Remote embedding requires separate, per-profile consent.
