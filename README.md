# MLingo

MLingo is a native macOS app that captures system audio, transcribes speech locally with MLX Whisper, translates recognized text with the OpenAI API, and presents click-through floating subtitles.

Audio stays on the Mac. Only transcript text and at most the two preceding transcript snippets are sent to OpenAI; translation requests use `store: false`.

## Requirements

- Apple Silicon Mac
- macOS 14 or later
- Xcode with the Metal Toolchain installed
- An OpenAI Platform API key for translation

An API key is billed through the OpenAI Platform. A ChatGPT subscription does not include API usage or API credits.

## Build and run in Xcode

Install the Metal Toolchain once if Xcode has not already installed it:

```bash
xcodebuild -downloadComponent MetalToolchain
```

Open `MLingo.xcodeproj`, select the shared `MLingo` scheme and run the app on **My Mac**. The first transcription can take longer while the default `mlx-community/whisper-base-mlx` model is downloaded and cached.

The SwiftPM executable remains available for compile and test compatibility, but it is not the packaged application and does not bundle the MLX Metal library. Use the Xcode app target for live transcription.

## Build a local release candidate

```bash
./scripts/build-local-rc.sh
```

The script archives the arm64 Release target and creates:

```text
.build/release/MLingo.app
```

It also verifies the ad-hoc signature, bundle identifier and version, AppIcon, entitlements, architecture, and `default.metallib` resource.

This build is intended for local use on the same Mac. It is ad-hoc signed, has App Sandbox disabled to support the current capture/MLX runtime, keeps the JIT entitlement, and is neither hardened nor notarized. Do not distribute it as a public release.

## Setup and permissions

Open Settings (`⌘,`) and configure the audio backend, models, languages, subtitles, and API key. Preferences are saved in UserDefaults; the trimmed API key is stored separately in Keychain.

- **System Audio** (default on macOS 14.2+): grant System Audio Recording access when macOS asks.
- **Screen Recording**: grant Screen Recording access. This is also the available backend on macOS 14.0–14.1.

If permission was denied, use the recovery action in MLingo or open System Settings > Privacy & Security, enable the corresponding permission, then restart the session.

## Daily use

- Start Translation: `⌘↩`
- Stop: `⌘.`
- Show/Hide Overlay: `⇧⌘O`
- Settings: `⌘,`

The overlay is click-through in normal mode. Use Overlay > Reposition Overlay to drag it, reset its position, or move it to another display. Display and placement preferences persist; session visibility does not.

Translation is non-streaming and processed by a bounded FIFO worker so network requests do not block Whisper. The main window exposes readiness, actionable errors, and an optional diagnostics section for audio, transcription, latency, CPU, and RSS.

## Privacy boundary

- System audio is captured and processed locally.
- Whisper inference runs locally with MLX.
- Audio, API credentials, display identifiers, and application identifiers are not sent to OpenAI.
- Only transcript text needed for the current translation and its short context is sent.
- OpenAI Responses API requests set `store: false`.
- The app does not include analytics or external telemetry.

## Validation

Run the offline test and release builds:

```bash
rtk proxy swift test
rtk proxy swift build -c release
rtk proxy xcodebuild \
  -project MLingo.xcodeproj \
  -scheme MLingo \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  build ARCHS=arm64 ONLY_ACTIVE_ARCH=YES EXCLUDED_ARCHS=x86_64
```

Integration and performance tests are opt-in because they can require TCC permissions, Metal, model downloads, WindowServer, or paid OpenAI API calls. See the milestone documents and test source for their environment flags. Never use real user audio or transcripts for an OpenAI benchmark.

## Troubleshooting

- **Translation cannot start:** save a valid OpenAI Platform API key and translation model in Settings.
- **Invalid key or model:** correct the draft values in Settings, save, then start a new session.
- **Quota error:** review API usage and billing at <https://platform.openai.com/usage>.
- **Offline or service error:** restore connectivity, stop the current session if needed, then restart it.
- **No captured audio:** confirm the selected backend and its matching macOS permission.
- **Metal library unavailable:** install the Metal Toolchain and run the native Xcode target or local RC script; do not use `swift run` for live transcription.
- **Model load is slow on first use:** wait for the Hugging Face model download to finish; later loads use the local cache.

## Architecture

```text
Selected audio backend
        │
        ▼
Adaptive audio windows
        │
        ▼
Local MLX Whisper
        │
        ▼
Sequential OpenAI translation
        │
        ▼
NSPanel subtitle overlay
```

MLingo uses SwiftUI for the app UI, AppKit for the floating panel, Swift Concurrency for the pipeline, UserDefaults for preferences, Keychain for credentials, URLSession for OpenAI, and OSLog/signposts for local diagnostics.

Version: `0.1.0` (build `1`).
