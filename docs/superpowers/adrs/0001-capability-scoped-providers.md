# ADR 0001: Capability-scoped providers

**Status:** Accepted

## Decision

Define a separate protocol for speech recognition, translation, chat, embedding, and TTS. Resolve a profile and model explicitly for each `ModelCapability`. Remote OpenAI-compatible and built-in local implementations share these boundaries. Resolution failures are typed and never trigger silent fallback.

## Consequences

Capabilities can evolve and be selected independently without a mega-interface. Settings and diagnostics must expose the active destination per capability. Callers must handle unavailable or invalid selections explicitly.
