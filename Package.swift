// swift-tools-version: 6.3

import PackageDescription
import Foundation

let appInfoPlist = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appending(path: "Sources/MLingoApp/Resources/Info.plist")
    .path

let package = Package(
    name: "MLingo",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "MLingo", targets: ["MLingoApp"]),
        .library(name: "MLingoCore", targets: ["MLingoCore"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/Blaizzy/mlx-audio-swift.git",
            exact: "0.1.3"
        ),
        // swift-transformers 1.x is not source-compatible with swift-jinja 2.4.
        .package(
            url: "https://github.com/huggingface/swift-jinja.git",
            exact: "2.3.6"
        )
    ],
    targets: [
        .target(
            name: "MLingoCore",
            dependencies: [
                .product(name: "MLXAudioCore", package: "mlx-audio-swift"),
                .product(name: "MLXAudioSTT", package: "mlx-audio-swift")
            ],
            path: "Sources/MLingoCore"
        ),
        .executableTarget(
            name: "MLingoApp",
            dependencies: ["MLingoCore"],
            path: "Sources/MLingoApp",
            resources: [
                .copy("Resources")
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", appInfoPlist,
                ])
            ]
        ),
        .testTarget(
            name: "MLingoCoreTests",
            dependencies: ["MLingoCore"],
            path: "Tests/MLingoCoreTests",
            resources: [
                .copy("Fixtures")
            ]
        )
    ]
)
