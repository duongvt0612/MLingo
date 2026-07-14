# Milestone 02 - Capture audio bằng ScreenCaptureKit

## Mục tiêu

Chứng minh MLingo bắt được system audio bằng ScreenCaptureKit mà không cần virtual audio device.

## Trạng thái hiện tại

- [x] Đã có `AudioEngineProtocol`.
- [x] Đã có `ScreenCaptureAudioEngine` dùng `SCShareableContent`, `SCStream`, `SCStreamOutput`.
- [x] Đã emit `AudioChunk` gồm samples, sample rate, channel count, timestamp, duration.
- [x] Đã có diagnostics stream cho RMS, peak, sample rate, channel count, chunk counters và capture state.
- [x] Đã có VAD tối thiểu với threshold mặc định `0.015`.
- [x] Đã chuẩn hóa output chunk về Float PCM mono 16 kHz.
- [ ] Chưa verify với audio thực tế.
- [x] Đã có UI diagnostic cho RMS/chunk/dropped count.
- [x] Đã có nút `Test Sound` riêng để test audio capture mà không chạy Whisper/OpenAI.

## Các bước triển khai

- [x] Tạo protocol start/stop capture và stream `AudioChunk`.
- [x] Tạo ScreenCaptureKit engine boundary.
- [x] Kiểm tra permission flow:
  - Nếu Screen Recording permission bị từ chối, hiện message có hành động rõ ràng.
  - Nếu cần restart app sau khi cấp permission, message phải nói rõ.
- [x] Thêm diagnostic mode cho audio:
  - RMS level.
  - Chunk duration.
  - Sample rate.
  - Dropped/empty chunk count.
- [x] Chuẩn hóa audio input:
  - Target sample rate: 16 kHz.
  - Target channel: mono.
  - Nếu ScreenCaptureKit trả format khác, thêm converter bằng `AVAudioConverter`.
- [x] Thêm VAD tối thiểu:
  - Bỏ qua silence chunk bằng RMS threshold.
  - Ghi log threshold và tỷ lệ chunk bị bỏ qua.
- [x] Tạo manual debug UI hoặc log path để xem audio level khi phát YouTube/VLC.
- [x] Tách chế độ test audio khỏi luồng dịch:
  - `Test Sound` chỉ start `ScreenCaptureAudioEngine`.
  - Không yêu cầu OpenAI API key.
  - Không gọi Whisper hoặc translation pipeline.
- [x] Đảm bảo stop/cancel sạch:
  - `stop()` gọi `stopCapture`.
  - Không emit chunk sau khi stop.
  - Không leak stream/delegate.

## Tiêu chí hoàn thành

- [ ] Bắt được audio từ browser/YouTube.
- [ ] Bắt được audio từ VLC hoặc local video.
- [ ] RMS/diagnostic thay đổi theo audio thật.
- [ ] Stop/start lại nhiều lần không crash.
- [x] Permission denied có UI/message để user tự sửa.

## Test bắt buộc

```bash
rtk proxy swift build
rtk proxy swift test
```

Unit tests hiện có:

- [x] RMS/peak tính đúng với sample fixture.
- [x] Silence chunk dưới threshold bị drop theo VAD.
- [x] Speech-like chunk trên threshold được nhận diện.
- [x] Diagnostics counters tăng đúng cho captured/dropped/empty.

Manual:

- [ ] Start MLingo.
- [ ] Cấp Screen Recording permission nếu macOS hỏi.
- [ ] Mở YouTube, phát video tiếng Anh.
- [ ] Xác nhận diagnostic audio có chunk và RMS khác 0.
- [ ] Stop, start lại, xác nhận không crash.

## Rủi ro

- ScreenCaptureKit audio behavior khác nhau theo macOS version và permission.
- Format audio có thể không phải Float mono 16 kHz; nếu không convert đúng, Whisper sẽ sai hoặc latency cao.
