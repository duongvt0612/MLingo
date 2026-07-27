import Foundation
import Testing
@testable import MLingoCore

@Test
func modelStorageSlugRejectsTraversalAndSeparators() {
    let rejected = [
        "", ".", "..", "../escape", "a/b", "a\\b", "a\u{0}b", "/leading", "trailing/",
        "-leading-dash", ".leading-dot", "UPPERCASE", "has space", "emoji🙂",
        String(repeating: "a", count: 65)
    ]
    for candidate in rejected {
        #expect(ModelStorageSlug(candidate) == nil, "\(candidate.debugDescription) must be rejected")
    }

    let accepted = ["whisper-base-mlx", "qwen3-0.6b-4bit", "multilingual-e5-small", "a", "a.b_c-d"]
    for candidate in accepted {
        #expect(ModelStorageSlug(candidate)?.rawValue == candidate)
    }
}

@Test
func modelStorageLayoutKeepsEveryPathInsideRoot() throws {
    let temporary = try TemporaryDirectory(label: "Layout")
    defer { temporary.remove() }

    let layout = ModelStorageLayout(root: temporary.url)
    let slug = try #require(ModelStorageSlug("whisper-base-mlx"))
    let run = UUID()

    let paths = [
        layout.root,
        layout.installedRoot,
        layout.installed(slug),
        layout.stagingRoot,
        layout.staging(slug, run: run),
        layout.quarantineRoot,
        layout.quarantine(slug, run: run),
        layout.hubCacheRoot,
        layout.receiptFile
    ]

    let rootPath = temporary.url.standardizedFileURL.resolvingSymlinksInPath().path
    for path in paths {
        let resolved = path.standardizedFileURL.resolvingSymlinksInPath().path
        #expect(
            resolved == rootPath || resolved.hasPrefix(rootPath + "/"),
            "\(path.lastPathComponent) escaped the store root"
        )
    }
}

@Test
func modelStorageLayoutSeparatesBucketsAndTagsRunsUniquely() throws {
    let temporary = try TemporaryDirectory(label: "Layout")
    defer { temporary.remove() }

    let layout = ModelStorageLayout(root: temporary.url)
    let slug = try #require(ModelStorageSlug("qwen3-0.6b-4bit"))
    let firstRun = UUID()
    let secondRun = UUID()

    #expect(layout.installed(slug).lastPathComponent == "qwen3-0.6b-4bit")
    #expect(layout.staging(slug, run: firstRun) != layout.staging(slug, run: secondRun))
    #expect(layout.staging(slug, run: firstRun) != layout.quarantine(slug, run: firstRun))
    #expect(layout.installed(slug).deletingLastPathComponent() == layout.installedRoot)
    #expect(layout.receiptFile.lastPathComponent == "installed.json")
}

@Test
func modelStorageLayoutCreatesItsBucketsOnDemand() throws {
    let temporary = try TemporaryDirectory(label: "Layout")
    defer { temporary.remove() }

    let layout = ModelStorageLayout(root: temporary.appending("Models", isDirectory: true))
    try layout.createBuckets()

    for directory in [layout.installedRoot, layout.stagingRoot, layout.quarantineRoot, layout.hubCacheRoot] {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory)
        #expect(exists && isDirectory.boolValue, "\(directory.lastPathComponent) was not created")
    }

    // Idempotent: reconcile runs this on every launch.
    try layout.createBuckets()
}

@Test
func modelStorageLayoutDefaultRootLivesUnderApplicationSupport() throws {
    let root = try ModelStorageLayout.defaultRoot()
    #expect(root.path.hasSuffix("/Application Support/MLingo/Models"))
}
