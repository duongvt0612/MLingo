import Foundation
import Testing
@testable import MLingoCore

@Test
func translationWorkerPublishesOrderedCompletionWithPropagatedTrace() async throws {
    let hub = TypedEventHub()
    let engine = WorkerTranslationEngine()
    let sessionID = SessionID(rawValue: UUID())
    let recorder = WorkerCompletionRecorder()
    let token = try await hub.subscribe(
        to: TranslationCompleted.self,
        scope: .session(sessionID),
        delivery: .durable(capacity: 2)
    ) { envelope in
        await recorder.append(envelope)
    }
    let worker = TranslationWorker(
        translationEngine: engine,
        settings: AppSettings(),
        selection: nil,
        eventHub: hub,
        sessionID: sessionID
    )
    let firstTrace = TraceID(rawValue: UUID())
    let secondTrace = TraceID(rawValue: UUID())
    let first = EventEnvelope(
        id: EventID(rawValue: UUID()),
        sessionID: sessionID,
        sequence: 1,
        timestamp: Date(timeIntervalSince1970: 1),
        traceID: firstTrace,
        payload: TranscriptCompleted(transcript: Transcript(text: "One", timestamp: 0))
    )
    let second = EventEnvelope(
        id: EventID(rawValue: UUID()),
        sessionID: sessionID,
        sequence: 2,
        timestamp: Date(timeIntervalSince1970: 2),
        traceID: secondTrace,
        payload: TranscriptCompleted(transcript: Transcript(text: "Two", timestamp: 3))
    )

    await worker.submit(first)
    await worker.submit(second)
    try await workerEventually { await recorder.count == 2 }

    #expect(await engine.contextTexts == [[], ["One"]])
    #expect(await recorder.traceIDs == [firstTrace, secondTrace])
    await worker.cancel()
    await hub.cancel(token)
}

@Test
func translationWorkerReportsEventHubFailureAsFatal() async throws {
    let hub = TypedEventHub()
    await hub.shutdown()
    let fatalErrors = WorkerErrorRecorder()
    let sessionID = SessionID(rawValue: UUID())
    let worker = TranslationWorker(
        translationEngine: WorkerTranslationEngine(),
        settings: AppSettings(),
        selection: nil,
        eventHub: hub,
        sessionID: sessionID,
        observers: TranslationWorkerObservers(
            onFatalError: { await fatalErrors.append($0) }
        )
    )
    let envelope = EventEnvelope(
        id: EventID(rawValue: UUID()),
        sessionID: sessionID,
        sequence: 1,
        timestamp: Date(),
        traceID: TraceID(rawValue: UUID()),
        payload: TranscriptCompleted(transcript: Transcript(text: "One", timestamp: 0))
    )

    await worker.submit(envelope)
    try await workerEventually { await fatalErrors.count == 1 }

    #expect(await fatalErrors.count == 1)
    await worker.cancel()
}

private actor WorkerTranslationEngine: TranslationEngineProtocol {
    private(set) var contextTexts: [[String]] = []

    func translate(_ request: TranslationRequest, settings: AppSettings) async throws -> SubtitleItem {
        contextTexts.append(request.context.map(\.text))
        return SubtitleItem(
            original: request.current.text,
            translated: "translated \(request.current.text)",
            start: request.current.timestamp,
            end: request.current.timestamp + 2
        )
    }
}

private actor WorkerCompletionRecorder {
    private var values: [EventEnvelope<TranslationCompleted>] = []
    var count: Int { values.count }
    var traceIDs: [TraceID] { values.map(\.traceID) }

    func append(_ envelope: EventEnvelope<TranslationCompleted>) {
        values.append(envelope)
    }
}

private actor WorkerErrorRecorder {
    private var values: [MLingoError] = []
    var count: Int { values.count }
    func append(_ error: MLingoError) { values.append(error) }
}

private func workerEventually(
    timeout: Duration = .seconds(1),
    condition: @escaping @Sendable () async -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("Condition was not met before timeout")
}
