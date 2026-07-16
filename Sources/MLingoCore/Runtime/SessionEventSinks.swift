import Foundation

struct OriginalSubtitleSink: Sendable {
    private let handler: @Sendable (Transcript) async -> Void

    init(handler: @escaping @Sendable (Transcript) async -> Void) {
        self.handler = handler
    }

    func receive(_ transcript: Transcript) async {
        await handler(transcript)
    }
}

actor SessionTranscriptRouter {
    private let sessionID: SessionID
    private let originalSink: OriginalSubtitleSink
    private let translationWorker: TranslationWorker?
    private let isSessionActive: @Sendable () async -> Bool
    private let onTranscriptionComplete: @Sendable (UUID) async -> Void

    init(
        sessionID: SessionID,
        originalSink: OriginalSubtitleSink,
        translationWorker: TranslationWorker?,
        isSessionActive: @escaping @Sendable () async -> Bool,
        onTranscriptionComplete: @escaping @Sendable (UUID) async -> Void
    ) {
        self.sessionID = sessionID
        self.originalSink = originalSink
        self.translationWorker = translationWorker
        self.isSessionActive = isSessionActive
        self.onTranscriptionComplete = onTranscriptionComplete
    }

    func route(_ envelope: EventEnvelope<TranscriptCompleted>) async {
        guard envelope.sessionID == sessionID, await isSessionActive() else { return }
        let transcript = envelope.payload.transcript
        await originalSink.receive(transcript)
        guard await isSessionActive() else { return }
        if let translationWorker {
            await translationWorker.submit(envelope)
        } else {
            await onTranscriptionComplete(transcript.id)
        }
    }
}

@MainActor
final class TranslatedSubtitleSink {
    private let overlayEngine: any OverlayEngineProtocol
    private let settings: AppSettings
    private let now: PerformanceNow
    private let onDiscarded: @MainActor @Sendable (UUID) -> Void
    private let onRendered: @MainActor @Sendable (
        UUID,
        PerformanceInstant,
        PerformanceInstant
    ) -> Void
    private var queue = OrderedSubtitleQueue()
    private var subtitleTraceIDs: [UUID: UUID] = [:]

    init(
        overlayEngine: any OverlayEngineProtocol,
        settings: AppSettings,
        now: @escaping PerformanceNow,
        onDiscarded: @escaping @MainActor @Sendable (UUID) -> Void,
        onRendered: @escaping @MainActor @Sendable (
            UUID,
            PerformanceInstant,
            PerformanceInstant
        ) -> Void
    ) {
        self.overlayEngine = overlayEngine
        self.settings = settings
        self.now = now
        self.onDiscarded = onDiscarded
        self.onRendered = onRendered
    }

    func receive(_ envelope: EventEnvelope<TranslationCompleted>) {
        let completed = envelope.payload
        subtitleTraceIDs[completed.subtitle.id] = completed.sourceTranscriptID
        let ready = queue.insert(completed.subtitle)
        if ready.isEmpty {
            subtitleTraceIDs[completed.subtitle.id] = nil
            onDiscarded(completed.sourceTranscriptID)
        }
        for item in ready {
            let transcriptID = subtitleTraceIDs.removeValue(forKey: item.id)
                ?? completed.sourceTranscriptID
            let renderStarted = now()
            overlayEngine.update(with: item, settings: settings)
            onRendered(transcriptID, renderStarted, now())
        }
    }
}
