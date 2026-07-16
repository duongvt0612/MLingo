import Foundation

public enum EventSubscriptionScope: Equatable, Sendable {
    case allSessions
    case session(SessionID)

    fileprivate func includes(_ sessionID: SessionID) -> Bool {
        switch self {
        case .allSessions:
            true
        case let .session(expectedSessionID):
            expectedSessionID == sessionID
        }
    }
}

public enum RealtimeOverflowPolicy<Event: EventFact>: Sendable {
    case dropOldest
    case coalesce(@Sendable (Event, Event) -> Event)
}

public enum EventDeliveryPolicy<Event: EventFact>: Sendable {
    case realtime(capacity: Int, overflow: RealtimeOverflowPolicy<Event>)
    case durable(capacity: Int)
}

public struct EventDeliveryMetrics: Equatable, Sendable {
    public let enqueued: UInt64
    public let delivered: UInt64
    public let buffered: Int
    public let droppedOldest: UInt64
    public let coalesced: UInt64
    public let suspendedPublishers: Int

    public init(
        enqueued: UInt64,
        delivered: UInt64,
        buffered: Int,
        droppedOldest: UInt64,
        coalesced: UInt64,
        suspendedPublishers: Int
    ) {
        self.enqueued = enqueued
        self.delivered = delivered
        self.buffered = buffered
        self.droppedOldest = droppedOldest
        self.coalesced = coalesced
        self.suspendedPublishers = suspendedPublishers
    }
}

public enum TypedEventHubError: Error, Equatable, Sendable {
    case invalidCapacity(Int)
    case closed
    case sequenceExhausted(SessionID)
    case duplicateSubscriptionToken(SubscriptionToken)
}

public actor TypedEventHub {
    public typealias Clock = @Sendable () -> Date
    public typealias EventIDGenerator = @Sendable () -> EventID
    public typealias SubscriptionTokenGenerator = @Sendable () -> SubscriptionToken

    private let now: Clock
    private let makeEventID: EventIDGenerator
    private let makeSubscriptionToken: SubscriptionTokenGenerator

    private var isClosed = false
    private var sequences: [SessionID: UInt64] = [:]
    private var subscriptions: [SubscriptionToken: AnyEventSubscription] = [:]

    public init(
        now: @escaping Clock = { Date() },
        makeEventID: @escaping EventIDGenerator = {
            EventID(rawValue: UUID())
        },
        makeSubscriptionToken: @escaping SubscriptionTokenGenerator = {
            SubscriptionToken(rawValue: UUID())
        }
    ) {
        self.now = now
        self.makeEventID = makeEventID
        self.makeSubscriptionToken = makeSubscriptionToken
    }

    @discardableResult
    public func subscribe<Event: EventFact>(
        to eventType: Event.Type = Event.self,
        scope: EventSubscriptionScope = .allSessions,
        delivery: EventDeliveryPolicy<Event>,
        handler: @escaping @Sendable (EventEnvelope<Event>) async throws -> Void
    ) async throws -> SubscriptionToken {
        guard !isClosed else {
            throw TypedEventHubError.closed
        }

        let capacity: Int
        let mailboxMode: EventMailbox<Event>.Mode
        switch delivery {
        case let .realtime(requestedCapacity, overflow):
            capacity = requestedCapacity
            mailboxMode = .realtime(overflow)
        case let .durable(requestedCapacity):
            capacity = requestedCapacity
            mailboxMode = .durable
        }
        guard capacity > 0 else {
            throw TypedEventHubError.invalidCapacity(capacity)
        }

        let token = makeSubscriptionToken()
        let mailbox = EventMailbox<Event>(capacity: capacity, mode: mailboxMode)
        let record = AnyEventSubscription(
            eventType: ObjectIdentifier(eventType),
            scope: scope,
            enqueue: { value in
                guard let envelope = value as? EventEnvelope<Event> else { return }
                await mailbox.enqueue(envelope)
            },
            cancel: {
                await mailbox.cancel()
            },
            metrics: {
                await mailbox.metrics()
            },
            waitForSuspendedPublishers: { count in
                await mailbox.waitForSuspendedPublishers(count)
            }
        )
        guard subscriptions[token] == nil else {
            // Preserve the active subscription; cancel the unused mailbox so its
            // worker cannot start and leak after a duplicate-token rejection.
            await mailbox.cancel()
            throw TypedEventHubError.duplicateSubscriptionToken(token)
        }
        subscriptions[token] = record

        await mailbox.start(handler: handler) { [weak self] in
            await self?.subscriptionDidFail(token)
        }
        return token
    }

    @discardableResult
    public func publish<Event: EventFact>(
        _ payload: Event,
        sessionID: SessionID,
        traceID: TraceID? = nil
    ) async throws -> EventEnvelope<Event> {
        guard !isClosed else {
            throw TypedEventHubError.closed
        }

        let previousSequence = sequences[sessionID] ?? 0
        let sequence = try nextEventSequence(
            after: previousSequence,
            sessionID: sessionID
        )
        sequences[sessionID] = sequence
        let eventID = makeEventID()
        let envelope = EventEnvelope(
            id: eventID,
            sessionID: sessionID,
            sequence: sequence,
            timestamp: now(),
            traceID: traceID ?? TraceID(rawValue: eventID.rawValue),
            payload: payload
        )

        let eventType = ObjectIdentifier(Event.self)
        let matchingSubscriptions = subscriptions.values.filter {
            $0.eventType == eventType && $0.scope.includes(sessionID)
        }
        // Enqueue per matching subscription only. Durable backpressure lives in
        // each mailbox's producer waiters (suspendedPublishers), so a full
        // durable subscription blocks only publications that target it.
        for subscription in matchingSubscriptions {
            await subscription.enqueue(envelope)
        }
        return envelope
    }

    public func cancel(_ token: SubscriptionToken) async {
        guard let subscription = subscriptions.removeValue(forKey: token) else {
            return
        }
        await subscription.cancel()
    }

    public func metrics(for token: SubscriptionToken) async -> EventDeliveryMetrics? {
        guard let subscription = subscriptions[token] else {
            return nil
        }
        return await subscription.metrics()
    }

    func waitForSuspendedPublishers(
        _ count: Int,
        for token: SubscriptionToken
    ) async -> Bool {
        guard let subscription = subscriptions[token] else {
            return false
        }
        return await subscription.waitForSuspendedPublishers(count)
    }

    public func shutdown() async {
        guard !isClosed else { return }
        isClosed = true

        let activeSubscriptions = Array(subscriptions.values)
        subscriptions.removeAll()
        for subscription in activeSubscriptions {
            await subscription.cancel()
        }
    }

    private func subscriptionDidFail(_ token: SubscriptionToken) async {
        await cancel(token)
    }
}

func nextEventSequence(after sequence: UInt64, sessionID: SessionID) throws -> UInt64 {
    let (nextSequence, overflowed) = sequence.addingReportingOverflow(1)
    guard !overflowed else {
        throw TypedEventHubError.sequenceExhausted(sessionID)
    }
    return nextSequence
}

private struct AnyEventSubscription: Sendable {
    let eventType: ObjectIdentifier
    let scope: EventSubscriptionScope
    let enqueue: @Sendable (any Sendable) async -> Void
    let cancel: @Sendable () async -> Void
    let metrics: @Sendable () async -> EventDeliveryMetrics
    let waitForSuspendedPublishers: @Sendable (Int) async -> Bool
}

private actor EventMailbox<Event: EventFact> {
    enum Mode: Sendable {
        case realtime(RealtimeOverflowPolicy<Event>)
        case durable
    }

    private struct ProducerWaiter {
        let envelope: EventEnvelope<Event>
        let continuation: CheckedContinuation<Void, Never>
    }

    private let capacity: Int
    private let mode: Mode
    private var buffer: [EventEnvelope<Event>] = []
    private var consumerWaiter: CheckedContinuation<EventEnvelope<Event>?, Never>?
    private var producerWaiters: [ProducerWaiter] = []
    private var suspensionObservers: [(
        count: Int,
        continuation: CheckedContinuation<Bool, Never>
    )] = []
    private var worker: Task<Void, Never>?
    private var isTerminated = false
    private var enqueued: UInt64 = 0
    private var delivered: UInt64 = 0
    private var droppedOldest: UInt64 = 0
    private var coalesced: UInt64 = 0

    init(capacity: Int, mode: Mode) {
        self.capacity = capacity
        self.mode = mode
    }

    func start(
        handler: @escaping @Sendable (EventEnvelope<Event>) async throws -> Void,
        onFailure: @escaping @Sendable () async -> Void
    ) {
        guard worker == nil, !isTerminated else { return }
        worker = Task { [weak self] in
            guard let self else { return }
            do {
                while let envelope = await self.next() {
                    try Task.checkCancellation()
                    try await handler(envelope)
                    await self.didDeliver()
                }
            } catch is CancellationError {
                // Subscription cancellation is an expected terminal path.
            } catch {
                await onFailure()
            }
        }
    }

    func enqueue(_ envelope: EventEnvelope<Event>) async {
        guard !isTerminated else { return }
        enqueued += 1

        if let consumerWaiter {
            self.consumerWaiter = nil
            consumerWaiter.resume(returning: envelope)
            return
        }

        if buffer.count < capacity {
            buffer.append(envelope)
            return
        }

        switch mode {
        case let .realtime(overflow):
            applyRealtimeOverflow(overflow, incoming: envelope)
        case .durable:
            await withCheckedContinuation { continuation in
                producerWaiters.append(ProducerWaiter(
                    envelope: envelope,
                    continuation: continuation
                ))
                resumeSatisfiedSuspensionObservers()
            }
        }
    }

    func cancel() {
        guard !isTerminated else { return }
        isTerminated = true
        buffer.removeAll(keepingCapacity: false)

        consumerWaiter?.resume(returning: nil)
        consumerWaiter = nil
        for waiter in producerWaiters {
            waiter.continuation.resume()
        }
        producerWaiters.removeAll(keepingCapacity: false)
        for observer in suspensionObservers {
            observer.continuation.resume(returning: false)
        }
        suspensionObservers.removeAll(keepingCapacity: false)

        worker?.cancel()
        worker = nil
    }

    func metrics() -> EventDeliveryMetrics {
        EventDeliveryMetrics(
            enqueued: enqueued,
            delivered: delivered,
            buffered: buffer.count,
            droppedOldest: droppedOldest,
            coalesced: coalesced,
            suspendedPublishers: producerWaiters.count
        )
    }

    func waitForSuspendedPublishers(_ count: Int) async -> Bool {
        guard producerWaiters.count < count else { return true }
        guard !isTerminated else { return false }
        return await withCheckedContinuation { continuation in
            suspensionObservers.append((count, continuation))
        }
    }

    private func next() async -> EventEnvelope<Event>? {
        if !buffer.isEmpty {
            let envelope = buffer.removeFirst()
            admitNextProducerIfPossible()
            return envelope
        }
        guard !isTerminated else { return nil }

        return await withCheckedContinuation { continuation in
            consumerWaiter = continuation
        }
    }

    private func didDeliver() {
        delivered += 1
    }

    private func admitNextProducerIfPossible() {
        guard case .durable = mode,
              buffer.count < capacity,
              !producerWaiters.isEmpty,
              !isTerminated else {
            return
        }
        let waiter = producerWaiters.removeFirst()
        buffer.append(waiter.envelope)
        waiter.continuation.resume()
    }

    private func resumeSatisfiedSuspensionObservers() {
        let satisfied = suspensionObservers.filter {
            producerWaiters.count >= $0.count
        }
        suspensionObservers.removeAll {
            producerWaiters.count >= $0.count
        }
        for observer in satisfied {
            observer.continuation.resume(returning: true)
        }
    }

    private func applyRealtimeOverflow(
        _ overflow: RealtimeOverflowPolicy<Event>,
        incoming: EventEnvelope<Event>
    ) {
        switch overflow {
        case .dropOldest:
            buffer.removeFirst()
            buffer.append(incoming)
            droppedOldest += 1
        case let .coalesce(merge):
            // Buffer is full; only merge when the tail event shares the session.
            let previous = buffer[buffer.count - 1]
            if previous.sessionID == incoming.sessionID {
                buffer.removeLast()
                buffer.append(EventEnvelope(
                    id: incoming.id,
                    sessionID: incoming.sessionID,
                    sequence: incoming.sequence,
                    timestamp: incoming.timestamp,
                    traceID: incoming.traceID,
                    payload: merge(previous.payload, incoming.payload)
                ))
                coalesced += 1
            } else {
                // Keep the previous (tail) event and the incoming one; free a slot
                // by dropping the oldest buffered event without cross-session merge.
                buffer.removeFirst()
                buffer.append(incoming)
                droppedOldest += 1
            }
        }
    }
}
