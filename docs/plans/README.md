# Kế hoạch triển khai MVP MLingo

Bộ tài liệu này chia MVP thành 8 milestone riêng. Mỗi milestone có file riêng để triển khai tuần tự, tránh nhảy sang polish khi pipeline lõi chưa chạy thật.

## Trạng thái hiện tại

- [x] Đã có Swift package build được qua `Package.swift`.
- [x] Đã có app shell SwiftUI, settings form, Keychain API key store, OpenAI translation boundary, ScreenCaptureKit audio boundary, overlay NSPanel boundary, và subtitle queue.
- [x] `rtk proxy swift test` đang pass với 8 tests.
- [ ] Chưa có `MLingo.xcodeproj` thật.
- [ ] Chưa có MLX Whisper inference/tokenizer thật.
- [ ] Chưa verify live audio capture bằng app thực tế như YouTube, VLC, Zoom hoặc Google Meet.

## Thứ tự milestone

1. [Milestone 01 - Thiết lập project](./milestone-01-project-setup.md)
2. [Milestone 02 - Capture audio bằng ScreenCaptureKit](./milestone-02-audio-capture.md)
3. [Milestone 03 - Transcription bằng MLX Whisper](./milestone-03-mlx-whisper.md)
4. [Milestone 04 - Dịch bằng OpenAI](./milestone-04-openai-translation.md)
5. [Milestone 05 - Floating subtitle overlay](./milestone-05-floating-overlay.md)
6. [Milestone 06 - Settings và persistence](./milestone-06-settings-persistence.md)
7. [Milestone 07 - Tối ưu hiệu năng](./milestone-07-performance.md)
8. [Milestone 08 - Polish và release candidate](./milestone-08-polish-rc.md)

## Nguyên tắc triển khai

- Làm theo hướng risk-first: audio capture và Whisper thật phải được chứng minh trước khi polish UI.
- Mỗi milestone kết thúc bằng test hoặc manual verification rõ ràng.
- Không lưu OpenAI API key trong SwiftData hoặc UserDefaults; chỉ lưu trong Keychain.
- Speech recognition chạy local; chỉ transcript text được gửi lên OpenAI.
- Không thêm future features vào MVP: vocabulary, OCR, offline translation, meeting mode, Safari extension.

## Lệnh kiểm tra chung

```bash
rtk proxy swift test
rtk proxy swift build
```

Nếu cần build qua Xcode, phải tạo target/project thật thay vì fake `.xcodeproj`.
