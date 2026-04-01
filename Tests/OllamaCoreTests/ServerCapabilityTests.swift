import XCTest
@testable import OllamaCore

final class ServerCapabilityTests: XCTestCase {
    func testConservativeDefaultsAdvertiseTextRoutesForChatModels() {
        let summary = ModelCapabilitySummary(
            sizeBytes: 1_000,
            quantization: "Q4_K_M",
            parameterCountLabel: "7B",
            contextLength: 4096,
            supportsStreaming: true
        )

        let capabilities = ServerModelCapabilities.conservativeDefaults(
            backendKind: .ggufLlama,
            sourceModelID: "org/example-chat-model",
            displayName: "Example Chat",
            capabilitySummary: summary
        )

        XCTAssertTrue(capabilities.textGeneration)
        XCTAssertTrue(capabilities.chat)
        XCTAssertTrue(capabilities.streaming)
        XCTAssertTrue(capabilities.supportedRoutes.contains(.apiGenerate))
        XCTAssertTrue(capabilities.supportedRoutes.contains(.apiChat))
        XCTAssertTrue(capabilities.supportedRoutes.contains(.v1Responses))
        XCTAssertFalse(capabilities.embeddings)
        XCTAssertFalse(capabilities.toolCalling)
    }

    func testConservativeDefaultsDoNotAdvertiseChatForEmbeddingSignals() {
        let summary = ModelCapabilitySummary(
            sizeBytes: 1_000,
            quantization: "Q4_K_M",
            parameterCountLabel: "Unknown",
            contextLength: 4096,
            supportsStreaming: true,
            notes: "feature-extraction"
        )

        let capabilities = ServerModelCapabilities.conservativeDefaults(
            backendKind: .ggufLlama,
            sourceModelID: "org/embedding-model",
            displayName: "Embedding Model",
            capabilitySummary: summary
        )

        XCTAssertFalse(capabilities.textGeneration)
        XCTAssertFalse(capabilities.chat)
        XCTAssertTrue(capabilities.embeddings)
        XCTAssertTrue(capabilities.supportedRoutes.contains(.apiEmbed))
        XCTAssertTrue(capabilities.supportedRoutes.contains(.v1Embeddings))
        XCTAssertFalse(capabilities.supportedRoutes.contains(.apiGenerate))
        XCTAssertFalse(capabilities.supportedRoutes.contains(.v1ChatCompletions))
    }

    func testInferenceRequestTracksToolsReasoningAndMediaFlags() {
        let turn = ConversationTurn(
            role: "user",
            parts: [
                .text("Describe this image."),
                ConversationContentPart(kind: .imageURL, url: "https://example.com/image.png")
            ]
        )

        let request = InferenceRequest(
            catalogId: "example/catalog",
            prompt: "",
            systemPrompt: nil,
            conversationTurns: [turn],
            tools: [InferenceToolDefinition(name: "lookup_weather")],
            reasoning: InferenceReasoningOptions(effort: "medium"),
            parameters: .default,
            runtimePreferences: .validationBaseline()
        )

        XCTAssertTrue(request.isChatRequest)
        XCTAssertTrue(request.requestsToolCalling)
        XCTAssertTrue(request.requestsReasoningControls)
        XCTAssertTrue(request.hasNonTextInputs)
        XCTAssertTrue(request.hasImageInputs)
        XCTAssertFalse(request.hasAudioInputs)
        XCTAssertFalse(request.hasVideoInputs)
    }
}
