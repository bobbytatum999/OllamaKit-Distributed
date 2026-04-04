import Combine
import Foundation
import OllamaCore

final class ModelRunner: ObservableObject {
    static let shared = ModelRunner()

    @Published private(set) var activeLoadedModelPath: String?
    @Published private(set) var activeCatalogId: String?

    var isLoaded: Bool {
        activeCatalogId != nil
    }

    var loadedModelPath: String? {
        activeLoadedModelPath
    }

    private init() {}

    func loadModel(from path: String, contextLength: Int = 4096, gpuLayers: Int = 0) async throws {
        let snapshot = await MainActor.run {
            ModelStorage.shared.allSnapshots().first { $0.localPath == path }
        }

        guard let snapshot else {
            throw ModelError.modelNotFound("Model file not found at the stored path. Please re-download the model.")
        }

        try await loadModel(
            catalogId: snapshot.catalogId,
            contextLength: contextLength,
            gpuLayers: gpuLayers
        )
    }

    func loadModel(catalogId: String, contextLength: Int = 4096, gpuLayers: Int? = nil) async throws {
        if let snapshot = await ModelStorage.shared.snapshot(name: catalogId),
           snapshot.backendKind == .ggufLlama,
           !snapshot.isValidatedRunnable
        {
            let refreshedSnapshot = await ModelStorage.shared.validateModel(catalogId: snapshot.catalogId) ?? snapshot
            guard refreshedSnapshot.isValidatedRunnable else {
                throw ModelError.backendUnavailable(
                    refreshedSnapshot.validationSummary
                        ?? "This GGUF model failed validation on this device and cannot be loaded for chat."
                )
            }
        }

        let settings = AppSettings.shared
        let runtime = RuntimePreferences(
            contextLength: max(contextLength, 512),
            gpuLayers: gpuLayers ?? settings.gpuLayers,
            threads: settings.threads,
            batchSize: settings.batchSize,
            flashAttentionEnabled: settings.flashAttentionEnabled,
            mmapEnabled: settings.mmapEnabled,
            mlockEnabled: settings.mlockEnabled,
            keepModelInMemory: settings.keepModelInMemory,
            autoOffloadMinutes: settings.autoOffloadMinutes
        )

        let entry = try await RuntimeCoordinator.shared.loadModel(
            catalogId: catalogId,
            runtime: runtime
        )
        await updateActiveState(from: entry)
    }

    func validateModel(catalogId: String) async -> ModelSnapshot? {
        await ModelStorage.shared.validateModel(catalogId: catalogId)
    }

    func unloadModel() {
        Task {
            await RuntimeCoordinator.shared.unloadModel()
            await updateActiveState(from: nil)
        }
    }

    func generate(
        prompt: String,
        systemPrompt: String? = nil,
        conversationTurns: [ConversationTurn] = [],
        tools: [InferenceToolDefinition] = [],
        reasoning: InferenceReasoningOptions? = nil,
        parameters: ModelParameters = .appDefault,
        onToken: @escaping (String) -> Void
    ) async throws -> GenerationResult {
        guard let activeCatalogId else {
            throw ModelError.noModelLoaded
        }

        let currentSnapshot = await MainActor.run {
            ModelStorage.shared.snapshot(name: activeCatalogId)
        }
        let runtime = RuntimePreferences.fromSettings(
            AppSettings.shared,
            contextLength: currentSnapshot?.runtimeContextLength
        )

        let result = try await RuntimeCoordinator.shared.generate(
            request: InferenceRequest(
                catalogId: activeCatalogId,
                prompt: prompt,
                systemPrompt: systemPrompt,
                conversationTurns: conversationTurns,
                tools: tools,
                reasoning: reasoning,
                parameters: parameters,
                runtimePreferences: runtime
            )
        ) { chunk in
            onToken(chunk.text)
        }

        let updatedEntry = try? await RuntimeCoordinator.shared.activeEntry(contextLength: runtime.contextLength)
        await updateActiveState(from: updatedEntry)
        return result
    }

    func stopGeneration() {
        Task {
            await RuntimeCoordinator.shared.stopGeneration()
        }
    }

    private func updateActiveState(from entry: ModelCatalogEntry?) async {
        let catalogId = entry?.catalogId
        let localPath = entry?.localPath

        await MainActor.run {
            self.activeCatalogId = catalogId
            self.activeLoadedModelPath = localPath
        }
    }
}
