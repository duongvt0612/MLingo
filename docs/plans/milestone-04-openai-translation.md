# Milestone 04 - Dịch bằng OpenAI

## Mục tiêu

Dịch transcript tiếng Anh sang tiếng Việt tự nhiên bằng OpenAI API, giữ tên riêng và thuật ngữ, không tóm tắt.

## Trạng thái hiện tại

- [x] Đã có `TranslationEngineProtocol`.
- [x] Đã có `OpenAITranslationEngine` gọi `https://api.openai.com/v1/responses`.
- [x] Đã có `TranslationPromptBuilder`.
- [x] Đã có `TranslationResponseParser`.
- [x] Đã có test parser, prompt, missing API key, request construction.
- [x] Đã parse HTTP/error body và map lỗi key, model, quota, rate limit, network, timeout, service.
- [x] Đã chốt non-streaming cho MVP; không cần streaming event parser trong milestone này.
- [x] Đã có worker dịch tuần tự không chặn Whisper, context 2 câu và queue backpressure.
- [x] Đã có Settings test dùng draft key/model mà không persist.
- [ ] Chưa test live API bằng API key thật.

## Các bước triển khai

- [x] Tạo protocol dịch `Transcript` thành `SubtitleItem`.
- [x] Tạo request tới OpenAI Responses API.
- [x] Lưu API key qua Keychain store, không hardcode.
- [x] Prompt yêu cầu giữ tên riêng, thuật ngữ, không tóm tắt.
- [x] Parse `output_text` và output content cơ bản.
- [x] Xác nhận model mặc định:
  - Dùng `gpt-5.4-mini` cho cài đặt mới; không migrate model user đã lưu.
  - Cho user sửa trong Settings.
- [x] Hoàn thiện request:
  - Timeout ngắn phù hợp subtitle.
  - `max_output_tokens: 2.048` cho transcript hiện tại tối đa 2.000 ký tự.
  - HTTP error body parse để hiện message tốt hơn.
  - Retry đúng 1 lần cho HTTP 429 rate-limit hoặc mọi HTTP 5xx; quota/billing 429 và lỗi permanent không retry.
- [x] Quyết định streaming hay non-streaming cho MVP:
  - Nếu streaming, parse event stream.
  - Nếu non-streaming đủ nhanh, giữ non-streaming để giảm phức tạp.
- [x] Thêm context window nhỏ:
  - Gửi tối đa 2 transcript gần nhất để hỗ trợ dịch tự nhiên hơn.
  - Context có tổng budget 2.000 ký tự và bỏ câu cũ nhất khi vượt budget.
- [x] Thêm cost/usage guard:
  - Không gửi transcript rỗng.
  - Dedupe trước khi translate.
  - Giới hạn độ dài mỗi request.
- [x] Hoàn thiện error UX:
  - Missing API key.
  - Invalid API key.
  - Network offline.
  - Quota/billing error.

## Tiêu chí hoàn thành

- [x] Unit test xác nhận missing API key.
- [x] Unit test xác nhận request có Authorization header.
- [x] Unit test xác nhận parser đọc response mẫu.
- [ ] Translate fixed transcript bằng API thật.
- [x] Lỗi API key/network/quota có message đọc được và có unit test.
- [x] Không gửi audio, chỉ gửi text transcript.
- [ ] Translation latency ban đầu đạt khoảng 300-800 ms cho câu ngắn.

## Test bắt buộc

```bash
rtk proxy swift test

# Optional live API verification; không chạy nếu thiếu key.
OPENAI_API_KEY=... rtk proxy swift test --filter openAITranslatesLiveFixtureWhenAPIKeyIsAvailable
```

Manual:

- [ ] Nhập API key hợp lệ.
- [ ] Dịch text fixture: `Let's deploy this service with Docker and PostgreSQL.`
- [ ] Xác nhận `Docker`, `PostgreSQL` được giữ nguyên.
- [ ] Thử API key sai và quota error nếu có điều kiện.

Automated:

- [x] Request có `store: false`, timeout 8 giây, output limit và không có audio.
- [x] Context chỉ gồm tối đa 2 transcript trước, có budget 2.000 ký tự.
- [x] Retry đúng 1 lần cho 429 rate-limit/mọi 5xx; quota/billing 429 và lỗi permanent pause riêng nhánh dịch, không retry.
- [x] Worker giữ thứ tự, không chặn Whisper và bỏ pending cũ nhất khi queue đầy.
- [x] `rtk proxy swift test` pass 88 tests ngày 2026-07-15 (live fixture không gọi API khi thiếu key).

## Rủi ro

- Streaming parser được defer khỏi MVP; chỉ cân nhắc lại sau khi có benchmark non-streaming.
- Model mặc định có thể thay đổi theo OpenAI docs/pricing; cần verify lại khi release.
