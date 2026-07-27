import Foundation
import Testing
@testable import MLingoCore

private func makeLayout(_ temporary: TemporaryDirectory) throws -> ModelStorageLayout {
    let layout = ModelStorageLayout(root: temporary.appending("Models", isDirectory: true))
    try layout.createBuckets()
    return layout
}

@discardableResult
private func write(_ name: String, bytes: Int, in directory: URL) throws -> URL {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appending(path: name, directoryHint: .notDirectory)
    try Data(repeating: 0x41, count: bytes).write(to: url, options: [.atomic])
    return url
}

private func makeEntry(expectedBytes: UInt64) throws -> ModelCatalogEntry {
    ModelCatalogEntry(
        id: ModelID("owner/model"),
        slug: try #require(ModelStorageSlug("model")),
        role: .chat,
        repository: "owner/model",
        revision: String(repeating: "c", count: 40),
        files: ["config.json", "model.safetensors"],
        requiredFiles: ["config.json"],
        expectedBytes: expectedBytes
    )
}

@Test
func accountingSumsBytesPerBucketAndPerModel() throws {
    let temporary = try TemporaryDirectory(label: "Accounting")
    defer { temporary.remove() }
    let layout = try makeLayout(temporary)
    let whisper = try #require(ModelStorageSlug("whisper-base-mlx"))
    let qwen = try #require(ModelStorageSlug("qwen3-0.6b-4bit"))

    try write("model.safetensors", bytes: 100, in: layout.installed(whisper))
    try write("config.json", bytes: 20, in: layout.installed(whisper))
    try write("model.safetensors", bytes: 300, in: layout.installed(qwen))
    try write("partial.bin", bytes: 7, in: layout.staging(whisper, run: UUID()))
    try write("broken.bin", bytes: 5, in: layout.quarantine(qwen, run: UUID()))
    try write("blob", bytes: 11, in: layout.hubCacheRoot.appending(path: "blobs", directoryHint: .isDirectory))

    let usage = try ModelStorageAccounting(layout: layout).usage()

    #expect(usage.installedBytes == 420)
    #expect(usage.stagingBytes == 7)
    #expect(usage.quarantineBytes == 5)
    #expect(usage.hubCacheBytes == 11)
    #expect(usage.totalBytes == 443)
    #expect(usage.perModel[whisper] == 120)
    #expect(usage.perModel[qwen] == 300)
}

@Test
func accountingCountsHardlinkedBytesOnlyOnce() throws {
    let temporary = try TemporaryDirectory(label: "Accounting")
    defer { temporary.remove() }
    let layout = try makeLayout(temporary)
    let slug = try #require(ModelStorageSlug("model"))

    // Installation hardlinks out of the cache, so the same bytes appear under two paths until
    // the cache entry is dropped. Reporting them twice would tell the user to free space they
    // do not actually owe.
    let blob = try write("blob", bytes: 500, in: layout.hubCacheRoot)
    try FileManager.default.createDirectory(at: layout.installed(slug), withIntermediateDirectories: true)
    try FileManager.default.linkItem(
        at: blob,
        to: layout.installed(slug).appending(path: "model.safetensors", directoryHint: .notDirectory)
    )

    let usage = try ModelStorageAccounting(layout: layout).usage()
    #expect(usage.totalBytes == 500)
    // Per-bucket figures still describe what each bucket holds.
    #expect(usage.installedBytes == 500)
    #expect(usage.hubCacheBytes == 500)
}

@Test
func accountingCountsOnlyRegularFiles() throws {
    let temporary = try TemporaryDirectory(label: "Accounting")
    defer { temporary.remove() }
    let layout = try makeLayout(temporary)
    let slug = try #require(ModelStorageSlug("model"))
    let target = try write("real.bin", bytes: 40, in: layout.installed(slug))
    try FileManager.default.createDirectory(
        at: layout.installed(slug).appending(path: "nested", directoryHint: .isDirectory),
        withIntermediateDirectories: true
    )
    try FileManager.default.createSymbolicLink(
        at: layout.installed(slug).appending(path: "alias.bin", directoryHint: .notDirectory),
        withDestinationURL: target
    )

    let usage = try ModelStorageAccounting(layout: layout).usage()
    #expect(usage.installedBytes == 40)
}

@Test
func accountingReportsZeroForAnEmptyStore() throws {
    let temporary = try TemporaryDirectory(label: "Accounting")
    defer { temporary.remove() }
    let layout = try makeLayout(temporary)

    let usage = try ModelStorageAccounting(layout: layout).usage()
    #expect(usage.totalBytes == 0)
    #expect(usage.perModel.isEmpty)
}

@Test
func diskPreflightThrowsWhenAvailableBytesAreBelowExpectedPlusHeadroom() throws {
    let temporary = try TemporaryDirectory(label: "Accounting")
    defer { temporary.remove() }
    let layout = try makeLayout(temporary)
    let entry = try makeEntry(expectedBytes: 1_000)
    let available = ModelStorageAccounting.headroomBytes + 999
    let accounting = ModelStorageAccounting(layout: layout, availableBytes: { available })

    #expect {
        try accounting.preflight(entry)
    } throws: { error in
        (error as? ModelStoreError)?.issue
            == .insufficientDiskSpace(
                requiredBytes: 1_000 + ModelStorageAccounting.headroomBytes,
                availableBytes: available
            )
    }
}

@Test
func diskPreflightPassesWithHeadroom() throws {
    let temporary = try TemporaryDirectory(label: "Accounting")
    defer { temporary.remove() }
    let layout = try makeLayout(temporary)
    let entry = try makeEntry(expectedBytes: 1_000)
    let accounting = ModelStorageAccounting(
        layout: layout,
        availableBytes: { ModelStorageAccounting.headroomBytes + 1_000 }
    )

    try accounting.preflight(entry)
}

@Test
func diskPreflightAsksForOneCopyBecauseInstallationHardlinks() throws {
    let temporary = try TemporaryDirectory(label: "Accounting")
    defer { temporary.remove() }
    let layout = try makeLayout(temporary)
    let entry = try makeEntry(expectedBytes: 4_000_000_000)
    // Copying would need twice the model size; hardlinking needs one copy plus headroom.
    let accounting = ModelStorageAccounting(
        layout: layout,
        availableBytes: { 4_000_000_000 + ModelStorageAccounting.headroomBytes }
    )

    try accounting.preflight(entry)
}

@Test
func availableBytesReportsAPlausibleFigureForTheRealVolume() throws {
    let temporary = try TemporaryDirectory(label: "Accounting")
    defer { temporary.remove() }
    let layout = try makeLayout(temporary)

    let available = try ModelStorageAccounting(layout: layout).availableBytes()
    #expect(available > 0)
}
