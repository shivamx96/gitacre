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
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        .target(
            name: "GitacreCore",
            path: "Sources/GitacreCore"
        ),
        .executableTarget(
            name: "Gitacre",
            dependencies: [
                "GitacreCore",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/Gitacre"
        ),
        .testTarget(
            name: "GitacreCoreTests",
            dependencies: ["GitacreCore"],
            path: "Tests/GitacreCoreTests"
        ),
        .testTarget(
            name: "GitacreTests",
            dependencies: ["Gitacre"],
            path: "Tests/GitacreTests"
        )
    ],
    swiftLanguageModes: [.v5]
)
