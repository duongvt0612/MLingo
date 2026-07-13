# Milestone 05 - Floating subtitle overlay

## Mục tiêu

Render phụ đề dịch lên cửa sổ nổi always-on-top, đọc được trên mọi app và không cần focus app MLingo.

## Trạng thái hiện tại

- [x] Đã có `OverlayEngineProtocol`.
- [x] Đã có `FloatingSubtitleWindowController` dùng `NSPanel`.
- [x] Đã có `SubtitleOverlayView` SwiftUI.
- [x] Đã có font size, opacity, bilingual toggle trong settings model.
- [ ] Chưa manual test overlay trên app fullscreen.
- [ ] Chưa lưu vị trí overlay.
- [ ] Chưa chọn display khi có nhiều màn hình.

## Các bước triển khai

- [x] Tạo `NSPanel` borderless, background trong suốt.
- [x] Set level `.floating`.
- [x] Set collection behavior để join spaces và hỗ trợ fullscreen auxiliary.
- [x] Render subtitle bằng SwiftUI view.
- [x] Dùng font size và opacity từ settings.
- [ ] Kiểm tra NSPanel behavior:
  - Always on top.
  - Can join all spaces.
  - Full screen auxiliary.
  - Không chiếm focus khi update subtitle.
- [ ] Position:
  - Mặc định ở đáy màn hình.
  - Cho user kéo panel.
  - Lưu vị trí theo display nếu cần.
- [ ] Multi-display:
  - Chọn display hiện tại/mặc định.
  - Nếu video ở display khác, có setting chọn display.
- [ ] Readability:
  - Text trắng, shadow/outline.
  - Nền đen trong suốt có opacity.
  - Auto resize theo nội dung nhưng không tràn màn hình.
- [ ] Interaction:
  - Toggle show/hide overlay.
  - Không che thao tác app khác quá mức.
  - Có shortcut start/stop.
- [ ] Accessibility:
  - Accessibility label cho subtitle.
  - Respect reduced motion.
  - Không dùng animation gây distraction.

## Tiêu chí hoàn thành

- [ ] Phụ đề hiện trên YouTube/VLC/browser.
- [ ] Đọc được trên nền sáng và nền tối.
- [ ] Start/stop không tạo nhiều panel rác.
- [ ] Kéo panel không crash, update subtitle vẫn đúng.

## Test bắt buộc

```bash
rtk proxy swift test
```

Manual:

- [ ] Mở video fullscreen.
- [ ] Start MLingo.
- [ ] Xác nhận overlay nằm trên video.
- [ ] Đổi font size/opacity trong Settings.
- [ ] Thử trên display thứ hai nếu có.

## Rủi ro

- `NSPanel` behavior trong fullscreen app có thể cần tinh chỉnh collection behavior.
- Overlay có thể chặn click của app bên dưới nếu `ignoresMouseEvents` không đúng theo mode.
