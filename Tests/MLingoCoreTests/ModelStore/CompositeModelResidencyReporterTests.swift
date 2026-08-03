import Foundation
import Testing
@testable import MLingoCore

private let chatDirectory = URL(fileURLWithPath: "/tmp/mlingo-models/installed/qwen")
private let whisperDirectory = URL(fileURLWithPath: "/tmp/mlingo-models/installed/whisper")

@Test
func compositeUnionsResidentDirectoriesAcrossRuntimes() async {
    let composite = CompositeModelResidencyReporter()
    composite.register(CountingResidency(directories: [chatDirectory], leases: 0))
    composite.register(CountingResidency(directories: [whisperDirectory], leases: 0))

    #expect(await composite.residentModelDirectories() == [chatDirectory, whisperDirectory])
}

@Test
func compositeSumsLeaseCountsForTheSameDirectory() async {
    let composite = CompositeModelResidencyReporter()
    composite.register(CountingResidency(directories: [chatDirectory], leases: 2))
    composite.register(CountingResidency(directories: [chatDirectory], leases: 3))

    #expect(await composite.leaseCount(at: chatDirectory) == 5)
}

@Test
func compositeRefusesEvictionWhenOneRuntimeRefusesAndStillAsksTheOthers() async {
    let refusing = CountingResidency(directories: [chatDirectory], leases: 1, evictionSucceeds: false)
    let accepting = CountingResidency(directories: [chatDirectory], leases: 0, evictionSucceeds: true)
    let composite = CompositeModelResidencyReporter()
    composite.register(refusing)
    composite.register(accepting)

    #expect(await composite.requestEviction(at: chatDirectory) == false)
    // Every runtime is asked even after the first refusal: eviction is idempotent, and a partial
    // pass costs at most one reload, whereas short-circuiting would leave the others holding files.
    #expect(await refusing.evictionRequests == 1)
    #expect(await accepting.evictionRequests == 1)
}

@Test
func compositeAllowsEvictionWhenEveryRuntimeAgrees() async {
    let composite = CompositeModelResidencyReporter()
    composite.register(CountingResidency(directories: [chatDirectory], leases: 0, evictionSucceeds: true))
    composite.register(CountingResidency(directories: [], leases: 0, evictionSucceeds: true))

    #expect(await composite.requestEviction(at: chatDirectory))
}

@Test
func compositeWithoutReportersHoldsNothing() async {
    let composite = CompositeModelResidencyReporter()

    #expect(await composite.residentModelDirectories().isEmpty)
    #expect(await composite.leaseCount(at: chatDirectory) == 0)
    #expect(await composite.requestEviction(at: chatDirectory))
}

@Test
func compositeSeesReportersRegisteredAfterItWasHandedToTheManager() async {
    // Composition order requires this: the Whisper engine needs the manager as its resolver, and
    // the manager needs the engine's residency, so the composite is created empty and filled after.
    let composite = CompositeModelResidencyReporter()
    let manager: any LocalModelResidencyReporting = composite
    composite.register(CountingResidency(directories: [whisperDirectory], leases: 4))

    #expect(await manager.leaseCount(at: whisperDirectory) == 4)
}

// MARK: - Doubles

private actor CountingResidency: LocalModelResidencyReporting {
    private let directories: Set<URL>
    private let leases: Int
    private let evictionSucceeds: Bool
    private(set) var evictionRequests = 0

    init(directories: Set<URL>, leases: Int, evictionSucceeds: Bool = true) {
        self.directories = directories
        self.leases = leases
        self.evictionSucceeds = evictionSucceeds
    }

    func residentModelDirectories() -> Set<URL> { directories }

    func leaseCount(at directory: URL) -> Int {
        directories.contains(directory) ? leases : 0
    }

    func requestEviction(at directory: URL) -> Bool {
        evictionRequests += 1
        return evictionSucceeds
    }
}
