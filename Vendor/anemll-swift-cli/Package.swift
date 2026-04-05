// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "anemll-swift-cli",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(
            name: "AnemllCoreLib",
            targets: ["AnemllCore"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/huggingface/swift-transformers", revision: "abf5b1642bb8d095d6e048e6ccd87a95f0f5217a"),
        .package(url: "https://github.com/jpsim/Yams.git", exact: "5.2.0"),
    ],
    targets: [
        .target(
            name: "AnemllCore",
            dependencies: [
                "Yams",
                .product(name: "Transformers", package: "swift-transformers"),
            ],
            path: "Sources/AnemllCore"
        ),
    ]
)
