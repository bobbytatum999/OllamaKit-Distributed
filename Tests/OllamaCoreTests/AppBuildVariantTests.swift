import XCTest
@testable import OllamaCore

final class AppBuildVariantTests: XCTestCase {
    func testResolveDefaultsToStockSideload() {
        let variant = AppBuildVariant.resolve(infoDictionary: nil, environment: [:])
        XCTAssertEqual(variant, .stockSideload)
    }

    func testResolveUsesInfoDictionaryValue() {
        let variant = AppBuildVariant.resolve(
            infoDictionary: [AppBuildVariant.infoDictionaryKey: "jailbreak"],
            environment: [:]
        )

        XCTAssertEqual(variant, .jailbreak)
        XCTAssertTrue(variant.allowsLiveBundleWorkspace)
    }

    func testResolveEnvironmentOverridesInfoDictionary() {
        let variant = AppBuildVariant.resolve(
            infoDictionary: [AppBuildVariant.infoDictionaryKey: "stockSideload"],
            environment: [AppBuildVariant.environmentKey: "jailbreak"]
        )

        XCTAssertEqual(variant, .jailbreak)
    }

    func testResolveIgnoresUnknownVariantValues() {
        let variant = AppBuildVariant.resolve(
            infoDictionary: [AppBuildVariant.infoDictionaryKey: "unsupported"],
            environment: [AppBuildVariant.environmentKey: "also-unsupported"]
        )

        XCTAssertEqual(variant, .stockSideload)
    }

    func testVariantMetadataMatchesExpectedBehavior() {
        XCTAssertEqual(AppBuildVariant.stockSideload.title, "Stock Sideload")
        XCTAssertFalse(AppBuildVariant.stockSideload.allowsLiveBundleWorkspace)
        XCTAssertEqual(AppBuildVariant.stockSideload.artifactSuffix, "stockSideload")

        XCTAssertEqual(AppBuildVariant.jailbreak.title, "Jailbreak")
        XCTAssertTrue(AppBuildVariant.jailbreak.allowsLiveBundleWorkspace)
        XCTAssertEqual(AppBuildVariant.jailbreak.artifactSuffix, "jailbreak")
    }
}
