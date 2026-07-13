# Milestone 06 - Settings và persistence

## Mục tiêu

Lưu cấu hình của user bền vững, an toàn cho API key, và khôi phục đúng khi mở lại app.

## Trạng thái hiện tại

- [x] Đã có `SettingsStoreProtocol`.
- [x] Đã có `UserDefaultsSettingsStore`.
- [x] Đã có `APIKeyStoreProtocol`.
- [x] Đã có `KeychainAPIKeyStore`.
- [x] Đã có settings UI bằng SwiftUI `Form`.
- [x] Đã có test round-trip settings bằng UserDefaults suite riêng.
- [ ] README ban đầu nói SwiftData, nhưng implementation hiện tại dùng UserDefaults cho preferences.
- [ ] Chưa có Keychain integration test.
- [ ] Chưa có validation đầy đủ trong UI.

## Các bước triển khai

- [x] Chốt API key lưu trong Keychain.
- [x] Chốt preferences nhỏ lưu trong UserDefaults cho MVP.
- [x] Tạo settings fields:
  - OpenAI API key.
  - OpenAI model.
  - Whisper model.
  - Subtitle font size.
  - Background opacity.
  - Theme.
  - Source/target language.
  - Bilingual toggle.
- [x] Load settings khi app launch/view task chạy.
- [x] Save settings từ Settings UI.
- [ ] Chốt lại persistence strategy trong README:
  - API key: Keychain.
  - Preferences nhỏ: UserDefaults.
  - SwiftData chỉ thêm khi có data model lớn hơn như history/vocabulary.
- [ ] Validation:
  - API key rỗng thì hiện warning trước khi start.
  - Font size trong range.
  - Opacity trong range.
  - Model name không rỗng.
- [ ] Optional autosave cho một số setting UI nếu cần.
- [ ] Diagnostics:
  - Hiện API key saved/not saved, không bao giờ hiện full key.
  - Hiện model đang dùng.
  - Hiện permission/capture state.

## Tiêu chí hoàn thành

- [ ] App restart vẫn giữ settings qua manual test.
- [x] API key không nằm trong UserDefaults theo code path hiện tại.
- [ ] Xóa API key trong UI thì Keychain item bị xóa qua manual test.
- [ ] Settings invalid không làm app crash.

## Test bắt buộc

```bash
rtk proxy swift test
```

Cần thêm tests:

- [ ] Keychain save/load/delete nếu chạy được trong test environment.
- [ ] Settings validation.
- [ ] ViewModel save/load với fake stores.

Manual:

- [ ] Nhập API key, quit app, mở lại.
- [ ] Đổi font size/opacity, quit app, mở lại.
- [ ] Xóa API key, xác nhận start báo missing key.

## Rủi ro

- Keychain trong sandbox/release có behavior khác debug.
- SwiftData thêm sớm có thể làm phức tạp migration khi chưa cần.
