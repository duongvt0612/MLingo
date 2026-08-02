import Foundation

/// Counts every request any `URLSession` built on the default configuration attempts.
///
/// Same trick as the Milestone 07 local-inference spy: `canInit` records the attempt and then
/// declines to handle it, so traffic proceeds untouched and the count is evidence rather than a
/// simulation. Used to prove the default Model Store suite never reaches the network — a claim
/// that is otherwise impossible to distinguish from "the network happened to be fast".
///
/// It cannot see a session created with a custom `protocolClasses`, nor raw sockets. Both are
/// out of reach for the code under test, which goes through `URLSession`.
final class ModelStoreNetworkSpy {
    private static let counter = SpyCounter()

    var requestCount: Int { Self.counter.value }

    func start() {
        Self.counter.reset()
        URLProtocol.registerClass(SpyURLProtocol.self)
    }

    func stop() {
        URLProtocol.unregisterClass(SpyURLProtocol.self)
    }

    fileprivate static func record() {
        counter.increment()
    }
}

private final class SpyCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = 0

    var value: Int { lock.withLock { storedValue } }
    func increment() { lock.withLock { storedValue += 1 } }
    func reset() { lock.withLock { storedValue = 0 } }
}

private final class SpyURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool {
        ModelStoreNetworkSpy.record()
        return false
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {}
    override func stopLoading() {}
}
