# Milestone 07 - Performance và Stability

## Mục tiêu

Đo latency end-to-end bằng monotonic clock, quan sát CPU/RSS và queue trong app,
đồng thời cung cấp benchmark opt-in để kiểm tra mục tiêu p95 dưới 2 giây mà không
làm test mặc định phụ thuộc network hoặc phần cứng MLX.

Latency tổng được tính từ audio speech-bearing cuối cùng góp vào transcript đến
khi overlay render hoàn tất. Media timestamp của CoreAudio và ScreenCaptureKit
không được dùng để trừ trực tiếp với monotonic clock.

## Kết quả triển khai

- [x] Thêm `LatencyStatistics` và `PipelinePerformanceDiagnostics` public.
- [x] Tracker theo session giữ tối đa 4.096 mẫu và tính latest/p50/p95 bằng
  nearest-rank cho audio/backlog, Whisper, translation queue, OpenAI, overlay và
  total latency.
- [x] Speech capture anchor được giữ dạng sidecar qua pre-roll, silence flush,
  overlap, timestamp discontinuity và pending-window coalescing; `AudioChunk`
  không đổi contract.
- [x] Duplicate, overflow, failed request và cancellation không đi vào total
  percentile; queue/drop counters vẫn được cập nhật.
- [x] Stop/restart hủy publisher, xóa trace/samples và loại callback session cũ.
- [x] Thêm OSLog intervals `audio.capture`, `whisper.decode`,
  `translation.request`, `overlay.render`; metadata chỉ chứa trace ID, duration
  và queue depth, không chứa transcript, audio hoặc credential.
- [x] Sample process CPU/RSS mỗi giây bằng `proc_pid_rusage`; một core tương ứng
  100% CPU và sampling failure không dừng pipeline.
- [x] Main window có panel Performance diagnostics, cập nhật tối đa 1 Hz, hỗ
  trợ VoiceOver và không dùng animation/chart.
- [x] Transcription-only vẫn hiển thị Whisper/resource metrics; Stop giữ snapshot
  cuối và session kế tiếp reset panel.
- [x] Giữ nguyên window `1.5s` preferred, `3s` maximum, overlap `0.4s`, Whisper
  pending cap `9s` và translation FIFO tối đa 8.
- [x] Giữ default `mlx-community/whisper-base-mlx`; không migrate model đã lưu.

## Public interfaces

- `LatencyStatistics: Equatable, Sendable` gồm `latest`, `p50`, `p95` và
  `sampleCount`.
- `PipelinePerformanceDiagnostics: Equatable, Sendable` gồm stage latencies,
  session duration, queue/drop counters, CPU và RSS.
- `SubtitlePipeline.start` có callback `onPerformanceDiagnostics` với default
  no-op để giữ source compatibility cho call site hiện tại.
- Clock, trace events, process sampler và benchmark helpers giữ internal và có
  injection point cho test.

## Test tự động

- [x] Correlation đúng qua mọi stage và total chỉ hoàn tất sau overlay render.
- [x] Nearest-rank đúng và sample storage được giới hạn 4.096 phần tử.
- [x] Silence flush giữ speech anchor thay vì silence arrival; discontinuity loại
  anchor cũ.
- [x] Duplicate và queue overflow cập nhật counters nhưng không thêm total sample.
- [x] Pipeline publish diagnostics, có RSS, giữ snapshot cuối khi Stop và reset
  về empty khi session mới bắt đầu.
- [x] `proc_pid_rusage` đọc RSS an toàn.
- [x] Benchmark thật được gate bằng `MLINGO_RUN_PERFORMANCE_BENCHMARKS=1` và skip
  rõ khi thiếu Metal, WindowServer hoặc `OPENAI_API_KEY`.
- [x] `rtk proxy swift test --no-parallel` pass 170 tests ngày 2026-07-15;
  benchmark thật được skip vì không bật env flag.

## Benchmark opt-in

Chạy suite benchmark:

```bash
rtk proxy env MLINGO_RUN_PERFORMANCE_BENCHMARKS=1 \
  swift test --filter PerformanceBenchmarkTests
```

Điều kiện an toàn trước mọi manual/live benchmark:

- Chỉ dùng audio fixture được bundle trong test hoặc dữ liệu synthetic; tuyệt
  đối không dùng hay gửi audio, transcript hoặc subtitle thật của người dùng tới
  OpenAI.
- Dùng API key riêng cho project benchmark, inject qua `OPENAI_API_KEY`; không
  commit, ghi ra file, in ra console hoặc đưa key vào signpost/log.
- Xác nhận project OpenAI đã có budget/usage alert phù hợp, chấp nhận chi phí dự
  kiến cho 10 request và giữ `store: false` trước khi bật benchmark.
- Chỉ chạy trên máy và mạng tin cậy, không qua proxy/telemetry bên thứ ba; kiểm
  tra log không chứa nội dung fixture, transcript hoặc credential trước khi chạy.
- Người chạy phải chủ động bật `MLINGO_RUN_PERFORMANCE_BENCHMARKS=1`; thiếu bất
  kỳ điều kiện nào ở trên thì không chạy benchmark OpenAI.

Các bài benchmark gồm:

- Tiny/base/small F16 với `jfk.flac`: một warm-up, 10 lần đo, report p50/p95 và
  real-time factor; transcript phải chứa fixture phrase.
- End-to-end dùng MLX base, OpenAI thật và AppKit overlay thật: 10 lần đo,
  p95 total `<2s`, overlay p95 `<100ms`.
- Stability mặc định 3.600 giây, warm-up 300 giây; fail nếu RSS tăng ròng quá
  100 MiB hoặc least-squares slope vượt 1 MiB/phút. CPU chỉ report.
- Có thể chạy smoke ngắn bằng `MLINGO_PERFORMANCE_DURATION_SECONDS`; thời lượng
  dưới 10 phút dùng 10% thời gian làm warm-up.
- Lifecycle load/ingest/stop Whisper 10 lần để kiểm tra cleanup.

Candidate model:

- `mlx-community/whisper-tiny-asr-fp16`
- `mlx-community/whisper-base-asr-fp16`
- `mlx-community/whisper-small-asr-fp16`

Benchmark chỉ cung cấp evidence/recommendation; không tự đổi default hoặc sửa
model của người dùng.

## Tiêu chí hoàn thành

- [ ] Live end-to-end p95 dưới 2 giây trên máy benchmark.
- [ ] Overlay render p95 dưới 100 ms trên máy benchmark.
- [ ] Chạy 1 giờ không vượt memory gate.
- [ ] Stop/start 10 lần với benchmark thật không leak stream/task.

Các mục trên chưa được đánh dấu vì benchmark opt-in và manual run chưa được chạy
trong lần triển khai này.

## Nghiệm thu manual

- [ ] Chạy video/meeting 15 phút và ghi total p50/p95 trong panel.
- [ ] Chạy app 1 giờ, đối chiếu RSS/CPU trong panel với Activity Monitor.
- [ ] Stop/start Translation 10 lần và xác nhận snapshot cuối được giữ khi Stop,
  sau đó diagnostics reset khi session mới bắt đầu.
- [ ] Kiểm tra VoiceOver đọc đúng tên và giá trị từng metric.
- [ ] Kiểm tra panel trong Light/Dark/System theme.

## Rủi ro còn lại

- OpenAI latency phụ thuộc network và có thể làm live threshold fail dù local
  pipeline ổn định.
- SwiftPM command-line không luôn đóng gói MLX Metal shaders; benchmark MLX có
  thể cần chạy qua Xcode scheme như hướng dẫn ở milestone 03.
- Benchmark RSS trong test process bao gồm runtime XCTest/Swift Testing; manual
  run vẫn cần để xác nhận app release trong thời gian dài.
