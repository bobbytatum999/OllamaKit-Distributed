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
        let resolvedGpuLayers = await MainActor.run { gpuLayers ?? AppSettings.shared.gpuLayers }
        let resolvedKvCachePreset = await MainActor.run { AppSettings.shared.kvCachePreset.rawValue }
        await MainActor.run {
            AppLogStore.shared.record(
                .model,
                title: "Load Requested",
                message: "Loading model into runtime.",
                metadata: [
                    "catalog_id": catalogId,
                    "context_length": "\(max(contextLength, 512))",
                    "gpu_layers": "\(resolvedGpuLayers)",
                    "kv_cache_preset": resolvedKvCachePreset
                ]
            )
        }
        if let snapshot = await ModelStorage.shared.snapshot(name: catalogId) {
            let backendKind = await MainActor.run { snapshot.backendKind }
            let isValidatedRunnable = await MainActor.run { snapshot.isValidatedRunnable }
            if backendKind == .ggufLlama && !isValidatedRunnable {
                let refreshedSnapshot = await ModelStorage.shared.validateModel(catalogId: await MainActor.run { snapshot.catalogId }) ?? snapshot
                let refreshedIsValid = await MainActor.run { refreshedSnapshot.isValidatedRunnable }
                guard refreshedIsValid else {
                    let summary = await MainActor.run { refreshedSnapshot.validationSummary }
                    throw ModelError.backendUnavailable(
                        summary
                            ?? "This GGUF model failed validation on this device and cannot be loaded for chat."
                    )
                }
            }
        }

        let (settings_gpuLayers, settings_threads, settings_batchSize, settings_kvCachePreset,
             settings_flashAttention, settings_mmap, settings_mlock, settings_keepInMemory,
             settings_autoOffload) = await MainActor.run {
            let s = AppSettings.shared
            return (gpuLayers ?? s.gpuLayers, s.threads, s.batchSize, s.kvCachePreset,
                    s.flashAttentionEnabled, s.mmapEnabled, s.mlockEnabled,
                    s.keepModelInMemory, s.autoOffloadMinutes)
        }

        let runtime = RuntimePreferences(
            contextLength: max(contextLength, 512),
            gpuLayers: settings_gpuLayers,
            threads: settings_threads,
            batchSize: settings_batchSize,
            kvCachePreset: settings_kvCachePreset,
            flashAttentionEnabled: settings_flashAttention,
            mmapEnabled: settings_mmap,
            mlockEnabled: settings_mlock,
            keepModelInMemory: settings_keepInMemory,
            autoOffloadMinutes: settings_autoOffload
        )

        let entry = try await RuntimeCoordinator.shared.loadModel(
            catalogId: catalogId,
            runtime: runtime
        )
        await updateActiveState(from: entry)
        let resolvedPath = entry.localPath ?? ""
        await MainActor.run {
            AppLogStore.shared.record(
                .model,
                title: "Load Completed",
                message: "Model loaded successfully.",
                metadata: [
                    "catalog_id": catalogId,
                    "resolved_path": resolvedPath
                ]
            )
        }
    }

    func validateModel(catalogId: String) async -> ModelSnapshot? {
        await ModelStorage.shared.validateModel(catalogId: catalogId)
    }

    func unloadModel() {
        Task { @MainActor in
            AppLogStore.shared.record(
                .model,
                title: "Unload Requested",
                message: "Requested model unload."
            )
        }
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
        parameters: ModelParameters? = nil,
        onToken: @escaping (String) -> Void
    ) async throws -> GenerationResult {
        guard let activeCatalogId else {
            await MainActor.run {
                AppLogStore.shared.record(
                    .model,
                    level: .error,
                    title: "Generation Failed",
                    message: "No active model loaded."
                )
            }
            throw ModelError.noModelLoaded
        }

        let resolvedParameters = await MainActor.run { parameters ?? .appDefault }

        let (snapshotContextLength, runtime) = await MainActor.run {
            let snap = ModelStorage.shared.snapshot(name: activeCatalogId)
            let rt = RuntimePreferences.fromSettings(
                AppSettings.shared,
                contextLength: snap?.runtimeContextLength
            )
            return (snap?.runtimeContextLength, rt)
        }

        let result = try await RuntimeCoordinator.shared.generate(
            request: InferenceRequest(
                catalogId: activeCatalogId,
                prompt: prompt,
                systemPrompt: systemPrompt,
                conversationTurns: conversationTurns,
                tools: tools,
                reasoning: reasoning,
                parameters: resolvedParameters,
                runtimePreferences: runtime
            )
        ) { chunk in
            onToken(chunk.text)
        }

        let updatedEntry = try? await RuntimeCoordinator.shared.activeEntry(contextLength: runtime.contextLength)
        await updateActiveState(from: updatedEntry)
        await MainActor.run {
            AppLogStore.shared.record(
                .model,
                title: "Generation Result",
                message: "Inference completed.",
                metadata: [
                    "catalog_id": activeCatalogId,
                    "tokens": "\(result.tokensGenerated)",
                    "seconds": String(format: "%.2f", result.generationTime),
                    "cancelled": "\(result.wasCancelled)"
                ]
            )
        }
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
