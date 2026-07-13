# Milestone 08 - Polish và release candidate

## Mục tiêu

Biến vertical slice đã chạy thật thành bản MVP có thể dùng hằng ngày: permission UX rõ, app packaging ổn, UI gọn, release build validate.

## Trạng thái hiện tại

- [x] App shell đã có giao diện cơ bản.
- [x] Đã có `Info.plist` và entitlements resource.
- [ ] Chưa có app icon.
- [ ] Chưa có release packaging.
- [ ] Chưa có Xcode project/native archive target thật.
- [ ] Chưa có README build/run đầy đủ.

## Các bước triển khai

- [x] Tạo UI shell cơ bản với Start/Stop, Settings, status, diagnostics.
- [x] Tạo settings form native bằng SwiftUI `Form`.
- [ ] Permission UX:
  - Screen Recording permission guide.
  - API key missing guide.
  - Network/quota error guide.
- [ ] App shell polish:
  - Menu commands: Start, Stop, Settings, Show/Hide Overlay.
  - Keyboard shortcuts.
  - Status indicator gọn, không marketing.
- [ ] Visual polish:
  - Native macOS spacing.
  - Form sections gọn.
  - Overlay readable.
  - Không dùng emoji icon.
- [ ] Packaging:
  - Tạo Xcode project/target thật nếu cần archive `.app`.
  - Gắn bundle id `com.duongvt.MLingo`.
  - Gắn Info.plist và entitlements đúng target.
  - Validate release build.
- [ ] Manual acceptance:
  - YouTube.
  - Netflix/Coursera/Udemy nếu có access.
  - Zoom/Google Meet.
  - VLC.
  - Podcast/browser audio.
- [ ] Documentation:
  - Update README cách build/run.
  - Ghi permissions cần cấp.
  - Ghi API key yêu cầu OpenAI Platform, không phải ChatGPT subscription.

## Tiêu chí hoàn thành

- [ ] User có thể build/run app theo README.
- [ ] Release build tạo được `.app`.
- [ ] MVP chạy được pipeline end-to-end trên ít nhất YouTube và VLC.
- [ ] Lỗi thường gặp có message để user tự xử lý.
- [ ] Không có future features chen vào MVP.

## Test bắt buộc

```bash
rtk proxy swift test
rtk proxy swift build -c release
```

Nếu có Xcode project:

```bash
rtk proxy xcodebuild -scheme MLingo -configuration Release build
```

Manual:

- [ ] Cài/chạy app mới.
- [ ] Cấp permission.
- [ ] Nhập API key.
- [ ] Start subtitle với video tiếng Anh.
- [ ] Stop app, mở lại, settings còn được lưu.

## Rủi ro

- Packaging macOS cần signing/notarization nếu muốn distribute ngoài máy local.
- App sandbox có thể ảnh hưởng ScreenCaptureKit/Keychain/MLX; cần quyết định sandbox cho release.
