# ADR 0003: Unified model storage

**Status:** Accepted

## Decision

Use one `ModelManager` for Whisper, LLM, embedding, and TTS assets. Default storage is Application Support; optional custom storage uses a persisted security-scoped bookmark. Catalog revisions are pinned, custom repositories require compatibility probing, and gated tokens remain in Keychain.

## Consequences

Download, verification, leases, deletion, recovery, and disk accounting share one state machine. Runtime code cannot delete leased assets. Loss of custom storage must surface a recoverable typed state.
