import Foundation
import Testing

/// Shared helpers for suites added from Milestone 08a onward.
///
/// Earlier suites carry their own file-private equivalents and a good number of fixed
/// `Task.sleep` waits. Those are deliberately left alone here; this file exists so new
/// suites stop adding to that pile, not to migrate it.

/// Polls until `condition` holds, then returns. Records an issue if the deadline passes.
///
/// Prefer this over a fixed sleep: it fails loudly on a real hang instead of passing by
/// luck on a fast machine and flaking on a slow one.
func eventually(
    timeout: Duration = .seconds(1),
    _ condition: @escaping @Sendable () async -> Bool,
    sourceLocation: SourceLocation = #_sourceLocation
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("Condition was not met within \(timeout)", sourceLocation: sourceLocation)
}

/// A unique directory under the system temporary directory.
///
/// Model Store suites must never touch the real Application Support directory: `--no-parallel`
/// serialises tests within one run but does nothing about state left behind for the next run.
struct TemporaryDirectory {
    let url: URL

    init(label: String = "ModelStore") throws {
        url = FileManager.default.temporaryDirectory
            .appending(path: "MLingo-\(label)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// Call from a `defer` in the test that created the directory.
    func remove() {
        try? FileManager.default.removeItem(at: url)
    }

    func appending(_ component: String, isDirectory: Bool = false) -> URL {
        url.appending(path: component, directoryHint: isDirectory ? .isDirectory : .notDirectory)
    }
}

/// A lock-guarded counter usable from any isolation domain.
final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = 0

    init() {}

    var value: Int {
        lock.withLock { storedValue }
    }

    func increment() {
        lock.withLock { storedValue += 1 }
    }

    func reset() {
        lock.withLock { storedValue = 0 }
    }
}
