import Foundation
import Testing
@testable import MLingoCore

@Test
func typedEventHubRoutesOnlyExactEventTypesAndDoesNotReplayHistory() async throws {
    let hub = TypedEventHub()
    let sessionID = makeSessionID(1)
    let started = EnvelopeRecorder<SessionStarted>()
    let ended = EnvelopeRecorder<SessionEnded>()

    _ = try await hub.publish(SessionStarted(kind: .transcription), sessionID: sessionID)

    _ = try await hub.subscribe(
        to: SessionStarted.self,
        delivery: .realtime(capacity: 8, overflow: .dropOldest)
    ) { envelope in
        await started.append(envelope)
    }
    _ = try await hub.subscribe(
        to: SessionEnded.self,
        delivery: .realtime(capacity: 8, overflow: .dropOldest)
    ) { envelope in
        await ended.append(envelope)
    }

    _ = try await hub.publish(SessionEnded(reason: .completed), sessionID: sessionID)
    _ = try await hub.publish(SessionStarted(kind: .translation), sessionID: sessionID)

    await started.waitForCount(1)
    await ended.waitForCount(1)

    #expect(await started.values.map(\.sequence) == [3])
    #expect(await ended.values.map(\.sequence) == [2])
    await hub.shutdown()
}

@Test
func typedEventHubAppliesSessionScopeWithoutChangingAllSessionDelivery() async throws {
    let hub = TypedEventHub()
    let firstSession = makeSessionID(10)
    let secondSession = makeSessionID(20)
    let scoped = EnvelopeRecorder<SessionStarted>()
    let allSessions = EnvelopeRecorder<SessionStarted>()

    _ = try await hub.subscribe(
        to: SessionStarted.self,
        scope: .session(firstSession),
        delivery: .realtime(capacity: 8, overflow: .dropOldest)
    ) { envelope in
        await scoped.append(envelope)
    }
    _ = try await hub.subscribe(
        to: SessionStarted.self,
        scope: .allSessions,
        delivery: .realtime(capacity: 8, overflow: .dropOldest)
    ) { envelope in
        await allSessions.append(envelope)
    }

    _ = try await hub.publish(SessionStarted(kind: .transcription), sessionID: firstSession)
    _ = try await hub.publish(SessionStarted(kind: .translation), sessionID: secondSession)

    await scoped.waitForCount(1)
    await allSessions.waitForCount(2)

    #expect(await scoped.values.map(\.sessionID) == [firstSession])
    #expect(await allSessions.values.map(\.sessionID) == [firstSession, secondSession])
    await hub.shutdown()
}

@Test
func typedEventHubSequencesAcrossTypesPerSessionAndControlsTraceMetadata() async throws {
    let fixedEventID = EventID(
        rawValue: UUID(uuidString: "30000000-0000-0000-0000-000000000001")!
    )
    let fixedDate = Date(timeIntervalSince1970: 1_721_222_222)
    let propagatedTrace = TraceID(
        rawValue: UUID(uuidString: "30000000-0000-0000-0000-000000000099")!
    )
    let hub = TypedEventHub(
        now: { fixedDate },
        makeEventID: { fixedEventID }
    )
    let firstSession = makeSessionID(30)
    let secondSession = makeSessionID(40)

    let root = try await hub.publish(
        SessionStarted(kind: .translation),
        sessionID: firstSession
    )
    let derived = try await hub.publish(
        SessionEnded(reason: .completed),
        sessionID: firstSession,
        traceID: propagatedTrace
    )
    let independent = try await hub.publish(
        SessionStarted(kind: .transcription),
        sessionID: secondSession
    )

    #expect(root.sequence == 1)
    #expect(derived.sequence == 2)
    #expect(independent.sequence == 1)
    #expect(root.id == fixedEventID)
    #expect(root.timestamp == fixedDate)
    #expect(root.traceID == TraceID(rawValue: fixedEventID.rawValue))
    #expect(derived.traceID == propagatedTrace)
    await hub.shutdown()
}

@Test
func typedEventHubUsesInjectedSubscriptionTokenGenerator() async throws {
    let fixedToken = SubscriptionToken(
        rawValue: UUID(uuidString: "31000000-0000-0000-0000-000000000001")!
    )
    let hub = TypedEventHub(makeSubscriptionToken: { fixedToken })

    let token = try await hub.subscribe(
        to: SessionStarted.self,
        delivery: .realtime(capacity: 1, overflow: .dropOldest)
    ) { _ in }

    #expect(token == fixedToken)
    await hub.shutdown()
}

@Test
func typedEventHubRealtimeDropOldestIsDeterministicForSlowSubscriber() async throws {
    let hub = TypedEventHub()
    let sessionID = makeSessionID(50)
    let recorder = EnvelopeRecorder<SessionStarted>()
    let firstDeliveryGate = BlockingGate()
    let token = try await hub.subscribe(
        to: SessionStarted.self,
        delivery: .realtime(capacity: 2, overflow: .dropOldest)
    ) { envelope in
        if envelope.sequence == 1 {
            await firstDeliveryGate.block()
        }
        await recorder.append(envelope)
    }

    _ = try await hub.publish(SessionStarted(kind: .translation), sessionID: sessionID)
    await firstDeliveryGate.waitUntilBlocked()
    for _ in 2...5 {
        _ = try await hub.publish(SessionStarted(kind: .translation), sessionID: sessionID)
    }

    #expect(await hub.metrics(for: token) == EventDeliveryMetrics(
        enqueued: 5,
        delivered: 0,
        buffered: 2,
        droppedOldest: 2,
        coalesced: 0,
        suspendedPublishers: 0
    ))

    await firstDeliveryGate.release()
    await recorder.waitForCount(3)
    #expect(await recorder.values.map(\.sequence) == [1, 4, 5])
    #expect(await hub.metrics(for: token)?.delivered == 3)

    await hub.cancel(token)
    await hub.cancel(token)
    #expect(await hub.metrics(for: token) == nil)
    await hub.shutdown()
}

@Test
func typedEventHubRealtimeCoalescingKeepsIncomingEnvelopeMetadata() async throws {
    let hub = TypedEventHub()
    let sessionID = makeSessionID(60)
    let recorder = EnvelopeRecorder<MergeFact>()
    let firstDeliveryGate = BlockingGate()
    let finalTrace = TraceID(
        rawValue: UUID(uuidString: "60000000-0000-0000-0000-000000000005")!
    )
    let token = try await hub.subscribe(
        to: MergeFact.self,
        delivery: .realtime(
            capacity: 2,
            overflow: .coalesce { previous, incoming in
                MergeFact(value: previous.value + "+" + incoming.value)
            }
        )
    ) { envelope in
        if envelope.sequence == 1 {
            await firstDeliveryGate.block()
        }
        await recorder.append(envelope)
    }

    _ = try await hub.publish(MergeFact(value: "1"), sessionID: sessionID)
    await firstDeliveryGate.waitUntilBlocked()
    _ = try await hub.publish(MergeFact(value: "2"), sessionID: sessionID)
    _ = try await hub.publish(MergeFact(value: "3"), sessionID: sessionID)
    _ = try await hub.publish(MergeFact(value: "4"), sessionID: sessionID)
    let incoming = try await hub.publish(
        MergeFact(value: "5"),
        sessionID: sessionID,
        traceID: finalTrace
    )

    #expect(await hub.metrics(for: token)?.coalesced == 2)
    #expect(await hub.metrics(for: token)?.buffered == 2)

    await firstDeliveryGate.release()
    await recorder.waitForCount(3)
    let received = await recorder.values
    #expect(received.map(\.sequence) == [1, 2, 5])
    #expect(received.map(\.payload.value) == ["1", "2", "3+4+5"])
    #expect(received.last?.id == incoming.id)
    #expect(received.last?.timestamp == incoming.timestamp)
    #expect(received.last?.traceID == finalTrace)
    await hub.shutdown()
}

@Test
func typedEventHubSerializesConcurrentPublishersByAssignedSequence() async throws {
    let hub = TypedEventHub()
    let sessionID = makeSessionID(70)
    let recorder = EnvelopeRecorder<MergeFact>()
    _ = try await hub.subscribe(
        to: MergeFact.self,
        delivery: .realtime(capacity: 64, overflow: .dropOldest)
    ) { envelope in
        await recorder.append(envelope)
    }

    let assignedSequences = try await withThrowingTaskGroup(
        of: UInt64.self,
        returning: [UInt64].self
    ) { group in
        for value in 1...50 {
            group.addTask {
                try await hub.publish(
                    MergeFact(value: String(value)),
                    sessionID: sessionID
                ).sequence
            }
        }
        var sequences: [UInt64] = []
        for try await sequence in group {
            sequences.append(sequence)
        }
        return sequences
    }

    await recorder.waitForCount(50)
    #expect(assignedSequences.sorted() == Array(1...50).map(UInt64.init))
    #expect(await recorder.values.map(\.sequence) == Array(1...50).map(UInt64.init))
    await hub.shutdown()
}

@Test
func typedEventHubDurableDeliverySuspendsThirdPublisherAndRemainsLossless() async throws {
    let hub = TypedEventHub()
    let sessionID = makeSessionID(80)
    let recorder = EnvelopeRecorder<SessionStarted>()
    let firstDeliveryGate = BlockingGate()
    let token = try await hub.subscribe(
        to: SessionStarted.self,
        delivery: .durable(capacity: 1)
    ) { envelope in
        if envelope.sequence == 1 {
            await firstDeliveryGate.block()
        }
        await recorder.append(envelope)
    }

    _ = try await hub.publish(SessionStarted(kind: .translation), sessionID: sessionID)
    await firstDeliveryGate.waitUntilBlocked()
    _ = try await hub.publish(SessionStarted(kind: .translation), sessionID: sessionID)
    let thirdPublication = Task {
        try await hub.publish(SessionStarted(kind: .translation), sessionID: sessionID)
    }

    #expect(await hub.waitForSuspendedPublishers(1, for: token))
    #expect(await hub.metrics(for: token)?.suspendedPublishers == 1)
    #expect(await hub.metrics(for: token)?.buffered == 1)

    await firstDeliveryGate.release()
    #expect(try await thirdPublication.value.sequence == 3)
    await recorder.waitForCount(3)
    #expect(await recorder.values.map(\.sequence) == [1, 2, 3])
    #expect(await hub.metrics(for: token) == EventDeliveryMetrics(
        enqueued: 3,
        delivered: 3,
        buffered: 0,
        droppedOldest: 0,
        coalesced: 0,
        suspendedPublishers: 0
    ))
    await hub.shutdown()
}

@Test
func typedEventHubDurableConcurrentPublishersResumeInSequenceOrder() async throws {
    let hub = TypedEventHub()
    let sessionID = makeSessionID(85)
    let recorder = EnvelopeRecorder<MergeFact>()
    let firstDeliveryGate = BlockingGate()
    let token = try await hub.subscribe(
        to: MergeFact.self,
        delivery: .durable(capacity: 1)
    ) { envelope in
        if envelope.sequence == 1 {
            await firstDeliveryGate.block()
        }
        await recorder.append(envelope)
    }

    _ = try await hub.publish(MergeFact(value: "1"), sessionID: sessionID)
    await firstDeliveryGate.waitUntilBlocked()
    _ = try await hub.publish(MergeFact(value: "2"), sessionID: sessionID)
    let publishers = Task {
        try await withThrowingTaskGroup(of: UInt64.self, returning: [UInt64].self) { group in
            for value in 3...20 {
                group.addTask {
                    try await hub.publish(
                        MergeFact(value: String(value)),
                        sessionID: sessionID
                    ).sequence
                }
            }
            var sequences: [UInt64] = []
            for try await sequence in group {
                sequences.append(sequence)
            }
            return sequences
        }
    }

    #expect(await hub.waitForSuspendedPublishers(1, for: token))
    await firstDeliveryGate.release()
    #expect(try await publishers.value.sorted() == Array(3...20).map(UInt64.init))
    await recorder.waitForCount(20)
    #expect(await recorder.values.map(\.sequence) == Array(1...20).map(UInt64.init))
    #expect(await hub.metrics(for: token)?.delivered == 20)
    await hub.shutdown()
}

@Test
func typedEventHubCancelDropsQueueCancelsHandlerAndReleasesBackpressure() async throws {
    let hub = TypedEventHub()
    let sessionID = makeSessionID(90)
    let cancellationGate = CancellationAwareGate()
    let token = try await hub.subscribe(
        to: SessionStarted.self,
        delivery: .durable(capacity: 1)
    ) { _ in
        try await cancellationGate.blockUntilCancelled()
    }

    _ = try await hub.publish(SessionStarted(kind: .translation), sessionID: sessionID)
    await cancellationGate.waitUntilBlocked()
    _ = try await hub.publish(SessionStarted(kind: .translation), sessionID: sessionID)
    let thirdPublication = Task {
        try await hub.publish(SessionStarted(kind: .translation), sessionID: sessionID)
    }
    #expect(await hub.waitForSuspendedPublishers(1, for: token))
    #expect(await hub.metrics(for: token)?.suspendedPublishers == 1)

    await hub.cancel(token)
    await hub.cancel(token)
    await cancellationGate.waitUntilCancelled()
    #expect(try await thirdPublication.value.sequence == 3)
    #expect(await hub.metrics(for: token) == nil)
    await hub.shutdown()
}

@Test
func typedEventHubShutdownReleasesDurablePublishersAndRejectsNewWork() async throws {
    let hub = TypedEventHub()
    let sessionID = makeSessionID(100)
    let cancellationGate = CancellationAwareGate()
    let token = try await hub.subscribe(
        to: SessionStarted.self,
        delivery: .durable(capacity: 1)
    ) { _ in
        try await cancellationGate.blockUntilCancelled()
    }

    _ = try await hub.publish(SessionStarted(kind: .translation), sessionID: sessionID)
    await cancellationGate.waitUntilBlocked()
    _ = try await hub.publish(SessionStarted(kind: .translation), sessionID: sessionID)
    let blockedPublication = Task {
        try await hub.publish(SessionStarted(kind: .translation), sessionID: sessionID)
    }
    #expect(await hub.waitForSuspendedPublishers(1, for: token))
    #expect(await hub.metrics(for: token)?.suspendedPublishers == 1)

    await hub.shutdown()
    await cancellationGate.waitUntilCancelled()
    #expect(try await blockedPublication.value.sequence == 3)
    #expect(await hub.metrics(for: token) == nil)

    await #expect(throws: TypedEventHubError.closed) {
        try await hub.publish(SessionStarted(kind: .translation), sessionID: sessionID)
    }
    await #expect(throws: TypedEventHubError.closed) {
        try await hub.subscribe(
            to: SessionStarted.self,
            delivery: .realtime(capacity: 1, overflow: .dropOldest)
        ) { _ in }
    }
    await hub.shutdown()
}

@Test
func typedEventHubSubscriberFailureIsIsolatedFromOtherSubscribers() async throws {
    let hub = TypedEventHub()
    let sessionID = makeSessionID(110)
    let failingCalls = Counter()
    let healthyRecorder = EnvelopeRecorder<SessionStarted>()
    let failingToken = try await hub.subscribe(
        to: SessionStarted.self,
        delivery: .realtime(capacity: 4, overflow: .dropOldest)
    ) { _ in
        await failingCalls.increment()
        throw TestFailure.expected
    }
    let healthyToken = try await hub.subscribe(
        to: SessionStarted.self,
        delivery: .realtime(capacity: 4, overflow: .dropOldest)
    ) { envelope in
        await healthyRecorder.append(envelope)
    }

    _ = try await hub.publish(SessionStarted(kind: .translation), sessionID: sessionID)
    await failingCalls.waitForValue(1)
    await healthyRecorder.waitForCount(1)
    // Wait for subscriptionDidFail to remove the failing subscription (metrics gone)
    // rather than Task.yield(), which does not guarantee that cleanup completed.
    while await hub.metrics(for: failingToken) != nil {
        await Task.yield()
    }
    _ = try await hub.publish(SessionStarted(kind: .translation), sessionID: sessionID)
    await healthyRecorder.waitForCount(2)

    #expect(await failingCalls.value == 1)
    #expect(await hub.metrics(for: failingToken) == nil)
    #expect(await hub.metrics(for: healthyToken)?.delivered == 2)
    #expect(await healthyRecorder.values.map(\.sequence) == [1, 2])
    await hub.shutdown()
}

@Test
func typedEventHubCancelPublishRaceDoesNotDisturbOtherSubscription() async throws {
    let hub = TypedEventHub()
    let sessionID = makeSessionID(115)
    let cancelledRecorder = EnvelopeRecorder<MergeFact>()
    let healthyRecorder = EnvelopeRecorder<MergeFact>()
    let cancelledToken = try await hub.subscribe(
        to: MergeFact.self,
        delivery: .realtime(capacity: 128, overflow: .dropOldest)
    ) { envelope in
        await cancelledRecorder.append(envelope)
    }
    let healthyToken = try await hub.subscribe(
        to: MergeFact.self,
        delivery: .realtime(capacity: 128, overflow: .dropOldest)
    ) { envelope in
        await healthyRecorder.append(envelope)
    }

    async let cancellation: Void = hub.cancel(cancelledToken)
    let published = try await withThrowingTaskGroup(
        of: UInt64.self,
        returning: [UInt64].self
    ) { group in
        for value in 1...100 {
            group.addTask {
                try await hub.publish(
                    MergeFact(value: String(value)),
                    sessionID: sessionID
                ).sequence
            }
        }
        var sequences: [UInt64] = []
        for try await sequence in group {
            sequences.append(sequence)
        }
        return sequences
    }
    _ = await cancellation

    await healthyRecorder.waitForCount(100)
    #expect(published.sorted() == Array(1...100).map(UInt64.init))
    #expect(await healthyRecorder.values.map(\.sequence) == Array(1...100).map(UInt64.init))
    #expect(await hub.metrics(for: cancelledToken) == nil)
    #expect(await hub.metrics(for: healthyToken)?.delivered == 100)
    #expect(await cancelledRecorder.values.count <= 100)
    await hub.shutdown()
}

@Test
func typedEventHubRejectsInvalidCapacityAndCheckedSequenceOverflow() async throws {
    let hub = TypedEventHub()
    await #expect(throws: TypedEventHubError.invalidCapacity(0)) {
        try await hub.subscribe(
            to: SessionStarted.self,
            delivery: .durable(capacity: 0)
        ) { _ in }
    }
    await #expect(throws: TypedEventHubError.invalidCapacity(-1)) {
        try await hub.subscribe(
            to: SessionStarted.self,
            delivery: .realtime(capacity: -1, overflow: .dropOldest)
        ) { _ in }
    }

    let sessionID = makeSessionID(120)
    #expect(try nextEventSequence(after: UInt64.max - 1, sessionID: sessionID) == UInt64.max)
    #expect(throws: TypedEventHubError.sequenceExhausted(sessionID)) {
        try nextEventSequence(after: UInt64.max, sessionID: sessionID)
    }
    await hub.shutdown()
}

private func makeSessionID(_ suffix: UInt8) -> SessionID {
    SessionID(rawValue: UUID(uuid: (
        0, 0, 0, 0,
        0, 0,
        0, 0,
        0, 0,
        0, 0, 0, 0, 0, suffix
    )))
}

private actor EnvelopeRecorder<Event: EventFact> {
    private(set) var values: [EventEnvelope<Event>] = []
    private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func append(_ envelope: EventEnvelope<Event>) {
        values.append(envelope)
        let ready = waiters.filter { values.count >= $0.count }
        waiters.removeAll { values.count >= $0.count }
        for waiter in ready {
            waiter.continuation.resume()
        }
    }

    func waitForCount(_ count: Int) async {
        guard values.count < count else { return }
        await withCheckedContinuation { continuation in
            waiters.append((count, continuation))
        }
    }
}

private struct MergeFact: EventFact, Equatable {
    let value: String
}

private actor BlockingGate {
    private var blocked = false
    private var blockContinuation: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []

    func block() async {
        blocked = true
        for observer in observers {
            observer.resume()
        }
        observers.removeAll()
        await withCheckedContinuation { continuation in
            blockContinuation = continuation
        }
    }

    func waitUntilBlocked() async {
        guard !blocked else { return }
        await withCheckedContinuation { continuation in
            observers.append(continuation)
        }
    }

    func release() {
        blockContinuation?.resume()
        blockContinuation = nil
    }
}

private actor Counter {
    private(set) var value = 0
    private var waiters: [(value: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func increment() {
        value += 1
        let ready = waiters.filter { value >= $0.value }
        waiters.removeAll { value >= $0.value }
        for waiter in ready {
            waiter.continuation.resume()
        }
    }

    func waitForValue(_ expectedValue: Int) async {
        guard value < expectedValue else { return }
        await withCheckedContinuation { continuation in
            waiters.append((expectedValue, continuation))
        }
    }
}

private actor CancellationAwareGate {
    private var blocked = false
    private var cancelled = false
    private var blockContinuation: CheckedContinuation<Void, Error>?
    private var blockedObservers: [CheckedContinuation<Void, Never>] = []
    private var cancellationObservers: [CheckedContinuation<Void, Never>] = []

    func blockUntilCancelled() async throws {
        blocked = true
        for observer in blockedObservers {
            observer.resume()
        }
        blockedObservers.removeAll()

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                blockContinuation = continuation
            }
        } onCancel: {
            Task {
                await self.handleCancellation()
            }
        }
    }

    func waitUntilBlocked() async {
        guard !blocked else { return }
        await withCheckedContinuation { continuation in
            blockedObservers.append(continuation)
        }
    }

    func waitUntilCancelled() async {
        guard !cancelled else { return }
        await withCheckedContinuation { continuation in
            cancellationObservers.append(continuation)
        }
    }

    private func handleCancellation() {
        guard !cancelled else { return }
        cancelled = true
        blockContinuation?.resume(throwing: CancellationError())
        blockContinuation = nil
        for observer in cancellationObservers {
            observer.resume()
        }
        cancellationObservers.removeAll()
    }
}

private enum TestFailure: Error {
    case expected
}
