import CryptoKit
import Foundation
import Testing
@testable import MLingoCore

private let validConfig = Data(#"{"model_type":"whisper"}"#.utf8)

private func makeEntry(
    files: [String] = ["config.json", "tokenizer.json", "model.safetensors"],
    required: [String] = ["config.json", "tokenizer.json", "model.safetensors"],
    expectedBytes: UInt64 = 1_000,
    digests: [String: String] = [:]
) throws -> ModelCatalogEntry {
    ModelCatalogEntry(
        id: ModelID("owner/model"),
        slug: try #require(ModelStorageSlug("model")),
        role: .chat,
        repository: "owner/model",
        revision: String(repeating: "b", count: 40),
        files: files,
        requiredFiles: required,
        expectedBytes: expectedBytes,
        expectedDigests: digests
    )
}

@discardableResult
private func writeFile(_ name: String, _ data: Data, in directory: URL) throws -> URL {
    let url = directory.appending(path: name, directoryHint: .notDirectory)
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try data.write(to: url, options: [.atomic])
    return url
}

/// A snapshot that passes every check, so each test can break exactly one thing.
private func makeValidSnapshot(in directory: URL, weightBytes: Int = 128) throws {
    try writeFile("config.json", validConfig, in: directory)
    try writeFile("tokenizer.json", Data(#"{"version":"1"}"#.utf8), in: directory)
    try writeFile("model.safetensors", Data(repeating: 0x42, count: weightBytes), in: directory)
}

private func expectIssue(
    _ expected: ModelStoreIssue,
    verifying directory: URL,
    against entry: ModelCatalogEntry,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(sourceLocation: sourceLocation) {
        try ModelSnapshotVerifier().verify(directory, against: entry)
    } throws: { error in
        (error as? ModelStoreError)?.issue == expected
    }
}

@Test
func verifierAcceptsACompleteSnapshotAndReturnsItsByteCount() throws {
    let temporary = try TemporaryDirectory(label: "Verify")
    defer { temporary.remove() }
    try makeValidSnapshot(in: temporary.url, weightBytes: 128)

    let bytes = try ModelSnapshotVerifier().verify(temporary.url, against: try makeEntry())
    #expect(bytes == UInt64(validConfig.count + 15 + 128))
}

@Test
func verifierRejectsAMissingRequiredFile() throws {
    let temporary = try TemporaryDirectory(label: "Verify")
    defer { temporary.remove() }
    try writeFile("config.json", validConfig, in: temporary.url)
    try writeFile("model.safetensors", Data(repeating: 0x42, count: 8), in: temporary.url)

    expectIssue(.missingRequiredFile("tokenizer.json"), verifying: temporary.url, against: try makeEntry())
}

@Test
func verifierRejectsAnEmptyRequiredFile() throws {
    let temporary = try TemporaryDirectory(label: "Verify")
    defer { temporary.remove() }
    try makeValidSnapshot(in: temporary.url)
    try writeFile("tokenizer.json", Data(), in: temporary.url)

    expectIssue(.emptyFile("tokenizer.json"), verifying: temporary.url, against: try makeEntry())
}

@Test
func verifierRejectsUnparseableJSON() throws {
    let temporary = try TemporaryDirectory(label: "Verify")
    defer { temporary.remove() }
    try makeValidSnapshot(in: temporary.url)
    try writeFile("config.json", Data("not json".utf8), in: temporary.url)

    expectIssue(.malformedManifest("config.json"), verifying: temporary.url, against: try makeEntry())
}

@Test
func verifierRejectsASnapshotWithoutWeights() throws {
    let temporary = try TemporaryDirectory(label: "Verify")
    defer { temporary.remove() }
    try writeFile("config.json", validConfig, in: temporary.url)
    try writeFile("tokenizer.json", Data(#"{"v":1}"#.utf8), in: temporary.url)
    let entry = try makeEntry(
        files: ["config.json", "tokenizer.json"],
        required: ["config.json", "tokenizer.json"]
    )

    expectIssue(.missingRequiredFile("model.safetensors"), verifying: temporary.url, against: entry)
}

@Test
func verifierRejectsASymlinkInsideTheSnapshot() throws {
    let temporary = try TemporaryDirectory(label: "Verify")
    defer { temporary.remove() }
    try makeValidSnapshot(in: temporary.url)
    let target = try writeFile("real.bin", Data(repeating: 1, count: 4), in: temporary.url)
    try FileManager.default.createSymbolicLink(
        at: temporary.appending("alias.bin"),
        withDestinationURL: target
    )

    // Staging is built by hardlinking, so a symlink means something other than us wrote here.
    expectIssue(.unsafeSnapshotEntry("alias.bin"), verifying: temporary.url, against: try makeEntry())
}

@Test
func verifierRejectsASymlinkEscapingTheSnapshotRoot() throws {
    let temporary = try TemporaryDirectory(label: "Verify")
    defer { temporary.remove() }
    try makeValidSnapshot(in: temporary.url)
    try FileManager.default.createSymbolicLink(
        at: temporary.appending("escape"),
        withDestinationURL: URL(fileURLWithPath: "/etc")
    )

    expectIssue(.unsafeSnapshotEntry("escape"), verifying: temporary.url, against: try makeEntry())
}

@Test
func verifierRejectsNestedDirectories() throws {
    let temporary = try TemporaryDirectory(label: "Verify")
    defer { temporary.remove() }
    try makeValidSnapshot(in: temporary.url)
    try FileManager.default.createDirectory(
        at: temporary.appending("onnx", isDirectory: true),
        withIntermediateDirectories: true
    )

    expectIssue(.unsafeSnapshotEntry("onnx"), verifying: temporary.url, against: try makeEntry())
}

@Test
func verifierRejectsTooManyFiles() throws {
    let temporary = try TemporaryDirectory(label: "Verify")
    defer { temporary.remove() }
    try makeValidSnapshot(in: temporary.url)
    for index in 0..<200 {
        try writeFile("extra-\(index).bin", Data(repeating: 0, count: 1), in: temporary.url)
    }

    #expect {
        try ModelSnapshotVerifier().verify(temporary.url, against: try makeEntry())
    } throws: { error in
        if case .snapshotTooLarge = (error as? ModelStoreError)?.issue { return true }
        return false
    }
}

@Test
func verifierRejectsASnapshotFarLargerThanExpected() throws {
    let temporary = try TemporaryDirectory(label: "Verify")
    defer { temporary.remove() }
    try makeValidSnapshot(in: temporary.url, weightBytes: 4_000)

    // A repository that grew fourfold at a pinned commit is a supply problem, not a download.
    #expect {
        try ModelSnapshotVerifier().verify(temporary.url, against: try makeEntry(expectedBytes: 1_000))
    } throws: { error in
        if case .snapshotTooLarge = (error as? ModelStoreError)?.issue { return true }
        return false
    }
}

@Test
func verifierAcceptsASnapshotSlightlyLargerThanExpected() throws {
    let temporary = try TemporaryDirectory(label: "Verify")
    defer { temporary.remove() }
    try makeValidSnapshot(in: temporary.url, weightBytes: 1_100)

    // Headroom exists because expectedBytes is a recorded sum, not a guarantee.
    let bytes = try ModelSnapshotVerifier().verify(temporary.url, against: try makeEntry(expectedBytes: 1_100))
    #expect(bytes > 1_100)
}

@Test
func verifierAcceptsAMatchingDigest() throws {
    let temporary = try TemporaryDirectory(label: "Verify")
    defer { temporary.remove() }
    let weights = Data(repeating: 0x42, count: 128)
    try makeValidSnapshot(in: temporary.url, weightBytes: 128)
    let digest = SHA256.hash(data: weights).map { String(format: "%02x", $0) }.joined()

    let entry = try makeEntry(digests: ["model.safetensors": digest])
    #expect(try ModelSnapshotVerifier().verify(temporary.url, against: entry) > 0)
}

@Test
func verifierRejectsAMismatchedDigest() throws {
    let temporary = try TemporaryDirectory(label: "Verify")
    defer { temporary.remove() }
    try makeValidSnapshot(in: temporary.url)

    let entry = try makeEntry(digests: ["model.safetensors": String(repeating: "0", count: 64)])
    expectIssue(.digestMismatch("model.safetensors"), verifying: temporary.url, against: entry)
}

@Test
func verifierRejectsAMissingSnapshotDirectory() throws {
    let temporary = try TemporaryDirectory(label: "Verify")
    defer { temporary.remove() }
    let absent = temporary.appending("absent", isDirectory: true)

    expectIssue(.storageUnavailable, verifying: absent, against: try makeEntry())
}

@Test
func modelQuarantineReasonCoversEveryVerificationIssue() {
    #expect(ModelQuarantineReason(issue: .missingRequiredFile("a")) == .missingFile)
    #expect(ModelQuarantineReason(issue: .emptyFile("a")) == .emptyFile)
    #expect(ModelQuarantineReason(issue: .malformedManifest("a")) == .malformedManifest)
    #expect(ModelQuarantineReason(issue: .unsafeSnapshotEntry("a")) == .unsafeEntry)
    #expect(ModelQuarantineReason(issue: .snapshotTooLarge(actualBytes: 2, allowedBytes: 1)) == .tooLarge)
    #expect(ModelQuarantineReason(issue: .digestMismatch("a")) == .digestMismatch)
    // Transport and disk failures are retried, never quarantined.
    #expect(ModelQuarantineReason(issue: .transportFailure) == nil)
    #expect(ModelQuarantineReason(issue: .authenticationRequired) == nil)
}
