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
        .package(
            url: "https://github.com/ml-explore/mlx-swift-lm.git",
            exact: "3.31.4"
        ),
        .package(
            url: "https://github.com/huggingface/swift-huggingface.git",
            exact: "0.9.0"
        ),
        .package(
            url: "https://github.com/huggingface/swift-transformers.git",
            exact: "1.3.3"
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
                .product(name: "MLXAudioSTT", package: "mlx-audio-swift"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXEmbedders", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers"),
                // Keep swift-transformers on the source-compatible Jinja release.
                .product(name: "Jinja", package: "swift-jinja")
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
        ),
        .testTarget(
            name: "MLingoAppTests",
            dependencies: ["MLingoApp", "MLingoCore"],
            path: "Tests/MLingoAppTests"
        )
    ]
)
