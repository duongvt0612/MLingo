# Milestone 03 - Transcription bằng MLX Whisper

## Mục tiêu

Thay `MLXWhisperEngine` placeholder bằng inference native Swift trên Apple Silicon, local-only và không embed Python runtime.

## Trạng thái triển khai

- [x] Swift tools 6.2; pin chính xác `mlx-audio-swift` 0.1.3.
- [x] Chỉ liên kết `MLXAudioCore` và `MLXAudioSTT` vào `MLingoCore`.
- [x] `MLXWhisperEngine` là actor, dùng `WhisperModel.fromPretrained` và cache model đang load.
- [x] Model mặc định `mlx-community/whisper-base-mlx`.
- [x] Migrate chính xác model cũ `mlx-community/whisper-small` sang `mlx-community/whisper-small-mlx`.
- [x] Ép source language, bỏ transcript rỗng và ánh xạ lỗi load/inference.
- [x] Adaptive window: silence 0,5 giây, speech tối thiểu 0,4 giây, hard limit 3 giây và overlap 0,4 giây.
- [x] Inference tuần tự, dedupe exact/near-duplicate và suffix/prefix overlap.
- [x] Session cancellation chặn callback transcript/diagnostics cũ sau stop/restart.
- [x] Pipeline có hai mode `.transcriptionOnly` và `.translation`.
- [x] Test Transcription không gọi OpenAI và không mở overlay.
- [x] ViewModel dùng một active mode duy nhất cho idle, sound test, transcription test và translation.
- [x] Status panel hiển thị model state, model ID, transcript cuối, window duration, latency, processed và duplicate count.
- [x] Fixture `jfk.flac` có attribution và test MLX thật dạng opt-in.

## Quyền riêng tư và tải model

Audio samples chỉ đi từ ScreenCaptureKit đến MLX Whisper trong process của ứng dụng. MLingo không upload audio. Lần đầu load model/tokenizer, thư viện có thể tải artifact từ Hugging Face; các lần sau dùng cache cục bộ và cùng model ID được reuse trong memory.

Hai ID do MLingo quản lý (`whisper-base-mlx` và `whisper-small-mlx`) hiện trỏ tới repository legacy chỉ có `weights.npz`, trong khi loader 0.1.3 nhận `safetensors`. Backend resolve chúng sang mirror F16 tương ứng (`*-asr-fp16`, khoảng 144 MB cho base) lúc load. Giá trị settings và custom model ID không bị rewrite.

## Test

Test mặc định không tải model:

```bash
rtk proxy swift test
```

Test MLX thật với fixture JFK được gate bằng biến môi trường:

```bash
rtk proxy env MLINGO_RUN_MLX_INTEGRATION=1 swift test --filter MLXWhisperIntegrationTests
```

`mlx-swift` xác nhận SwiftPM command-line không build được Metal shaders. Command trên chỉ chạy được nếu `mlx.metallib` đã được cung cấp cạnh test binary. Cách chuẩn, vẫn dùng trực tiếp `Package.swift` và không cần tạo `.xcodeproj`, là:

```bash
rtk proxy env MLINGO_RUN_MLX_INTEGRATION=1 xcodebuild test \
  -scheme MLingo-Package \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:MLingoCoreTests \
  -skipPackagePluginValidation
```

Xcode phải cài Metal Toolchain trong Settings → Components (hoặc qua `xcodebuild -downloadComponent MetalToolchain`).

Kết quả được chấp nhận khi transcript, không phụ thuộc dấu câu, chứa:

```text
ask not what your country can do for you
```

## Nghiệm thu manual

- [ ] Lần đầu hiển thị Loading rồi Ready; lần sau reuse cache.
- [ ] Test Transcription chạy khi không có OpenAI API key và không mở overlay.
- [ ] YouTube/VLC tạo transcript đúng thứ tự, không spam duplicate.
- [ ] Stop/start nhiều lần không crash và không nhận callback session cũ.
- [ ] Lỗi mạng/model hiển thị rõ và có thể thử lại.
- [ ] Sau warm-up trên M4 Pro, benchmark ít nhất 10 window: median ≤ 1.200 ms, p95 ≤ 2.000 ms; không tính model load.

Verification trên máy phát triển hiện tại đã tải và validate model F16 thành công, nhưng GPU integration còn chặn ở môi trường vì Xcode chưa cài Metal Toolchain. Offline suite không bị ảnh hưởng.

## Ghi chú dependency

`swift-transformers` 1.x hiện không source-compatible với `swift-jinja` 2.4.0. Root package pin `swift-jinja` 2.3.6 để giữ build của `mlx-audio-swift` 0.1.3 ổn định; package này không được link trực tiếp vào target ứng dụng.
