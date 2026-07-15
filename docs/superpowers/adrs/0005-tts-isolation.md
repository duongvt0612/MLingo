# ADR 0005: TTS isolation

**Status:** Accepted

## Decision

TTS consumes completed translation events through its own provider capability and ordered queue. System TTS ships first; remote and built-in AI implementations follow. TTS cancels by session, uses a separate output path, and never receives draft translations.

## Consequences

Changing a TTS provider does not modify translation or session orchestration. Optional ducking must restore system state on every termination path. Voice cloning remains out of v1 scope.
