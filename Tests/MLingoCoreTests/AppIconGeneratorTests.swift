import Foundation
import Testing

@Test
func appIconGeneratorRejectsMissingAndEmptyOutputArguments() throws {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let scriptURL = repositoryRoot.appending(path: "scripts/generate-app-icon.swift")

    for arguments in [[], [""]] {
        let workingDirectory = FileManager.default.temporaryDirectory
            .appending(path: "MLingoAppIconGeneratorTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: workingDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: workingDirectory) }

        let process = Process()
        let standardError = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["swift", scriptURL.path] + arguments
        process.currentDirectoryURL = workingDirectory
        process.standardError = standardError
        process.standardOutput = Pipe()

        try process.run()
        process.waitUntilExit()

        let errorOutput = String(
            decoding: standardError.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        #expect(process.terminationStatus == 2)
        #expect(errorOutput == "Usage: generate-app-icon.swift <output-directory>\n")
    }
}
