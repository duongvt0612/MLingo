
# MLingo

> Detailed README (v0.1)

## Vision
MLingo is a native macOS application written in Swift that captures system audio, performs low-latency local speech recognition, translates speech in real time, renders subtitles, and can optionally speak completed translations.

The project is designed as a modular, event-driven platform that can later evolve into an AI language companion.

## Product Roadmap
1. Live Subtitle
2. Live Translation
3. Live Voice Translation
4. Knowledge Engine
5. AI Companion

## Development Roadmap

The original MVP milestones are complete. The active platform migration is defined by the master plan at `docs/superpowers/plans/2026-07-15-mlingo-platform/README.md` and its 17 independently gated milestones.

## Architecture
System Audio
-> Audio Engine
-> Speech Recognition
-> Transcript Event Bus

Subscribers:
- Subtitle Engine
- Translation Engine
- TTS Engine
- Knowledge Engine
- Recorder
- AI Companion

## Principles
- SwiftUI
- MVVM
- Async/Await
- SOLID
- Event-driven
- Local-first
- Privacy-first
- Compile-time feature modules

## Cost Strategy
- Local speech recognition
- User-selected remote or local providers
- On-demand AI only
