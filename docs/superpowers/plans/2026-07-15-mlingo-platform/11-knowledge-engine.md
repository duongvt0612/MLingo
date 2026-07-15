# Milestone 11: Knowledge Engine

**Outcome:** Recorded sessions support local bookmarks, vocabulary, notes, and model-isolated semantic search.

## Tasks

- [ ] Add SwiftData entities and migrations for bookmarks, vocabulary entries, timeline metadata, saved notes, and embedding records.
- [ ] Add failing tests for source linkage, uniqueness, cascade deletion, and selected-range metadata.
- [ ] Implement local embedding indexing by default with model ID, revision, dimensions, and normalization metadata per vector space.
- [ ] Add offline semantic-search fixtures, ranking tolerances, empty-index handling, and cancellation.
- [ ] Require explicit per-profile consent before any remote embedding call and show the destination before enabling it.
- [ ] Implement delete/rebuild when embedding model or revision changes; never query mixed vector spaces.
- [ ] Add background indexing progress and recovery without blocking session capture.

## Acceptance

- Semantic search works with network disabled.
- Session deletion removes related knowledge records and vectors.
- Changing embedding model cannot mix old and new vectors.
- Remote embedding is impossible without explicit stored consent for the selected profile.
