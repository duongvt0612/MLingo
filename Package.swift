// swift-tools-version: 6.0

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
    targets: [
        .target(
            name: "MLingoCore",
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
