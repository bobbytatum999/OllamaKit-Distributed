// swift-tools-version:5.9
import Foundation
import PackageDescription

let skipOllamaKitPackageTarget = ProcessInfo.processInfo.environment["SKIP_OLLAMAKIT_PACKAGE_TARGET"] == "1"

var products: [Product] = [
    .library(
        name: "OllamaCore",
        targets: ["OllamaCore"]
    )
]

if !skipOllamaKitPackageTarget {
    products.append(
        .library(
            name: "OllamaKit",
            targets: ["OllamaKit"]
        )
    )
}

var targets: [Target] = [
    .target(
        name: "OllamaCore",
        dependencies: [
            .product(name: "AnemllCore", package: "anemll-swift-cli")
        ],
        path: "Sources/OllamaCore"
    )
]

if !skipOllamaKitPackageTarget {
    targets.append(
        .target(
            name: "OllamaKit",
            dependencies: ["OllamaCore"],
            path: "Sources/OllamaKit",
            exclude: [],
            resources: [
                .process("Assets.xcassets")
            ]
        )
    )
}

targets.append(
    .testTarget(
        name: "OllamaCoreTests",
        dependencies: ["OllamaCore"],
        path: "Tests/OllamaCoreTests"
    )
)

let package = Package(
    name: "OllamaKit",
    platforms: [
        .iOS("26.0"),
        .macOS("15.0")
    ],
    products: products,
    dependencies: [
        .package(path: "Vendor/anemll-swift-cli")
    ],
    targets: targets
)
