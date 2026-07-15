# Milestone 05 - Floating subtitle overlay

## Mục tiêu

Render phụ đề dịch bằng một `NSPanel` always-on-top, click-through khi xem và có HUD trực tiếp để reposition mà không cần focus lại MLingo khi subtitle cập nhật.

## Kết quả triển khai

- [x] `FloatingSubtitleWindowController` tạo và tái sử dụng đúng một panel.
- [x] Start session xóa subtitle cũ; Stop/Hide thoát edit mode, clear nội dung và hide panel.
- [x] Manual Hide chỉ áp dụng cho session hiện tại; subtitle mới vẫn update state nhưng không tự hiện panel lại.
- [x] Normal mode dùng `ignoresMouseEvents`; edit mode bật interaction và HUD gồm Done, Reset Position và Display.
- [x] Header có menu Overlay cho Show/Hide, Reposition, Reset Position và Move to Display; menu chỉ active khi translation đang chạy.
- [x] `OverlayPresentationState` được dùng chung qua controller, pipeline và ViewModel.
- [x] Settings/Subtitles có picker Overlay display; draft đồng bộ khi HUD đổi display trong live session.
- [x] Display preference dùng Core Graphics display UUID, hỗ trợ Automatic theo cửa sổ MLingo và fallback main display.
- [x] Vị trí được lưu theo từng display dưới dạng normalized center-X/bottom-Y và debounce sau khi kéo.
- [x] Thay đổi resolution, Dock hoặc menu bar resolve lại theo `visibleFrame` và clamp panel vào màn hình.
- [x] Display bị disconnect fallback sang automatic resolution nhưng giữ preferred UUID để dùng lại khi reconnect.
- [x] Preferences malformed chỉ reset overlay preferences, không ảnh hưởng AppSettings hoặc API key.
- [x] Kích thước giới hạn ở `min(980 pt, 82% visibleFrame)` và tối đa 40% chiều cao; resize giữ bottom anchor.
- [x] Translated tối đa 3 dòng, original tối đa 2 dòng, scale factor 0.75; original dùng 58% font size.
- [x] Text trắng có shadow nhẹ, nền đen dùng opacity setting và không animation khi subtitle đổi.
- [x] Accessibility label chứa original và translated khi bật bilingual.

## Public interfaces

- [x] Thêm `OverlayDisplaySelection`, `OverlayDisplayDescriptor`, `OverlayPlacement`, `OverlayPreferences`, `OverlayPresentationState` và `OverlayPreferencesStoreProtocol`.
- [x] Mở rộng `OverlayEngineProtocol` với presentation state và các lệnh show/visibility/reposition/reset/display.
- [x] `SubtitlePipeline` proxy overlay commands và chỉ mở overlay trong translation mode.
- [x] `MLingoViewModel` expose shared state cùng actions cho Header và Settings.

## Automated tests

- [x] Preferences round-trip và malformed-data fallback.
- [x] Default placement, normalized round-trip, resolution change và visible-frame clamping.
- [x] Preferred/Automatic display, disconnect fallback và reconnect.
- [x] Controller tái sử dụng panel; hidden update không tự hiện lại; session mới không hiện subtitle stale.
- [x] Normal/edit mouse behavior, Done/Hide cleanup, display selection và dragged placement persistence.
- [x] Debounced placement không ghi đè display selection mới hơn.
- [x] Content resize giữ bottom anchor và không vượt visible frame.
- [x] Pipeline/ViewModel lifecycle, mode guard, shared state và command routing.

Validation ngày 2026-07-15:

```text
rtk proxy swift test       # 115 tests passed
rtk proxy swift build      # passed
rtk proxy git diff --check # passed
```

SwiftPM vẫn báo hai warning baseline: dependency `swift-jinja` chưa được target nào dùng và README của `MLXAudioVAD` chưa được khai báo resource/exclude.

## Manual acceptance còn lại

- [ ] Browser/YouTube và VLC fullscreen.
- [ ] Click-through normal mode và kéo/HUD edit mode trên app thực.
- [ ] Video sáng/tối; bilingual; font 18/64; opacity 20/90; subtitle dài.
- [ ] Keyboard, VoiceOver và reduced motion.
- [ ] Display thứ hai và disconnect/reconnect với phần cứng thực.

Các mục manual trên chưa được đánh dấu hoàn thành vì môi trường validation hiện tại không xác nhận fullscreen app, VoiceOver hoặc display vật lý thứ hai.

## Ngoài phạm vi

- Không thêm dependency, localization, overlay preview hoặc global hotkey mới.
- Overlay không tự dò display chứa video và không follow pointer.
- Visibility không persist qua session; display preference và vị trí được persist.
