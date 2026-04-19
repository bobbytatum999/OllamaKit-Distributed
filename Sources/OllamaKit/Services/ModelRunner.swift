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
        let loadStart = CFAbsoluteTimeGetCurrent()
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
            gpuLayers: gpuLayers ?? settings.gpuLayers,
            threads: settings.threads,
            batchSize: settings.batchSize,
            flashAttentionEnabled: settings.flashAttentionEnabled,
            mmapEnabled: settings.mmapEnabled,
            mlockEnabled: settings.mlockEnabled,
            turboQuantMode: settings.turboQuantMode,
            kvCacheTypeK: settings.kvCacheTypeK,
            kvCacheTypeV: settings.kvCacheTypeV,
            keepModelInMemory: settings.keepModelInMemory,
            autoOffloadMinutes: settings.autoOffloadMinutes
        )

        do {
            let entry = try await RuntimeCoordinator.shared.loadModel(
                catalogId: catalogId,
                runtime: runtime
            )
            await updateActiveState(from: entry)

            let elapsedMs = (CFAbsoluteTimeGetCurrent() - loadStart) * 1000
            await MainActor.run {
                ModelPerformanceStore.shared.record(
                    ModelPerformanceSample(
                        modelID: catalogId,
                        phase: .load,
                        elapsedMs: elapsedMs,
                        wasSuccessful: true
                    )
                )
            }
        } catch {
            let elapsedMs = (CFAbsoluteTimeGetCurrent() - loadStart) * 1000
            await MainActor.run {
                ModelPerformanceStore.shared.record(
                    ModelPerformanceSample(
                        modelID: catalogId,
                        phase: .load,
                        elapsedMs: elapsedMs,
                        wasSuccessful: false,
                        notes: error.localizedDescription
                    )
                )
            }
            throw error
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
        let generationStart = CFAbsoluteTimeGetCurrent()

        let resolvedParameters = await MainActor.run { parameters ?? .appDefault }

        let (snapshotContextLength, runtime, preferredContextLength) = await MainActor.run {
            let snap = ModelStorage.shared.snapshot(name: activeCatalogId)
            let rt = RuntimePreferences.fromSettings(
                AppSettings.shared,
                contextLength: snap?.runtimeContextLength
            )
            let ctxLen = max(AppSettings.shared.defaultContextLength, 512)
            return (snap?.runtimeContextLength, rt, ctxLen)
        }
        let effectiveContextLength = max(
            min(currentSnapshot?.runtimeContextLength ?? preferredContextLength, preferredContextLength),
            512
        )
        let runtime = await MainActor.run {
            RuntimePreferences.fromSettings(
                AppSettings.shared,
                contextLength: effectiveContextLength
            )
        }

        let result: InferenceResult
        do {
            result = try await RuntimeCoordinator.shared.generate(
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
        } catch {
            let elapsedMs = (CFAbsoluteTimeGetCurrent() - generationStart) * 1000
            await MainActor.run {
                ModelPerformanceStore.shared.record(
                    ModelPerformanceSample(
                        modelID: activeCatalogId,
                        phase: .generate,
                        elapsedMs: elapsedMs,
                        wasSuccessful: false,
                        notes: error.localizedDescription
                    )
                )
            }
            throw error
        }

        let updatedEntry = try? await RuntimeCoordinator.shared.activeEntry(contextLength: runtime.contextLength)
        await updateActiveState(from: updatedEntry)

        await MainActor.run {
            ModelPerformanceStore.shared.record(
                ModelPerformanceSample(
                    modelID: activeCatalogId,
                    phase: .generate,
                    elapsedMs: result.generationTime * 1000,
                    tokens: result.tokensGenerated,
                    tokensPerSecond: result.generationTime > 0 ? Double(result.tokensGenerated) / result.generationTime : 0,
                    wasSuccessful: !result.wasCancelled,
                    notes: result.wasCancelled ? "cancelled" : nil
                ))
        }
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
