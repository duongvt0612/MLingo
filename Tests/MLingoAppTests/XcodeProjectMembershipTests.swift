import Foundation
import Testing

@Test
func xcodeProjectCompilesEveryMLingoAppSwiftSource() throws {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let appSourceRoot = repositoryRoot.appending(path: "Sources/MLingoApp")
    let projectFile = repositoryRoot.appending(path: "MLingo.xcodeproj/project.pbxproj")
    let projectContents = try String(contentsOf: projectFile, encoding: .utf8)
    let sourceKeys: [URLResourceKey] = [.isRegularFileKey]
    let enumerator = try #require(
        FileManager.default.enumerator(
            at: appSourceRoot,
            includingPropertiesForKeys: sourceKeys
        )
    )
    let sourceURLs = enumerator.compactMap { $0 as? URL }
        .filter { url in
            url.pathExtension == "swift"
                && (try? url.resourceValues(forKeys: Set(sourceKeys)).isRegularFile) == true
        }
        .sorted { $0.path < $1.path }

    let missingFileReferences = sourceURLs.compactMap { url -> String? in
        let relativePath = url.path.replacingOccurrences(
            of: repositoryRoot.path + "/",
            with: ""
        )
        return projectContents.contains("path = \(relativePath);") ? nil : relativePath
    }
    let missingBuildPhaseEntries = sourceURLs.compactMap { url -> String? in
        let entry = "/* \(url.lastPathComponent) in Sources */"
        return projectContents.contains(entry) ? nil : url.lastPathComponent
    }

    #expect(
        missingFileReferences.isEmpty,
        "Missing Xcode file references: \(missingFileReferences.joined(separator: ", "))"
    )
    #expect(
        missingBuildPhaseEntries.isEmpty,
        "Missing Xcode Sources entries: \(missingBuildPhaseEntries.joined(separator: ", "))"
    )
}
