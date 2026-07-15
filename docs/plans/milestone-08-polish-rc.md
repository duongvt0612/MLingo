# Milestone 08 — Polish và Local Release Candidate

## Mục tiêu

Hoàn thiện MLingo thành bản RC dùng cục bộ trên Apple Silicon: native macOS `.app`, ad-hoc signing, sandbox tắt, UI daily-use gọn và lỗi có hành động phục hồi. Không notarize, không thêm future feature.

## Kết quả implementation

- [x] Thêm `MLingo.xcodeproj` với application target thật và shared scheme `MLingo`.
- [x] Target compile `Sources/MLingoApp`, link local package product `MLingoCore` và bundle package resources.
- [x] Bundle ID `com.duongvt.MLingo`, macOS 14+, arm64, version `0.1.0` build `1`.
- [x] Release dùng ad-hoc signing, hardened runtime off, App Sandbox off và `com.apple.security.cs.allow-jit = true`.
- [x] Giữ SwiftPM executable cho compile/test compatibility.
- [x] Thêm `scripts/build-local-rc.sh`; output app là `.build/release/MLingo.app`, archive trung gian nằm ở `.build/local-rc/MLingo.xcarchive` để không ghi đè thư mục build SwiftPM.
- [x] Script kiểm tra signature, arm64, bundle ID/version, entitlement, AppIcon và `mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib`.
- [x] Thêm AppIcon asset đầy đủ từ 16 đến 1024 px, tạo từ master deterministic: nền charcoal, caption cyan, hai dòng trắng, không text/emoji/SF Symbol.
- [x] Đổi `SubtitlePipeline.ErrorHandler` sang `@MainActor @Sendable (MLingoError) -> Void`; lỗi không định kiểu được wrap theo startup/Whisper/translation stage.
- [x] Giữ guard session ID để callback của session đã stop/restart không lọt sang session mới.
- [x] Thêm recovery mapping nội bộ, không parse message:
  - Permission/capture mở System Settings.
  - Credential/model/settings mở MLingo Settings.
  - Quota mở OpenAI API Usage.
  - Offline/permanent error khi đang chạy cho Stop và hướng dẫn restart sau khi khắc phục.
  - Rate limit/timeout/service error tạm thời cho dismiss, không đổi retry/drop policy.
- [x] Main window dùng status dot tĩnh; readiness, action và recovery banner luôn hiện.
- [x] Gom Audio, Transcription và Performance vào một `DisclosureGroup`, mặc định thu gọn.
- [x] Thêm command trong app:
  - Start Translation — `⌘↩`
  - Stop — `⌘.`
  - Show/Hide Overlay — `⇧⌘O`
  - Settings giữ menu chuẩn `⌘,`
- [x] Command được disable theo active mode; overlay command chỉ active trong Translation.
- [x] Viết lại README theo Xcode app target, local RC, permission backend, OpenAI Platform key, privacy boundary, troubleshooting và giới hạn ad-hoc build.
- [x] Xóa mô tả stale về streaming translation và overlay animation.

## Public interface

- [x] `SubtitlePipeline.ErrorHandler = @MainActor @Sendable (MLingoError) -> Void`.
- [x] `SubtitlePipeline.start(onError:)` nhận `ErrorHandler`.
- [x] Không đổi audio, translation, overlay, settings persistence hay OpenAI request contract.
- [x] Recovery presentation và command availability giữ internal trong `MLingoApp`.

## Kết quả validation tự động

- [x] `rtk proxy swift test` — **175 tests passed**.
- [x] `rtk proxy swift build -c release` — build succeeded.
- [x] Native Xcode Release build cho `generic/platform=macOS`, arm64 — `** BUILD SUCCEEDED **`.
- [x] `./scripts/build-local-rc.sh` — archive succeeded và tạo `.build/release/MLingo.app`.
- [x] Artifact có ad-hoc signature hợp lệ, Mach-O arm64, bundle ID/version đúng, AppIcon và `default.metallib`.
- [x] Artifact có App Sandbox `false`, allow-JIT `true`, không có `get-task-allow`.
- [x] `rtk proxy git diff --check` — passed sau khi cập nhật code và tài liệu.

SwiftPM còn warning upstream về file `MLXAudioVAD/Models/SileroVAD/README.md` chưa được khai báo resource. Warning này nằm ngoài source MLingo và ngoài scope milestone.

Xcode archive còn warning build-graph upstream `missing creator for mutated node` tại `mlx-swift_Cmlx.bundle/Contents/MacOS`; archive vẫn thành công và script đã xác minh `default.metallib` trong bundle.

Lệnh native build đã chạy:

```bash
rtk proxy xcodebuild \
  -project MLingo.xcodeproj \
  -scheme MLingo \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath .build/xcode-derived \
  -clonedSourcePackagesDirPath .build/xcode-packages \
  build \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGNING_REQUIRED=YES \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=YES \
  EXCLUDED_ARCHS=x86_64
```

## Manual acceptance chưa chạy

- [ ] Launch `.build/release/MLingo.app` như app mới.
- [ ] Cấp và kiểm tra System Audio Recording permission.
- [ ] Cấp và kiểm tra Screen Recording permission.
- [ ] Lưu/xóa/khởi động lại với API key thật trong Keychain.
- [ ] OpenAI translation end-to-end bằng API key thật.
- [ ] YouTube end-to-end.
- [ ] VLC end-to-end.
- [ ] Theme sau restart.
- [ ] Overlay trong fullscreen và trên display thứ hai.
- [ ] Keyboard và VoiceOver manual pass.

OpenAI live check cần API key thuộc OpenAI Platform, có billing/cost limit phù hợp và quyền xem Usage trong organization. Không dùng audio hoặc transcript thật của người dùng cho benchmark/manual fixture.

## Giới hạn RC

- Chỉ Apple Silicon, macOS 14+.
- Local ad-hoc build; không hardened runtime, notarization, DMG, PKG hay ZIP.
- Không onboarding, localization, analytics, updater, menu-bar mode hoặc global shortcut.
- Không thay đổi overlay geometry/persistence.
- Manual acceptance ở trên phải được người dùng chạy trước khi xem đây là RC đã nghiệm thu end-to-end.
