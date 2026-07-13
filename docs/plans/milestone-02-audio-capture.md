# Milestone 02 - Capture audio bằng ScreenCaptureKit

## Mục tiêu

Chứng minh MLingo bắt được system audio bằng ScreenCaptureKit mà không cần virtual audio device.

## Trạng thái hiện tại

- [x] Đã có `AudioEngineProtocol`.
- [x] Đã có `ScreenCaptureAudioEngine` dùng `SCShareableContent`, `SCStream`, `SCStreamOutput`.
- [x] Đã emit `AudioChunk` gồm samples, sample rate, channel count, timestamp, duration.
- [ ] Chưa verify với audio thực tế.
- [ ] Chưa có UI diagnostic cho RMS/chunk/dropped count.

## Các bước triển khai

- [x] Tạo protocol start/stop capture và stream `AudioChunk`.
- [x] Tạo ScreenCaptureKit engine boundary.
- [ ] Kiểm tra permission flow:
  - Nếu Screen Recording permission bị từ chối, hiện message có hành động rõ ràng.
  - Nếu cần restart app sau khi cấp permission, message phải nói rõ.
- [ ] Thêm diagnostic mode cho audio:
  - RMS level.
  - Chunk duration.
  - Sample rate.
  - Dropped/empty chunk count.
- [ ] Chuẩn hóa audio input:
  - Target sample rate: 16 kHz.
  - Target channel: mono.
  - Nếu ScreenCaptureKit trả format khác, thêm converter bằng `AVAudioConverter`.
- [ ] Thêm VAD tối thiểu:
  - Bỏ qua silence chunk bằng RMS threshold.
  - Ghi log threshold và tỷ lệ chunk bị bỏ qua.
- [ ] Tạo manual debug UI hoặc log path để xem audio level khi phất YouTube/VLC.
- [ ] Đảm bảo stop/cancel sạch:
  - `stop()` gọi `stopCapture`.
  - Không emit chunk sau khi stop.
  - Không leak stream/delegate.

## Tiêu chí hoàn thành

- [ ] Bắt được audio từ browser/YouTube.
- [ ] Bắt được audio từ VLC hoặc local video.
- [ ] RMS/diagnostic thay đổi theo audio thật.
- [ ] Stop/start lại nhiều lần không crash.
- [ ] Permission denied có UI/message để user tự sửa.

## Test bắt buộc

```bash
rtk proxy swift test
```

Manual:

- [ ] Start MLingo.
- [ ] Cấp Screen Recording permission nếu macOS hỏi.
- [ ] Mở YouTube, phát video tiếng Anh.
- [ ] Xác nhận diagnostic audio có chunk và RMS khác 0.
- [ ] Stop, start lại, xác nhận không crash.

## Rủi ro

- ScreenCaptureKit audio behavior khác nhau theo macOS version và permission.
- Format audio có thể không phải Float mono 16 kHz; nếu không convert đúng, Whisper sẽ sai hoặc latency cao.
