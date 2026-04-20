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
        let (settings_gpuLayers, settings_threads, settings_batchSize, settings_kvCachePreset,
             settings_flashAttention, settings_mmap, settings_mlock, settings_keepInMemory,
             settings_autoOffload, settings_turboQuant, settings_kvCacheTypeK, settings_kvCacheTypeV) = await MainActor.run {
            let s = AppSettings.shared
            return (gpuLayers ?? s.gpuLayers, s.threads, s.batchSize, s.kvCachePreset,
                    s.flashAttentionEnabled, s.mmapEnabled, s.mlockEnabled,
                    s.keepModelInMemory, s.autoOffloadMinutes, s.turboQuantMode,
                    s.kvCacheTypeK, s.kvCacheTypeV)
        }

        let runtime = RuntimePreferences(
            contextLength: max(contextLength, 512),
            gpuLayers: settings_gpuLayers,
            threads: settings_threads,
            batchSize: settings_batchSize,
            flashAttentionEnabled: settings_flashAttention,
            mmapEnabled: settings_mmap,
            mlockEnabled: settings_mlock,
            turboQuantMode: settings_turboQuant,
            kvCacheTypeK: settings_kvCacheTypeK,
            kvCacheTypeV: settings_kvCacheTypeV,
            keepModelInMemory: settings_keepInMemory,
            autoOffloadMinutes: settings_autoOffload
        )

        do {
            let entry = try await RuntimeCoordinator.shared.loadModel(
                catalogId: catalogId,
                runtime: runtime
            )
            if entry.backendKind == .ggufLlama {
                _ = try? await ModelRegistryStore.shared.updateValidation(
                    catalogId: entry.catalogId,
                    outcome: ModelValidationOutcome(
                        status: .validated,
                        message: "Loaded successfully on this device with the current runtime settings."
                    )
                )
                await ModelStorage.shared.refresh()
            }
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
            min(snapshotContextLength ?? preferredContextLength, preferredContextLength),
            512
        )
        let generationRuntime = await MainActor.run {
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
                    parameters: resolvedParameters,
                    runtimePreferences: generationRuntime
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

        let updatedEntry = try? await RuntimeCoordinator.shared.activeEntry(contextLength: generationRuntime.contextLength)
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
