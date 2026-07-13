# Milestone 01 - Thiết lập project

## Mục tiêu

Tạo nền tảng project MLingo build/test được, có module boundary rõ ràng để các milestone sau chỉ việc điền implementation thật vào từng engine.

## Trạng thái hiện tại

- [x] Đã có `Package.swift`.
- [x] Đã có executable target `MLingoApp`.
- [x] Đã có library target `MLingoCore`.
- [x] Đã có test target `MLingoCoreTests`.
- [x] Đã có các folder chính: `App`, `Audio`, `Whisper`, `Translation`, `Overlay`, `Settings`, `Models`, `Utilities`.
- [ ] Chưa có source file riêng trong `Persistence`.
- [ ] Chưa có `.xcodeproj` thật.

## Các bước triển khai

- [x] Chốt entrypoint build hiện tại là Swift Package.
- [x] Tạo app target `MLingoApp`.
- [x] Tạo core target `MLingoCore`.
- [x] Tạo test target `MLingoCoreTests`.
- [x] Tạo hoặc cập nhật app metadata:
  - `Sources/MLingoApp/Resources/Info.plist`.
  - `Sources/MLingoApp/Resources/MLingo.entitlements`.
  - Bundle id mặc định: `com.duongvt.MLingo`.
- [x] Kiểm tra Swift 6 strict concurrency cho các protocol đi qua `Task`.
- [x] Đánh dấu UI-only overlay engine bằng `@MainActor`.
- [ ] Bổ sung folder/file `Persistence` nếu cần tách riêng SwiftData sau này.
- [ ] Tạo logging utility bằng `OSLog` với các category: `audio`, `whisper`, `translation`, `overlay`, `settings`, `pipeline`.
- [ ] Nếu bắt buộc cần Xcode project, tạo project thật trong Xcode hoặc bằng tool được phê duyệt.
- [ ] Không tạo `.xcodeproj` bằng tay nếu không verify được scheme.
- [ ] Xcode project phải tham chiếu đúng source hiện có, không duplicate file.

## Tiêu chí hoàn thành

- [x] `rtk proxy swift test` pass.
- [ ] `rtk proxy swift build` pass và được ghi nhận.
- [ ] App target có thể launch từ SwiftPM hoặc Xcode target thật.
- [x] Không có generated editor noise như `.vscode` được giữ lại sau validation.

## Test bắt buộc

```bash
rtk proxy swift build
rtk proxy swift test
```

## Rủi ro

- Fake `.xcodeproj` sẽ làm Xcode không có scheme, gây tốn thời gian debug sai.
- SwiftPM executable macOS app chưa thay thế đầy đủ cho release packaging; milestone 08 cần xử lý packaging thật.
