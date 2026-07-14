import Foundation

enum MLXMetalLibraryAvailability {
    static func isAvailable() -> Bool {
        var searchRoots: [URL] = []

        if let executableURL = Bundle.main.executableURL {
            let executableDirectory = executableURL.deletingLastPathComponent()
            searchRoots.append(executableDirectory)
            searchRoots.append(executableDirectory.deletingLastPathComponent())
        }

        for bundle in [Bundle.main] + Bundle.allBundles + Bundle.allFrameworks {
            searchRoots.append(bundle.bundleURL)
            if let resourceURL = bundle.resourceURL {
                searchRoots.append(resourceURL)
            }
        }

        return isAvailable(
            executableURL: Bundle.main.executableURL,
            searchRoots: searchRoots
        )
    }

    static func isAvailable(
        executableURL: URL?,
        searchRoots: [URL],
        fileManager: FileManager = .default
    ) -> Bool {
        guard !isSwiftPMCommandLineExecutable(executableURL) else {
            return false
        }

        return isAvailable(searchRoots: searchRoots, fileManager: fileManager)
    }

    static func isAvailable(
        searchRoots: [URL],
        fileManager: FileManager = .default
    ) -> Bool {
        let relativePaths = [
            "mlx.metallib",
            "Resources/mlx.metallib",
            "default.metallib",
            "Resources/default.metallib",
            "mlx-swift_Cmlx.bundle/default.metallib",
            "mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib"
        ]

        return searchRoots.contains { root in
            relativePaths.contains { relativePath in
                fileManager.isReadableFile(
                    atPath: root.appending(path: relativePath).path
                )
            }
        }
    }

    private static func isSwiftPMCommandLineExecutable(_ executableURL: URL?) -> Bool {
        executableURL?.standardizedFileURL.pathComponents.contains(".build") == true
    }
}
