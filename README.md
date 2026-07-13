# MLingo

A native macOS application written in Swift that captures system audio, performs local speech recognition using MLX-Whisper, translates the transcript into Vietnamese using the OpenAI API, and renders floating subtitles over any application.

---

# Vision

Watching English content should feel as natural as watching Vietnamese content.

The application should work with any macOS application that outputs audio:

- YouTube
- Netflix
- Coursera
- Udemy
- Zoom
- Google Meet
- VLC
- Podcasts
- Twitch

Speech recognition runs locally.

Only text is sent to the translation API.

---

# Goals

- Native SwiftUI application
- Apple Silicon optimized
- Low latency (1–2 seconds)
- Local speech recognition
- Floating subtitles
- Beautiful macOS experience
- Easy to maintain

---

# Tech Stack

Language

- Swift 6

UI

- SwiftUI

Window Management

- AppKit
- NSPanel

Audio

- ScreenCaptureKit
- AVFoundation

Speech Recognition

- MLX Whisper

Networking

- URLSession

Persistence

- SwiftData

Logging

- OSLog

Package Manager

- Swift Package Manager

---

# MVP Features

## Capture System Audio

Capture audio produced by any application.

No virtual audio device should be required if ScreenCaptureKit can provide audio.

---

## Local Speech Recognition

Convert audio into English text.

Requirements

- Streaming
- Low latency
- Continuous transcription

---

## Translation

Translate English into Vietnamese.

Requirements

- Natural Vietnamese
- Preserve names
- Preserve technical terms
- No summarization

---

## Floating Subtitle Window

Always-on-top transparent window.

Features

- Adjustable font
- Adjustable opacity
- Position
- Auto resize

---

## Settings

Allow configuring

- OpenAI API Key
- Whisper model
- Subtitle font
- Font size
- Background opacity
- Theme
- Language pair

---

# Architecture

```
System Audio
        │
        ▼
ScreenCaptureKit
        │
        ▼
Audio Buffer
        │
        ▼
Speech Detector
        │
        ▼
MLX Whisper
        │
        ▼
Transcript
        │
        ▼
Translator
        │
        ▼
Subtitle Queue
        │
        ▼
Overlay Window
```

---

# Project Structure

```
MLingo/

    App/

    Audio/

    Whisper/

    Translation/

    Overlay/

    Settings/

    Models/

    Persistence/

    Utilities/

    Resources/

    Tests/
```

---

# Main Components

## AudioEngine

Responsible for

- capturing system audio
- buffering
- resampling
- voice activity detection

---

## WhisperEngine

Responsible for

- loading model
- inference
- streaming transcription

Returns

```
Transcript
```

---

## TranslationEngine

Responsible for

- batching text
- maintaining context
- calling OpenAI
- streaming translated text

Returns

```
SubtitleItem
```

---

## OverlayEngine

Responsible for

- subtitle rendering
- animations
- multiple displays
- scaling

---

## SettingsManager

Stores

- preferences
- API key
- language
- appearance

---

# Data Models

```swift
struct Transcript {

    let id: UUID

    let text: String

    let timestamp: TimeInterval

}
```

```swift
struct SubtitleItem {

    let id: UUID

    let original: String

    let translated: String

    let start: Double

    let end: Double

}
```

---

# Latency Target

Speech Recognition

500~800 ms

Translation

300~500 ms

Rendering

<100 ms

Total

1~2 seconds

---

# Future Features

- Bilingual subtitles
- Vocabulary collection
- AI explanation popup
- OCR subtitle extraction
- Offline translation
- Meeting mode
- Safari extension
- macOS menu bar mode
- Apple Vision Pro support

---

# Milestones

## Milestone 1

Project setup

SwiftUI application

Basic architecture

---

## Milestone 2

Audio capture

Verify ScreenCaptureKit

---

## Milestone 3

Integrate MLX Whisper

Print transcript

---

## Milestone 4

OpenAI Translation

Streaming translation

---

## Milestone 5

Floating subtitles

Overlay window

---

## Milestone 6

Settings

Persistence

---

## Milestone 7

Performance optimization

Reduce latency

---

## Milestone 8

Polish

Release Candidate

---

# Coding Principles

- SOLID
- MVVM
- Async/Await
- Protocol Oriented Programming
- Dependency Injection
- No Singleton unless necessary
- Testable architecture
- Clean folder structure

---

# Success Criteria

- Less than 2 seconds latency
- Stable for hours
- Low CPU usage
- Native macOS experience
- Beautiful UI
