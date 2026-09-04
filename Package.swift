// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "Gitacre",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "GitacreCore", targets: ["GitacreCore"]),
        .executable(name: "Gitacre", targets: ["Gitacre"])
    ],
    targets: [
        .target(
            name: "GitacreCore",
            path: "Sources/GitacreCore"
        ),
        .executableTarget(
            name: "Gitacre",
            dependencies: ["GitacreCore"],
            path: "Sources/Gitacre"
        ),
        .testTarget(
            name: "GitacreCoreTests",
            dependencies: ["GitacreCore"],
            path: "Tests/GitacreCoreTests"
        )
    ],
    swiftLanguageModes: [.v5]
)
