import Foundation

struct TranslationWorkerObservers: Sendable {
    let onQueued: @Sendable (UUID) async -> Void
    let onStarted: @Sendable (UUID) async -> Void
    let onFinished: @Sendable (UUID) async -> Void
    let onDiscarded: @Sendable (UUID, Bool, Bool) async -> Void
    let onQueueDepth: @Sendable (Int) async -> Void
    let onWarning: @Sendable (String) -> Void
    let onError: @Sendable (MLingoError) async -> Void
    let onFatalError: @Sendable (MLingoError) async -> Void

    init(
        onQueued: @escaping @Sendable (UUID) async -> Void = { _ in },
        onStarted: @escaping @Sendable (UUID) async -> Void = { _ in },
        onFinished: @escaping @Sendable (UUID) async -> Void = { _ in },
        onDiscarded: @escaping @Sendable (UUID, Bool, Bool) async -> Void = { _, _, _ in },
        onQueueDepth: @escaping @Sendable (Int) async -> Void = { _ in },
        onWarning: @escaping @Sendable (String) -> Void = { _ in },
        onError: @escaping @Sendable (MLingoError) async -> Void = { _ in },
        onFatalError: @escaping @Sendable (MLingoError) async -> Void = { _ in }
    ) {
        self.onQueued = onQueued
        self.onStarted = onStarted
        self.onFinished = onFinished
        self.onDiscarded = onDiscarded
        self.onQueueDepth = onQueueDepth
        self.onWarning = onWarning
        self.onError = onError
        self.onFatalError = onFatalError
    }
}

actor TranslationWorker {
    private struct PendingTranslation: Sendable {
        let envelope: EventEnvelope<TranscriptCompleted>
        let request: TranslationRequest
    }

    private let translationEngine: any TranslationEngineProtocol
    private let settings: AppSettings
    private let selection: ResolvedProviderSelection?
    private let eventHub: TypedEventHub
    private let sessionID: SessionID
    private let observers: TranslationWorkerObservers

    private var pending: [PendingTranslation] = []
    private var history: [Transcript] = []
    private var lastDedupeKey: String?
    private var skippedCount = 0
    private var isPaused = false
    private var isCancelled = false
    private var drainTask: Task<Void, Never>?

    init(
        translationEngine: any TranslationEngineProtocol,
        settings: AppSettings,
        selection: ResolvedProviderSelection?,
        eventHub: TypedEventHub,
        sessionID: SessionID,
        observers: TranslationWorkerObservers = TranslationWorkerObservers()
    ) {
        self.translationEngine = translationEngine
        self.settings = settings
        self.selection = selection
        self.eventHub = eventHub
        self.sessionID = sessionID
        self.observers = observers
    }

    func submit(_ envelope: EventEnvelope<TranscriptCompleted>) async {
        guard !isCancelled, envelope.sessionID == sessionID else { return }
        let transcript = envelope.payload.transcript
        guard !isPaused else {
            await observers.onDiscarded(transcript.id, false, false)
            return
        }
        let dedupeKey = transcript.text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !dedupeKey.isEmpty else {
            await observers.onDiscarded(transcript.id, false, false)
            return
        }
        guard dedupeKey != lastDedupeKey else {
            await observers.onDiscarded(transcript.id, true, false)
            return
        }
        lastDedupeKey = dedupeKey

        let request = TranslationRequest(
            current: transcript,
            context: Array(history.suffix(2))
        )
        history.append(transcript)
        if history.count > 2 {
            history.removeFirst(history.count - 2)
        }

        if pending.count >= 8 {
            let removed = pending.removeFirst()
            skippedCount += 1
            await observers.onDiscarded(removed.request.current.id, false, true)
            observers.onWarning(
                "Translation is falling behind. Skipped \(skippedCount) older subtitles."
            )
        }
        pending.append(PendingTranslation(envelope: envelope, request: request))
        await observers.onQueued(transcript.id)
        await observers.onQueueDepth(pending.count)

        guard drainTask == nil else { return }
        drainTask = Task { [weak self] in
            await self?.drain()
        }
    }

    func cancel() async {
        guard !isCancelled else { return }
        isCancelled = true
        drainTask?.cancel()
        drainTask = nil
        let discarded = pending
        pending.removeAll(keepingCapacity: false)
        history.removeAll(keepingCapacity: false)
        for item in discarded {
            await observers.onDiscarded(item.request.current.id, false, false)
        }
        await observers.onQueueDepth(0)
    }

    private func drain() async {
        defer { drainTask = nil }

        while !isCancelled, !isPaused, !Task.isCancelled, !pending.isEmpty {
            let item = pending.removeFirst()
            await observers.onQueueDepth(pending.count)
            await observers.onStarted(item.request.current.id)

            let subtitle: SubtitleItem
            do {
                subtitle = try await translationEngine.translate(
                    item.request,
                    settings: settings,
                    selection: selection
                )
            } catch is CancellationError {
                await observers.onDiscarded(item.request.current.id, false, false)
                return
            } catch {
                guard !isCancelled, !Task.isCancelled else {
                    await observers.onDiscarded(item.request.current.id, false, false)
                    return
                }
                await handleTranslationFailure(error, item: item)
                continue
            }

            guard !isCancelled, !Task.isCancelled else {
                await observers.onDiscarded(item.request.current.id, false, false)
                return
            }
            await observers.onFinished(item.request.current.id)
            do {
                _ = try await eventHub.publish(
                    TranslationCompleted(
                        sourceTranscriptID: item.request.current.id,
                        subtitle: subtitle
                    ),
                    sessionID: sessionID,
                    traceID: item.envelope.traceID
                )
            } catch is CancellationError {
                await observers.onDiscarded(item.request.current.id, false, false)
                return
            } catch {
                guard !isCancelled, !Task.isCancelled else { return }
                await observers.onDiscarded(item.request.current.id, false, false)
                isPaused = true
                await discardPending()
                await observers.onFatalError(
                    .translationFailed("Event hub publication failed.")
                )
                return
            }
        }
    }

    private func handleTranslationFailure(
        _ error: any Error,
        item: PendingTranslation
    ) async {
        await observers.onDiscarded(item.request.current.id, false, false)
        let runtimeError = (error as? MLingoError)
            ?? .translationFailed(error.localizedDescription)
        await observers.onError(runtimeError)
        guard runtimeError.pausesTranslationSession else { return }
        isPaused = true
        await discardPending()
    }

    private func discardPending() async {
        let discarded = pending
        pending.removeAll(keepingCapacity: false)
        for pendingItem in discarded {
            await observers.onDiscarded(pendingItem.request.current.id, false, false)
        }
        await observers.onQueueDepth(0)
    }
}
