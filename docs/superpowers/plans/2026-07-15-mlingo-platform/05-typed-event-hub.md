# Milestone 05: Typed Event Hub

**Outcome:** A standalone event hub provides explicit typed delivery semantics before any runtime migration.

## Tasks

- [ ] Add failing tests for envelope metadata, per-session sequence, trace propagation, and typed subscription filtering.
- [ ] Implement `EventEnvelope<Event>`, session/trace identifiers, clock/ID seams, and subscription tokens.
- [ ] Add failing stress tests for realtime drop-oldest and coalescing policies under slow subscribers.
- [ ] Implement bounded realtime mailboxes with observable overflow metrics.
- [ ] Add failing tests proving durable mailboxes suspend producers, preserve order, and never drop.
- [ ] Implement durable subscription backpressure and cancellation-safe teardown.
- [ ] Define session lifecycle, transcript, and translation facts.
- [ ] Test subscriber failure isolation, cancellation races, stale-session callbacks, and cross-session isolation.

## Acceptance

- Realtime overflow follows the selected policy deterministically.
- Durable delivery is ordered and lossless under backpressure.
- One subscriber failure cannot terminate other subscriptions.
- `SubtitlePipeline` remains unchanged in this milestone.
