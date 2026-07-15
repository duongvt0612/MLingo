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

- Swift 6.3

UI

- SwiftUI

Window Management

- AppKit
- NSPanel

Audio

- Core Audio Process Tap (macOS 14.2+)
- ScreenCaptureKit audio-only (user-selectable on macOS 14.2+, fallback on 14.0–14.1)
- AVFoundation

Speech Recognition

- MLX Whisper via `mlx-audio-swift` 0.1.3

Networking

- URLSession

Persistence

- UserDefaults for small application preferences
- Keychain for the OpenAI API key
- SwiftData is reserved for future history or vocabulary data

Logging

- OSLog

Package Manager

- Swift Package Manager

---

# MVP Features

## Capture System Audio

Capture audio produced by any application. Choose the backend in Settings > Audio capture:

- **System Audio** (default, macOS 14.2+): Core Audio Process Tap with System Audio Recording permission.
- **Screen Recording**: ScreenCaptureKit audio-only with Screen Recording permission.
- macOS 14.0–14.1 always uses the ScreenCaptureKit backend because Process Tap is unavailable.

On macOS 14.2+, a denied or failed Core Audio capture does not silently fall back to ScreenCaptureKit. Select **Screen Recording** explicitly if you want that backend. No virtual audio device is required.

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

Settings use a Save/Cancel draft flow. Saving validates and normalizes the draft before changing the running app. The OpenAI API key is stored separately in Keychain and is never serialized with preferences.

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
Selected Core Audio Tap / ScreenCaptureKit backend
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

---

# Development

The default local Whisper model is `mlx-community/whisper-base-mlx`. Model artifacts are downloaded from Hugging Face on first use and then cached locally. Audio samples are never uploaded; only recognized text enters the OpenAI translation path.

The packaged app includes both capture descriptions. Grant the permission matching the backend selected in Settings: **System Audio Recording** for System Audio, or **Screen Recording** for Screen Recording. On macOS 14.0–14.1, only the ScreenCaptureKit option is available at runtime.

To run Whisper, open `Package.swift` in Xcode, select the `MLingo` scheme, and press Run. Install the Metal Toolchain first if Xcode has not already installed it:

```bash
xcodebuild -downloadComponent MetalToolchain
open Package.swift
```

Do not use `swift run` for transcription. Command-line SwiftPM builds the executable but does not package mlx-swift's Metal library; MLingo will report this configuration error instead of letting MLX abort the process.

Run the offline unit suite:

```bash
swift test
```

Run the opt-in native MLX fixture test. It uses the normal Hugging Face cache and downloads the model only when it is missing:

```bash
MLINGO_RUN_MLX_INTEGRATION=1 swift test --filter MLXWhisperIntegrationTests
```

This CLI form requires `default.metallib` to already be present beside the test products. On a clean machine, use the Xcode command below so the shader bundle is built and packaged automatically.

The command-line SwiftPM builder cannot compile MLX Metal shaders. For GPU inference, build the package directly with Xcode (no generated Xcode project is required) and ensure the Metal Toolchain component is installed. The compilation condition is required because shell environment variables are not forwarded into Xcode's test process:

```bash
xcodebuild test \
  -scheme MLingo-Package \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:MLingoCoreTests \
  -skipPackagePluginValidation \
  OTHER_SWIFT_FLAGS='$(inherited) -DMLINGO_RUN_MLX_INTEGRATION'
```

To force a separate download/load check from an empty temporary cache, replace the compilation condition with `-DMLINGO_RUN_MLX_DOWNLOAD_INTEGRATION`.

The Core Audio hardware integration test is opt-in because it can trigger TCC and requires audible system speech while it runs:

```bash
MLINGO_RUN_CORE_AUDIO_INTEGRATION=1 swift test --filter CoreAudioTapIntegrationTests
```

Run that test from the packaged Xcode scheme when checking permissions on a clean machine. Default `swift test` never requests or changes TCC permission.

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
