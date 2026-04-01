import XCTest
@testable import OllamaCore

final class AgentCapabilityTests: XCTestCase {
    func testEmbeddingSignalsDenyAgentToolingByDefault() {
        let profile = ModelAgentCapabilityProfile.conservativeDefaults(
            backendKind: .ggufLlama,
            sourceModelID: "org/embedding-model",
            displayName: "Embedding Model",
            capabilitySummary: ModelCapabilitySummary(
                sizeBytes: 1_000,
                quantization: "Q4_K_M",
                parameterCountLabel: "Unknown",
                contextLength: 4096,
                supportsStreaming: true,
                notes: "feature-extraction"
            ),
            serverCapabilities: ServerModelCapabilities(
                textGeneration: false,
                chat: false,
                streaming: false,
                embeddings: true
            )
        )

        XCTAssertFalse(profile.browserRead)
        XCTAssertFalse(profile.workspaceRead)
        XCTAssertFalse(profile.codeTools)
        XCTAssertFalse(profile.githubAccess)
        XCTAssertFalse(profile.remoteCI)
    }

    func testCoderSignalsEnableCodingAndResearchTooling() {
        let profile = ModelAgentCapabilityProfile.conservativeDefaults(
            backendKind: .ggufLlama,
            sourceModelID: "org/devstral-small-coder",
            displayName: "Devstral Coder",
            capabilitySummary: ModelCapabilitySummary(
                sizeBytes: 1_000,
                quantization: "Q4_K_M",
                parameterCountLabel: "7B",
                contextLength: 8192,
                supportsStreaming: true,
                notes: "chat coder agent"
            ),
            serverCapabilities: ServerModelCapabilities(
                textGeneration: true,
                chat: true,
                streaming: true,
                embeddings: false,
                toolCalling: true
            )
        )

        XCTAssertTrue(profile.browserRead)
        XCTAssertTrue(profile.browserActions)
        XCTAssertTrue(profile.workspaceRead)
        XCTAssertTrue(profile.workspaceWrite)
        XCTAssertTrue(profile.codeTools)
        XCTAssertTrue(profile.jsRuntime)
        XCTAssertTrue(profile.pythonRuntime)
        XCTAssertTrue(profile.swiftRuntime)
        XCTAssertTrue(profile.gitRead)
        XCTAssertTrue(profile.gitWrite)
        XCTAssertTrue(profile.githubAccess)
        XCTAssertTrue(profile.remoteCI)
        XCTAssertTrue(profile.managedRelayAccess)
        XCTAssertFalse(profile.bundleEdits)
    }

    func testOverrideAppliesPerCapability() {
        let base = ModelAgentCapabilityProfile(
            browserRead: true,
            browserActions: false,
            internetRead: true,
            internetWrite: false,
            workspaceRead: true,
            workspaceWrite: true,
            codeTools: true,
            jsRuntime: true,
            pythonRuntime: true,
            nodeRuntime: false,
            swiftRuntime: false,
            gitRead: true,
            gitWrite: false,
            githubAccess: true,
            remoteCI: false,
            managedRelayAccess: false,
            bundleEdits: false
        )

        let override = ModelAgentCapabilityOverride(
            browserActions: true,
            internetWrite: true,
            swiftRuntime: true,
            gitWrite: true,
            remoteCI: true,
            managedRelayAccess: true,
            bundleEdits: false
        )

        let effective = base.applying(override)

        XCTAssertTrue(effective.browserRead)
        XCTAssertTrue(effective.browserActions)
        XCTAssertTrue(effective.internetWrite)
        XCTAssertTrue(effective.gitWrite)
        XCTAssertTrue(effective.remoteCI)
        XCTAssertTrue(effective.swiftRuntime)
        XCTAssertTrue(effective.managedRelayAccess)
        XCTAssertFalse(effective.bundleEdits)
    }
}
