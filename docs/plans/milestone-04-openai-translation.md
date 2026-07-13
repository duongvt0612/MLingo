# Milestone 04 - Dịch bằng OpenAI

## Mục tiêu

Dịch transcript tiếng Anh sang tiếng Việt tự nhiên bằng OpenAI API, giữ tên riêng và thuật ngữ, không tóm tắt.

## Trạng thái hiện tại

- [x] Đã có `TranslationEngineProtocol`.
- [x] Đã có `OpenAITranslationEngine` gọi `https://api.openai.com/v1/responses`.
- [x] Đã có `TranslationPromptBuilder`.
- [x] Đã có `TranslationResponseParser`.
- [x] Đã có test parser, prompt, missing API key, request construction.
- [ ] Chưa parse error body chi tiết.
- [ ] Chưa có streaming event parser.
- [ ] Chưa test live API bằng API key thật.

## Các bước triển khai

- [x] Tạo protocol dịch `Transcript` thành `SubtitleItem`.
- [x] Tạo request tới OpenAI Responses API.
- [x] Lưu API key qua Keychain store, không hardcode.
- [x] Prompt yêu cầu giữ tên riêng, thuật ngữ, không tóm tắt.
- [x] Parse `output_text` và output content cơ bản.
- [ ] Xác nhận model mặc định:
  - Dùng model nhanh/chi phí hợp lý cho subtitle.
  - Cho user sửa trong Settings.
- [ ] Hoàn thiện request:
  - Timeout ngắn phù hợp subtitle.
  - HTTP error body parse để hiện message tốt hơn.
  - Retry có giới hạn cho lỗi tạm thời 429/5xx nếu cần.
- [ ] Quyết định streaming hay non-streaming cho MVP:
  - Nếu streaming, parse event stream.
  - Nếu non-streaming đủ nhanh, giữ non-streaming để giảm phức tạp.
- [ ] Thêm context window nhỏ:
  - Gửi thêm 1-3 transcript gần nhất nếu cần dịch tự nhiên hơn.
  - Không để context làm chậm quá mức.
- [ ] Thêm cost/usage guard:
  - Không gửi transcript rỗng.
  - Dedupe trước khi translate.
  - Giới hạn độ dài mỗi request.
- [ ] Hoàn thiện error UX:
  - Missing API key.
  - Invalid API key.
  - Network offline.
  - Quota/billing error.

## Tiêu chí hoàn thành

- [x] Unit test xác nhận missing API key.
- [x] Unit test xác nhận request có Authorization header.
- [x] Unit test xác nhận parser đọc response mẫu.
- [ ] Translate fixed transcript bằng API thật.
- [ ] Lỗi API key/network/quota có message đọc được.
- [ ] Không gửi audio, chỉ gửi text transcript.
- [ ] Translation latency ban đầu đạt khoảng 300-800 ms cho câu ngắn.

## Test bắt buộc

```bash
rtk proxy swift test
```

Manual:

- [ ] Nhập API key hợp lệ.
- [ ] Dịch text fixture: `Let's deploy this service with Docker and PostgreSQL.`
- [ ] Xác nhận `Docker`, `PostgreSQL` được giữ nguyên.
- [ ] Thử API key sai và quota error nếu có điều kiện.

## Rủi ro

- Streaming parser phức tạp hơn non-streaming.
- Model mặc định có thể thay đổi theo OpenAI docs/pricing; cần verify lại khi release.
