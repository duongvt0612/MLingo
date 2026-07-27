import Foundation

public enum ModelCatalogIssue: Equatable, Sendable {
    case malformedRepository
    case unpinnedRevision
    case unsafeFileName(String)
    case requiredFileNotListed(String)
    case noWeightsListed
    case emptyFileList
    case missingExpectedSize
}

/// One immutable catalog row: where a model comes from and what a complete download looks like.
///
/// `files` lists exact root-level names rather than extension globs. Upstream matches with
/// `fnmatch` and no `FNM_PATHNAME`, so `*` crosses `/` and `*.json` would also fetch nested
/// files such as `onnx/config.json` or a second copy of the weights.
public struct ModelCatalogEntry: Equatable, Sendable {
    public let id: ModelID
    public let slug: ModelStorageSlug
    public let role: ModelRole
    public var repository: String
    public var revision: String
    public var files: [String]
    public var requiredFiles: [String]
    /// Sum of the listed files at the pinned revision. Drives disk preflight and bounds
    /// verification, so it is a real figure rather than an estimate.
    public var expectedBytes: UInt64
    /// Optional per-file SHA-256. Left empty for v1: pinning a digest by hand is not
    /// meaningfully safer than pinning the commit it came from.
    public var expectedDigests: [String: String]

    public init(
        id: ModelID,
        slug: ModelStorageSlug,
        role: ModelRole,
        repository: String,
        revision: String,
        files: [String],
        requiredFiles: [String],
        expectedBytes: UInt64,
        expectedDigests: [String: String] = [:]
    ) {
        self.id = id
        self.slug = slug
        self.role = role
        self.repository = repository
        self.revision = revision
        self.files = files
        self.requiredFiles = requiredFiles
        self.expectedBytes = expectedBytes
        self.expectedDigests = expectedDigests
    }

    /// Checked by a test rather than at runtime: the catalog is compile-time data, and a
    /// malformed row is a bug to catch before shipping, not a condition to recover from.
    public var validationIssues: [ModelCatalogIssue] {
        var issues: [ModelCatalogIssue] = []
        if !Self.isWellFormedRepository(repository) {
            issues.append(.malformedRepository)
        }
        if revision.count != 40 || !revision.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) {
            issues.append(.unpinnedRevision)
        }
        if files.isEmpty {
            issues.append(.emptyFileList)
        }
        for file in files where !Self.isSafeFileName(file) {
            issues.append(.unsafeFileName(file))
        }
        let listed = Set(files)
        for required in requiredFiles where !listed.contains(required) {
            issues.append(.requiredFileNotListed(required))
        }
        if !files.contains(where: { $0.hasSuffix(".safetensors") }) {
            issues.append(.noWeightsListed)
        }
        if expectedBytes == 0 {
            issues.append(.missingExpectedSize)
        }
        return issues
    }

    /// `Repo.ID` splits on the first `/` without rejecting traversal, so the shape is checked here.
    private static func isWellFormedRepository(_ value: String) -> Bool {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty
                && part.count <= 96
                && part != "."
                && part != ".."
                && part.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-" }
        }
    }

    private static func isSafeFileName(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 128, value != ".", value != ".." else { return false }
        let forbidden: Set<Character> = ["/", "\\", "*", "?", "[", "]", "\u{0}"]
        return !value.contains(where: forbidden.contains)
    }
}

/// The bundled catalog. Adding a model is a data change: a new row here, no new code.
public enum MLingoModelCatalog {
    /// Speech recognition. The identifier is the string `AppSettings.whisperModel` already
    /// stores, so an existing installation resolves without a settings migration; the
    /// repository is the alias target `MLXAudioWhisperBackend` resolves it to.
    public static let whisperBase = ModelCatalogEntry(
        id: ModelID("mlx-community/whisper-base-mlx"),
        slug: ModelStorageSlug("whisper-base-mlx")!,
        role: .speechRecognition,
        repository: "mlx-community/whisper-base-asr-fp16",
        revision: "52f819c9c5fa6874a2f14a97112951fc951aa253",
        files: [
            "added_tokens.json",
            "config.json",
            "generation_config.json",
            "merges.txt",
            "model.safetensors",
            "model.safetensors.index.json",
            "normalizer.json",
            "preprocessor_config.json",
            "special_tokens_map.json",
            "tokenizer.json",
            "tokenizer_config.json",
            "vocab.json"
        ],
        requiredFiles: ["config.json", "tokenizer.json", "model.safetensors"],
        expectedBytes: 148_065_824
    )

    public static let qwen3Chat = ModelCatalogEntry(
        id: ModelID("mlx-community/Qwen3-0.6B-4bit"),
        slug: ModelStorageSlug("qwen3-0.6b-4bit")!,
        role: .chat,
        repository: "mlx-community/Qwen3-0.6B-4bit",
        revision: "73e3e38d981303bc594367cd910ea6eb48349da8",
        files: [
            "added_tokens.json",
            "config.json",
            "merges.txt",
            "model.safetensors",
            "model.safetensors.index.json",
            "special_tokens_map.json",
            "tokenizer.json",
            "tokenizer_config.json",
            "vocab.json"
        ],
        requiredFiles: ["config.json", "tokenizer.json", "model.safetensors"],
        expectedBytes: 351_383_618
    )

    /// Multilingual embeddings. `MLXEmbedders` registers the `xlm-roberta` architecture and
    /// lists this repository, so `EmbedderModelFactory` can load it as installed.
    public static let multilingualEmbedding = ModelCatalogEntry(
        id: ModelID("intfloat/multilingual-e5-small"),
        slug: ModelStorageSlug("multilingual-e5-small")!,
        role: .embedding,
        repository: "intfloat/multilingual-e5-small",
        revision: "614241f622f53c4eeff9890bdc4f31cfecc418b3",
        files: [
            "config.json",
            "model.safetensors",
            "sentencepiece.bpe.model",
            "special_tokens_map.json",
            "tokenizer.json",
            "tokenizer_config.json"
        ],
        requiredFiles: ["config.json", "tokenizer.json", "model.safetensors"],
        expectedBytes: 492_794_646
    )

    public static let v1: [ModelCatalogEntry] = [whisperBase, qwen3Chat, multilingualEmbedding]

    public static func entry(for id: ModelID) -> ModelCatalogEntry? {
        v1.first { $0.id == id }
    }

    public static func entries(for role: ModelRole) -> [ModelCatalogEntry] {
        v1.filter { $0.role == role }
    }
}
