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
- [x] README đã chốt UserDefaults cho preferences, Keychain cho credential; SwiftData để dành cho history/vocabulary tương lai.
- [x] Có Keychain unit tests với Security client fake và integration test opt-in bằng namespace UUID riêng.
- [x] Có shared validation cho UI, ViewModel và persistence.

## Các bước triển khai

- [x] Chốt API key lưu trong Keychain.
- [x] Chốt preferences nhỏ lưu trong UserDefaults cho MVP.
- [x] Tạo settings fields:
  - OpenAI API key.
  - OpenAI model.
  - Whisper model.
  - Subtitle font name.
  - Subtitle font size.
  - Background opacity.
  - Text opacity.
  - Theme.
  - Source/target language.
  - Bilingual toggle.
- [x] Load settings khi app launch/view task chạy.
- [x] Save settings từ Settings UI.
- [x] Chốt lại persistence strategy trong README:
  - API key: Keychain.
  - Preferences nhỏ: UserDefaults.
  - SwiftData chỉ thêm khi có data model lớn hơn như history/vocabulary.
- [x] Validation dùng chung:
  - Trim model, language và font name.
  - Bắt buộc Whisper/OpenAI model, source/target language và font name.
  - Font size `18...64`, background opacity `0.2...0.9`, text opacity `0...1`.
  - API key rỗng vẫn được Save để xóa credential, nhưng chặn Start Translate trước khi audio/Whisper khởi động.
- [x] Giữ Save/Cancel draft flow; không autosave và Cancel không preview theme.
- [x] Diagnostics:
  - Hiện API key saved/not saved, không bao giờ hiện full key.
  - Hiện model đang dùng.
  - Hiện permission/capture state.
- [x] Persisted preferences legacy được repair theo field và ghi lại; JSON root hỏng bị xóa rồi fallback defaults.
- [x] Keychain read/add/update/delete phân biệt not-found và failure, map sang typed credential error.
- [x] Preferences và credential load độc lập; save credential được rollback best-effort nếu preferences save lỗi.
- [x] System/Light/Dark áp dụng cho main window và Settings sau load/Save.

## Tiêu chí hoàn thành

- [ ] App restart vẫn giữ settings qua manual test.
- [x] API key không nằm trong UserDefaults theo code path hiện tại.
- [ ] Xóa API key trong UI thì Keychain item bị xóa qua manual test.
- [x] Settings invalid bị reject trước khi UserDefaults hoặc Keychain bị ghi.

## Test bắt buộc

```bash
rtk proxy swift test
```

Có automated coverage:

- [x] Settings validation, normalization và deterministic first error.
- [x] UserDefaults round-trip, legacy repair, malformed root và payload không chứa API key.
- [x] Keychain found/not-found/failure, add/update/delete và không add sau lookup error.
- [x] ViewModel load độc lập, key unchanged/delete, rollback và translation preflight.
- [x] Transcription Test không yêu cầu API key.
- [ ] Keychain integration test thực tế; chỉ chạy khi `MLINGO_RUN_KEYCHAIN_INTEGRATION_TESTS=1` và luôn cleanup.
- [x] `rtk proxy swift test` — 145 tests pass.
- [x] `rtk proxy swift build`.
- [x] `rtk proxy git diff --check`.

Manual:

- [ ] Nhập API key, quit app, mở lại.
- [ ] Đổi font size/opacity, quit app, mở lại.
- [ ] Xóa API key, xác nhận start báo missing key.
- [ ] Light/Dark/System sau Save và restart; Cancel không đổi theme.
- [ ] Keyboard, VoiceOver và Keychain trong release/sandbox.

## Rủi ro

- Keychain trong sandbox/release có behavior khác debug.
- SwiftData thêm sớm có thể làm phức tạp migration khi chưa cần.
