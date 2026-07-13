# Milestone 03 - Transcription bằng MLX Whisper

## Mục tiêu

Thay `MLXWhisperEngine` placeholder bằng inference thật trên Apple Silicon, local-only, không embed Python runtime.

## Trạng thái hiện tại

- [x] Đã có `WhisperEngineProtocol`.
- [x] Đã có `MLXWhisperEngine`.
- [x] Đã có `FixtureWhisperEngine` cho test pipeline.
- [ ] `MLXWhisperEngine` hiện mới load model name và ném diagnostic `whisperIntegrationPending`.
- [ ] Chưa có tokenizer/model inference thật.
- [ ] Chưa có fixture audio transcription thật.

## Các bước triển khai

- [x] Tạo protocol `loadModel(named:)` và `transcribe(_:)`.
- [x] Tạo fake/fixture engine để test pipeline không phụ thuộc model nặng.
- [ ] Chọn dependency chính:
  - Ưu tiên `mlx-swift` và code tham khảo từ MLX Whisper examples.
  - Ghi rõ version/commit trong `Package.swift` hoặc docs.
- [ ] Thêm package dependency MLX core Swift package.
- [ ] Thêm tokenizer/audio helper cần thiết.
- [ ] Port minimum Whisper path:
  - Load model weights.
  - Load tokenizer.
  - Audio mel spectrogram.
  - Decode transcript tiếng Anh.
- [ ] Bắt đầu bằng fixture audio file.
- [ ] Thêm sample audio ngắn trong test resources nếu license cho phép.
- [ ] Test `transcribe(file)` trước khi streaming.
- [ ] Nối rolling audio window:
  - Gom `AudioChunk` thành cửa sổ 1-3 giây.
  - Overlap nhỏ để tránh mất từ.
  - Trả `Transcript` có timestamp đúng.
- [ ] Xử lý duplicate transcript:
  - Bỏ qua transcript rỗng.
  - Bỏ qua transcript gần trùng với transcript gần nhất.
  - Giữ stable id và timestamp.
- [ ] Thêm UI diagnostics:
  - Model loading.
  - Model ready.
  - Last transcript.
  - Whisper latency.

## Tiêu chí hoàn thành

- [ ] Fixture audio tiếng Anh transcribe ra text chấp nhận được.
- [ ] Live audio window tạo được `Transcript`.
- [ ] Speech recognition chạy local, không gửi audio ra network.
- [ ] Latency ASR ban đầu đạt khoảng 500-1200 ms cho window ngắn.

## Test bắt buộc

```bash
rtk proxy swift test
```

Manual:

- [ ] Load model mặc định.
- [ ] Chạy fixture audio.
- [ ] Phát video tiếng Anh ngắn.
- [ ] Xác nhận transcript log hiện đúng thứ tự và không spam duplicate.

## Rủi ro

- MLX/Metal build có thể cần Xcode target thật, không chỉ SwiftPM.
- Model/tokenizer port có thể là phần khó nhất của MVP.
- Whisper small có thể latency cao; cần benchmark tiny/base/small.
