import Foundation
import MLingoCore
import Testing
@testable import MLingoApp

@Test
func compositionRefusesToBuildWithoutAStorageRoot() {
    // Application Support can be unavailable; the app must still launch, with the Models pane
    // reporting it rather than the process failing to compose.
    #expect(ModelStoreComposition(
        root: nil,
        credentialStore: nil,
        runtimeResidency: []
    ) == nil)
}

@Test
func compositionAsksEveryRegisteredRuntimeBeforeAModelIsDeleted() async throws {
    let temporary = FileManager.default.temporaryDirectory
        .appending(path: "MLingo-Composition-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: temporary) }

    let runtime = RecordingResidency()
    let composition = try #require(ModelStoreComposition(
        root: temporary,
        credentialStore: nil,
        runtimeResidency: [runtime]
    ))

    let directory = composition.storageRoot.appending(path: "installed/whisper-base-mlx")
    #expect(await composition.residency.requestEviction(at: directory))
    // Both the injected runtime and the Whisper engine the composition created must have been
    // asked; a runtime that is never consulted can be holding files during a delete.
    #expect(await runtime.evictionRequests == 1)
    #expect(await composition.residency.residentModelDirectories().isEmpty)
}

private actor RecordingResidency: LocalModelResidencyReporting {
    private(set) var evictionRequests = 0

    func residentModelDirectories() -> Set<URL> { [] }
    func leaseCount(at directory: URL) -> Int { 0 }

    func requestEviction(at directory: URL) -> Bool {
        evictionRequests += 1
        return true
    }
}
