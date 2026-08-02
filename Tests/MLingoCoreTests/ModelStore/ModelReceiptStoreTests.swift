import Foundation
import Testing
@testable import MLingoCore

private func makeReceipt(
    id: String = "mlx-community/whisper-base-mlx",
    slug: String = "whisper-base-mlx",
    status: ModelInstallReceipt.Status = .installed
) throws -> ModelInstallReceipt {
    ModelInstallReceipt(
        modelID: ModelID(id),
        slug: try #require(ModelStorageSlug(slug)),
        repository: "mlx-community/whisper-base-asr-fp16",
        revision: String(repeating: "5", count: 40),
        installedAt: Date(timeIntervalSince1970: 1_700_000_000),
        byteCount: 148_065_824,
        status: status
    )
}

@Test
func receiptStoreRoundTripsAnIndex() async throws {
    let temporary = try TemporaryDirectory(label: "Receipts")
    defer { temporary.remove() }
    let store = FileModelReceiptStore(fileURL: temporary.appending("installed.json"))

    var index = ModelReceiptIndex()
    let receipt = try makeReceipt()
    index.insert(receipt)
    index.insert(try makeReceipt(
        id: "intfloat/multilingual-e5-small",
        slug: "multilingual-e5-small",
        status: .quarantined(reason: .digestMismatch)
    ))
    try await store.save(index)

    let loaded = try await store.load()
    #expect(loaded == index)
    #expect(loaded.receipt(for: ModelID("mlx-community/whisper-base-mlx")) == receipt)
    #expect(
        loaded.receipt(for: ModelID("intfloat/multilingual-e5-small"))?.status
            == .quarantined(reason: .digestMismatch)
    )
}

@Test
func receiptStoreReturnsAnEmptyIndexForAMissingFile() async throws {
    let temporary = try TemporaryDirectory(label: "Receipts")
    defer { temporary.remove() }
    let store = FileModelReceiptStore(fileURL: temporary.appending("installed.json"))

    let loaded = try await store.load()
    #expect(loaded.receipts.isEmpty)
    #expect(loaded.schemaVersion == ModelReceiptIndex.currentSchemaVersion)
}

@Test
func receiptStoreRepairsMalformedJSONWithoutDeletingIt() async throws {
    let temporary = try TemporaryDirectory(label: "Receipts")
    defer { temporary.remove() }
    let fileURL = temporary.appending("installed.json")
    try Data("{{{ not json".utf8).write(to: fileURL)
    let store = FileModelReceiptStore(fileURL: fileURL)

    let loaded = try await store.load()
    #expect(loaded.receipts.isEmpty)
    // The directories it described may still be on disk; reconciliation decides their fate,
    // so a corrupt index is never grounds for deleting the file or the models.
    #expect(FileManager.default.fileExists(atPath: fileURL.path))
}

@Test
func receiptStoreIgnoresAnUnknownSchemaVersion() async throws {
    let temporary = try TemporaryDirectory(label: "Receipts")
    defer { temporary.remove() }
    let fileURL = temporary.appending("installed.json")
    try Data(#"{"schemaVersion":99,"receipts":{}}"#.utf8).write(to: fileURL)
    let store = FileModelReceiptStore(fileURL: fileURL)

    let loaded = try await store.load()
    #expect(loaded.receipts.isEmpty)
    #expect(loaded.schemaVersion == ModelReceiptIndex.currentSchemaVersion)
}

@Test
func receiptStoreRejectsAnUnsafeSlugFromDisk() async throws {
    let temporary = try TemporaryDirectory(label: "Receipts")
    defer { temporary.remove() }
    let fileURL = temporary.appending("installed.json")
    let hostile = """
    {"schemaVersion":1,"receipts":{"a/b":{"modelID":"a/b","slug":"../../etc",\
    "repository":"a/b","revision":"\(String(repeating: "1", count: 40))",\
    "installedAt":0,"byteCount":1,"status":{"installed":{}}}}}
    """
    try Data(hostile.utf8).write(to: fileURL)
    let store = FileModelReceiptStore(fileURL: fileURL)

    // A slug is failable at decode, so a traversal attempt cannot become a live path.
    let loaded = try await store.load()
    #expect(loaded.receipts.isEmpty)
}

@Test
func receiptStoreWritesAtomicallyAndLeavesNoTemporaryFile() async throws {
    let temporary = try TemporaryDirectory(label: "Receipts")
    defer { temporary.remove() }
    let store = FileModelReceiptStore(fileURL: temporary.appending("installed.json"))

    var index = ModelReceiptIndex()
    index.insert(try makeReceipt())
    try await store.save(index)
    try await store.save(index)

    let contents = try FileManager.default.contentsOfDirectory(atPath: temporary.url.path)
    #expect(contents == ["installed.json"], "unexpected leftovers: \(contents)")
    #expect(try await store.load() == index)
}

@Test
func receiptStoreCreatesItsParentDirectory() async throws {
    let temporary = try TemporaryDirectory(label: "Receipts")
    defer { temporary.remove() }
    let nested = temporary.appending("Models", isDirectory: true)
        .appending(path: "installed.json", directoryHint: .notDirectory)
    let store = FileModelReceiptStore(fileURL: nested)

    try await store.save(ModelReceiptIndex())
    #expect(FileManager.default.fileExists(atPath: nested.path))
}

@Test
func receiptIndexInsertsAndRemovesByModelIdentifier() throws {
    var index = ModelReceiptIndex()
    let receipt = try makeReceipt()
    index.insert(receipt)
    #expect(index.receipts.count == 1)

    index.insert(try makeReceipt(status: .quarantined(reason: .missingFile)))
    #expect(index.receipts.count == 1, "the same model must not accumulate receipts")
    #expect(index.receipt(for: receipt.modelID)?.status == .quarantined(reason: .missingFile))

    index.remove(receipt.modelID)
    #expect(index.receipts.isEmpty)
    #expect(index.receipt(for: receipt.modelID) == nil)
}
