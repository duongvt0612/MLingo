import Foundation
import Testing
@testable import MLingoCore

@Test
func catalogV1ContainsExactlyThreePinnedEntries() {
    let entries = MLingoModelCatalog.v1
    #expect(entries.count == 3)
    #expect(entries.map(\.role) == [.speechRecognition, .chat, .embedding])
}

@Test
func everyCatalogEntryIsWellFormed() {
    for entry in MLingoModelCatalog.v1 {
        #expect(entry.validationIssues.isEmpty, "\(entry.id) has issues: \(entry.validationIssues)")
        #expect(entry.revision.count == 40, "\(entry.id) revision is not a commit hash")
        #expect(
            entry.revision.allSatisfy { $0.isHexDigit && !$0.isUppercase },
            "\(entry.id) revision is not lowercase hex"
        )
        #expect(entry.expectedBytes > 0)
        #expect(!entry.files.isEmpty)
    }
}

@Test
func catalogEntryIdentifiersAndSlugsAreUnique() {
    let entries = MLingoModelCatalog.v1
    #expect(Set(entries.map(\.id)).count == entries.count)
    #expect(Set(entries.map(\.slug)).count == entries.count)
    #expect(Set(entries.map(\.repository)).count == entries.count)
}

@Test
func catalogFilePatternsAreExactNamesRatherThanWildcards() {
    // Upstream matches with fnmatch and no FNM_PATHNAME, so `*` crosses `/`. A pattern like
    // `*.json` would also pull in nested files such as `onnx/config.json`, which is why every
    // entry lists exact root-level names.
    for entry in MLingoModelCatalog.v1 {
        for file in entry.files {
            #expect(!file.contains("*"), "\(entry.id) uses a wildcard: \(file)")
            #expect(!file.contains("?"), "\(entry.id) uses a wildcard: \(file)")
            #expect(!file.contains("/"), "\(entry.id) lists a nested path: \(file)")
        }
    }
}

@Test
func everyCatalogEntryRequiresATokenizerAndWeights() {
    // `WhisperModel.fromDirectory` silently downloads openai/whisper-large-v3 when a tokenizer
    // is absent. Requiring the file here is what keeps an installed model genuinely offline.
    for entry in MLingoModelCatalog.v1 {
        #expect(entry.requiredFiles.contains("tokenizer.json"), "\(entry.id) does not require a tokenizer")
        #expect(entry.requiredFiles.contains("config.json"))
        #expect(entry.files.contains { $0.hasSuffix(".safetensors") }, "\(entry.id) has no weights")
        #expect(Set(entry.requiredFiles).isSubset(of: Set(entry.files)))
    }
}

@Test
func whisperCatalogEntryMatchesTheDefaultAppSetting() throws {
    // The catalog identifier is the string already stored in AppSettings, so an existing
    // installation resolves without a settings migration.
    let entry = try #require(MLingoModelCatalog.entry(for: ModelID(AppSettings().whisperModel)))
    #expect(entry.role == .speechRecognition)
    #expect(entry.repository == "mlx-community/whisper-base-asr-fp16")
}

@Test
func catalogLookupRejectsUnknownIdentifiers() {
    #expect(MLingoModelCatalog.entry(for: ModelID("mlx-community/not-real")) == nil)
    #expect(MLingoModelCatalog.entry(for: ModelID("")) == nil)
}

@Test
func catalogEntryValidationCatchesMalformedData() throws {
    let slug = try #require(ModelStorageSlug("broken"))
    let base = ModelCatalogEntry(
        id: ModelID("owner/broken"),
        slug: slug,
        role: .chat,
        repository: "owner/broken",
        revision: String(repeating: "a", count: 40),
        files: ["config.json", "tokenizer.json", "model.safetensors"],
        requiredFiles: ["config.json", "tokenizer.json"],
        expectedBytes: 10
    )
    #expect(base.validationIssues.isEmpty)

    var badRepository = base
    badRepository.repository = "no-slash"
    #expect(badRepository.validationIssues.contains(.malformedRepository))

    var traversalRepository = base
    traversalRepository.repository = "../etc/passwd"
    #expect(traversalRepository.validationIssues.contains(.malformedRepository))

    var badRevision = base
    badRevision.revision = "main"
    #expect(badRevision.validationIssues.contains(.unpinnedRevision))

    var wildcard = base
    wildcard.files = ["*.json"]
    #expect(wildcard.validationIssues.contains(.unsafeFileName("*.json")))

    var nested = base
    nested.files = base.files + ["onnx/config.json"]
    #expect(nested.validationIssues.contains(.unsafeFileName("onnx/config.json")))

    var missingRequired = base
    missingRequired.requiredFiles = ["absent.json"]
    #expect(missingRequired.validationIssues.contains(.requiredFileNotListed("absent.json")))

    var noWeights = base
    noWeights.files = ["config.json", "tokenizer.json"]
    #expect(noWeights.validationIssues.contains(.noWeightsListed))
}
