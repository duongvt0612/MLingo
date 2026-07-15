# ADR 0002: Hybrid typed event hub

**Status:** Accepted

## Decision

Publish immutable typed facts in session-scoped envelopes. Realtime subscribers use bounded drop-oldest or coalescing mailboxes. Durable subscribers suspend producers when full and never drop. Commands call services directly, and raw audio stays outside the global hub.

## Consequences

The runtime gains explicit delivery semantics and stale-session isolation. Durable consumers can apply backpressure. Command/event confusion and unbounded audio fan-out are avoided.
