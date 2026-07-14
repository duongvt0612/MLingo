# Milestone 03 - Transcription bằng MLX Whisper

## Mục tiêu

Thay `MLXWhisperEngine` placeholder bằng inference native Swift trên Apple Silicon, local-only và không embed Python runtime.

## Trạng thái triển khai

- [x] Swift tools 6.3, phù hợp với `mlx-swift` 0.31.6 đã resolve; pin chính xác `mlx-audio-swift` 0.1.3.
- [x] Chỉ liên kết `MLXAudioCore` và `MLXAudioSTT` vào `MLingoCore`.
- [x] `MLXWhisperEngine` là actor, dùng `WhisperModel.fromPretrained` và cache model đang load.
- [x] Model mặc định `mlx-community/whisper-base-mlx`.
- [x] Migrate chính xác model cũ `mlx-community/whisper-small` sang `mlx-community/whisper-small-mlx`.
- [x] Ép source language, bỏ transcript rỗng và ánh xạ lỗi load/inference.
- [x] Adaptive window: tìm speech boundary yên ít nhất 0,1 giây gần mốc 1,5 giây để cắt không overlap; chỉ giữ overlap 0,4 giây khi speech liên tục chạm hard limit 3 giây.
- [x] Inference tuần tự, dedupe exact/near-duplicate và suffix/prefix overlap.
- [x] Session cancellation chặn callback transcript/diagnostics cũ sau stop/restart.
- [x] Pipeline có hai mode `.transcriptionOnly` và `.translation`.
- [x] Test Transcription không gọi OpenAI và không mở overlay.
- [x] ViewModel dùng một active mode duy nhất cho idle, sound test, transcription test và translation.
- [x] Status panel hiển thị model state, model ID, transcript cuối, window duration, latency, processed và duplicate count.
- [x] Fixture `jfk.flac` có attribution và test MLX thật dạng opt-in.
- [x] Mỗi capture session tạo engine và `AsyncStream` mới; Stop → Start không tái sử dụng stream đã terminated.
- [x] macOS 14.2+ dùng Core Audio Process Tap; macOS 14.0–14.1 fallback ScreenCaptureKit audio-only.
- [x] Settings cho phép chọn System Audio hoặc Screen Recording; sound test và cả hai pipeline mode dùng chung lựa chọn.

## Quyền riêng tư và tải model

Audio samples chỉ đi từ backend người dùng chọn — Core Audio Process Tap hoặc ScreenCaptureKit audio-only — đến MLX Whisper trong process của ứng dụng. MLingo không upload audio. Trên macOS 14.2+, ứng dụng không tự fallback sang Screen Recording nếu System Audio bị từ chối; người dùng phải chọn backend Screen Recording trong Settings. Trên macOS 14.0–14.1, Process Tap không khả dụng nên factory dùng ScreenCaptureKit. Lần đầu load model/tokenizer, thư viện có thể tải artifact từ Hugging Face; các lần sau dùng cache cục bộ và cùng model ID được reuse trong memory.

Hai ID do MLingo quản lý (`whisper-base-mlx` và `whisper-small-mlx`) hiện trỏ tới repository legacy chỉ có `weights.npz`, trong khi loader 0.1.3 nhận `safetensors`. Backend resolve chúng sang mirror F16 tương ứng (`*-asr-fp16`, khoảng 144 MB cho base) lúc load. Giá trị settings và custom model ID không bị rewrite.

Binary tạo bởi `swift run` không chứa Metal resource của `mlx-swift`. Backend kiểm tra resource trước khi tải model và trả lỗi có hướng dẫn, tránh để MLX C++ abort sau khi download. Manual transcription phải chạy bằng scheme `MLingo`; GPU integration test dùng scheme `MLingo-Package` trong Xcode.

## Test

Test mặc định không tải model:

```bash
swift test
```

Test MLX thật với fixture JFK được gate bằng biến môi trường:

```bash
MLINGO_RUN_MLX_INTEGRATION=1 swift test --filter MLXWhisperIntegrationTests
```

`mlx-swift` xác nhận SwiftPM command-line không tự build Metal shaders. Command trên chỉ chạy GPU inference nếu bundle chứa `default.metallib` đã có trong build products. Trên máy sạch, cài Metal Toolchain trước:

```bash
xcodebuild -downloadComponent MetalToolchain
```

Sau đó dùng Xcode trực tiếp với `Package.swift` (không cần tạo `.xcodeproj`):

```bash
xcodebuild test \
  -scheme MLingo-Package \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:MLingoCoreTests \
  -skipPackagePluginValidation \
  OTHER_SWIFT_FLAGS='$(inherited) -DMLINGO_RUN_MLX_INTEGRATION'
```

Scheme `MLingo-Package` tự compile shader từ source của dependency và tạo `mlx-swift_Cmlx.bundle/default.metallib` trong build products cạnh test bundle; không cần copy artifact thủ công hoặc dựa vào một `.metallib` có sẵn. Compilation condition bật test opt-in bên trong Xcode test process; prefix biến môi trường trước `xcodebuild` không được test runner kế thừa. Test GPU integration dùng Hugging Face cache bình thường để xác nhận load và inference mà không bắt buộc download lại model đã có.

Test download/load từ cache tạm trống được gate riêng để không download lại model khi chỉ nghiệm thu GPU inference. Chạy cùng command trên nhưng đổi compilation condition thành `-DMLINGO_RUN_MLX_DOWNLOAD_INTEGRATION`.

Kết quả được chấp nhận khi transcript, không phụ thuộc dấu câu, chứa:

```text
ask not what your country can do for you
```

## Nghiệm thu manual

- [ ] Lần đầu hiển thị Loading rồi Ready; lần sau reuse cache.
- [ ] Test Transcription chạy khi không có OpenAI API key và không mở overlay.
- [ ] YouTube/VLC tạo transcript đúng thứ tự, không spam duplicate.
- [ ] Stop/start nhiều lần không crash và không nhận callback session cũ.
- [ ] Chuyển qua lại System Audio/Screen Recording, Stop/start mỗi backend ít nhất 5 lần vẫn nhận meter trong 1 giây và status panel hiển thị đúng backend.
- [ ] Lỗi mạng/model hiển thị rõ và có thể thử lại.
- [ ] Sau warm-up trên M4 Pro, benchmark ít nhất 10 window: median ≤ 1.200 ms, p95 ≤ 2.000 ms; không tính model load.

Verification trên máy phát triển hiện tại đã cài Metal Toolchain, load model F16 từ cache và chạy GPU integration với fixture JFK thành công. Test download từ cache trống vẫn phụ thuộc khả năng truy cập Hugging Face/Xet CDN tại thời điểm chạy.

## Ghi chú dependency

`swift-transformers` 1.x hiện không source-compatible với `swift-jinja` 2.4.0. Root package pin `swift-jinja` 2.3.6 để giữ build của `mlx-audio-swift` 0.1.3 ổn định; package này không được link trực tiếp vào target ứng dụng.
