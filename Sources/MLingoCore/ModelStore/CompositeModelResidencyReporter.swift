import Foundation

/// Speaks for every runtime that can hold a model's files.
///
/// `ModelManager` takes one residency reporter, but a running app has two: `BuiltInMLXRuntime` for
/// chat and embeddings, and `MLXWhisperEngine` for speech. Both must have let go before a directory
/// can be removed.
///
/// It is filled after construction because composition is circular: the Whisper engine needs the
/// manager as its directory resolver, and the manager needs the engine's residency. Creating this
/// empty, handing it to the manager, and registering afterwards is what breaks the cycle.
///
/// A lock rather than an actor so `register` can be called from the synchronous composition root.
/// The array is only ever appended to at launch and read afterwards, so contention is not a concern.
public final class CompositeModelResidencyReporter: LocalModelResidencyReporting, @unchecked Sendable {
    private let lock = NSLock()
    private var reporters: [any LocalModelResidencyReporting] = []

    public init() {}

    public func register(_ reporter: any LocalModelResidencyReporting) {
        lock.withLock { reporters.append(reporter) }
    }

    public func residentModelDirectories() async -> Set<URL> {
        var directories: Set<URL> = []
        for reporter in current() {
            directories.formUnion(await reporter.residentModelDirectories())
        }
        return directories
    }

    public func leaseCount(at directory: URL) async -> Int {
        var total = 0
        for reporter in current() {
            total += await reporter.leaseCount(at: directory)
        }
        return total
    }

    /// Asks every runtime, including those after the first refusal.
    ///
    /// Eviction is idempotent and unloading an idle model costs at most one reload, whereas
    /// stopping at the first `false` would leave the remaining runtimes still holding the files
    /// with nothing having asked them to stop.
    public func requestEviction(at directory: URL) async -> Bool {
        var evicted = true
        for reporter in current() where await reporter.requestEviction(at: directory) == false {
            evicted = false
        }
        return evicted
    }

    private func current() -> [any LocalModelResidencyReporting] {
        lock.withLock { reporters }
    }
}
