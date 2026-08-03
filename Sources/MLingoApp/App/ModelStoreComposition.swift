import Foundation
import MLingoCore

/// Wires the model store to the runtimes that can hold its files.
///
/// Composition is circular — the Whisper engine needs the manager as its directory resolver, and
/// the manager needs the engine's residency before it may delete anything — so the composite is
/// built empty, handed to the manager, and filled once the engine exists.
///
/// It is a type rather than a few lines inside `live()` so the wiring can be tested against a
/// temporary directory; `live()` itself would write into the real Application Support folder.
struct ModelStoreComposition {
    let manager: ModelManager
    let whisperEngine: MLXWhisperEngine
    let residency: CompositeModelResidencyReporter
    let storageRoot: URL

    /// Returns `nil` when there is no usable storage root, which is the one failure the app has
    /// to survive: without it Whisper falls back to its previous download path and the Models
    /// pane says so, rather than the app failing to launch.
    init?(
        root: URL?,
        credentialStore: (any ProviderCredentialStoreProtocol)?,
        runtimeResidency: [any LocalModelResidencyReporting]
    ) {
        guard let root else { return nil }
        let layout = ModelStorageLayout(root: root)
        guard (try? layout.createBuckets()) != nil else { return nil }

        let residency = CompositeModelResidencyReporter()
        let manager = ModelManager(
            layout: layout,
            downloader: HubModelSnapshotDownloader(cacheDirectory: layout.hubCacheRoot),
            credentialStore: credentialStore,
            residency: residency
        )
        let whisperEngine = MLXWhisperEngine(modelDirectoryResolver: manager)
        residency.register(whisperEngine)
        for reporter in runtimeResidency {
            residency.register(reporter)
        }

        self.manager = manager
        self.whisperEngine = whisperEngine
        self.residency = residency
        storageRoot = layout.root
    }
}
