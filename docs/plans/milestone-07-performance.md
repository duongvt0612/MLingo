# Milestone 07 - Tối ưu hiệu năng

## Mục tiêu

Đạt latency tổng thể 1-2 giây và đảm bảo app chạy ổn định trong thời gian dài.

## Trạng thái hiện tại

- [x] Đã có pipeline async.
- [x] Đã có subtitle queue.
- [ ] Chưa có metrics latency.
- [ ] Chưa có OSLog signposts.
- [ ] Chưa benchmark CPU/memory.
- [ ] Chưa test chạy dài.

## Các bước triển khai

- [x] Tạo pipeline async cơ bản.
- [x] Tạo queue để bỏ duplicate/stale subtitle.
- [ ] Thêm metrics:
  - Audio chunk timestamp.
  - Whisper start/end.
  - Translation start/end.
  - Overlay render time.
  - Total transcript-to-subtitle latency.
- [ ] Thêm OSLog signposts nếu phù hợp:
  - `audio.capture`.
  - `whisper.decode`.
  - `translation.request`.
  - `overlay.render`.
- [ ] Tune audio chunk/window:
  - Window 1-3 giây.
  - Overlap vừa đủ để không mất từ.
  - Silence skip bằng VAD.
- [ ] Backpressure:
  - Nếu Whisper chậm, không để audio queue tăng vô hạn.
  - Nếu Translation chậm, drop hoặc merge stale transcript.
  - Cancel sạch khi user stop.
- [ ] Model selection:
  - Benchmark tiny/base/small.
  - Chọn default dựa trên latency/accuracy.
- [ ] Long-run stability:
  - Chạy 1 giờ với video/meeting audio.
  - Theo dõi CPU, memory, queue size.

## Tiêu chí hoàn thành

- [ ] p95 total latency dưới 2 giây trong test thực tế.
- [ ] Render update dưới 100 ms.
- [ ] Chạy 1 giờ không memory growth bất thường.
- [ ] Stop/start lại nhiều lần không leak stream/task.

## Test bắt buộc

```bash
rtk proxy swift test
```

Manual/performance:

- [ ] Chạy video 15 phút, ghi p50/p95 latency.
- [ ] Chạy 1 giờ, theo dõi Activity Monitor.
- [ ] Stop/start 10 lần.

## Rủi ro

- Whisper model lớn có thể vượt latency target.
- Translation network latency không ổn định; cần fallback/queue policy rõ.
- Overlap audio quá lớn có thể tạo duplicate transcript.
