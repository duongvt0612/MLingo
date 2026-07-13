// swift-tools-version: 6.2

import PackageDescription

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
            ]
        ),
        .testTarget(
            name: "MLingoCoreTests",
            dependencies: ["MLingoCore"],
            path: "Tests/MLingoCoreTests"
        )
    ]
)
