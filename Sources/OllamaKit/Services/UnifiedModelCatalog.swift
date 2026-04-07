import Combine
import Foundation
import OllamaCore
import SwiftData

typealias GenerationResult = InferenceResult
typealias ModelError = InferenceError
typealias ModelParameters = SamplingParameters

extension SamplingParameters {
    static var appDefault: SamplingParameters {
        let settings = AppSettings.shared
        return SamplingParameters(
            temperature: settings.defaultTemperature,
            topP: settings.defaultTopP,
            topK: settings.defaultTopK,
            repeatPenalty: settings.defaultRepeatPenalty,
            repeatLastN: settings.defaultRepeatLastN,
            maxTokens: settings.maxTokens
        )
    }
}

struct ModelSnapshot: Identifiable, Hashable, Sendable {
    let catalogId: String
    let sourceModelID: String
    let name: String
    let serverIdentifier: String
    let backendKind: ModelBackendKind
    let localPath: String
    let packageRootPath: String
    let manifestPath: String
    let size: Int64
    let downloadDate: Date
    let quantization: String
    let parameters: String
    let contextLength: Int
    let importSource: ModelImportSource
    let isServerExposed: Bool
    let validationStatus: ModelValidationStatus?
    let validationMessage: String?
    let validatedAt: Date?
    let aliases: [String]
    let serverCapabilities: ServerModelCapabilities?

    init(entry: ModelCatalogEntry) {
        self.catalogId = entry.catalogId
        self.sourceModelID = entry.sourceModelID
        self.name = entry.displayName
        self.serverIdentifier = entry.serverIdentifier
        self.backendKind = entry.backendKind
        self.localPath = entry.localPath ?? ""
        self.packageRootPath = entry.packageRootPath ?? ""
        self.manifestPath = entry.manifestPath ?? ""
        self.size = entry.capabilitySummary.sizeBytes
        self.downloadDate = entry.updatedAt
        self.quantization = entry.capabilitySummary.quantization
        self.parameters = entry.capabilitySummary.parameterCountLabel
        self.contextLength = entry.capabilitySummary.contextLength
        self.importSource = entry.importSource
        self.isServerExposed = entry.isServerExposed
        self.validationStatus = entry.validationStatus
        self.validationMessage = entry.validationMessage
        self.validatedAt = entry.validatedAt
        self.aliases = entry.aliases
        self.serverCapabilities = entry.serverCapabilities
    }

    var id: String { catalogId }

    var modelId: String { sourceModelID }

    var displayName: String {
        name.nonEmpty ?? sourceModelID
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    var fileExists: Bool {
        if isBuiltInAppleModel {
            return true
        }

        if !localPath.isEmpty {
            return FileManager.default.fileExists(atPath: localPath)
        }

        if !packageRootPath.isEmpty {
            return FileManager.default.fileExists(atPath: packageRootPath)
        }

        return false
    }

    var runtimeContextLength: Int {
        max(contextLength, 512)
    }

    var persistentReference: String {
        catalogId
    }

    var apiIdentifier: String {
        serverIdentifier
    }

    var isBuiltInAppleModel: Bool {
        backendKind == .appleFoundation
    }

    var hasRunnableCoreMLPayload: Bool {
        backendKind == .coreMLPackage && CoreMLPackageLocator.looksRunnable(packageRootPath: packageRootPath)
    }

    var effectiveValidationStatus: ModelValidationStatus {
        if let validationStatus {
            return validationStatus
        }

        switch backendKind {
        case .ggufLlama:
            return .unknown
        case .appleFoundation, .coreMLPackage:
            return .validated
        }
    }

    var isValidatedRunnable: Bool {
        switch backendKind {
        case .ggufLlama:
            return fileExists && effectiveValidationStatus.isRunnable
        case .coreMLPackage:
            return hasRunnableCoreMLPayload
        case .appleFoundation:
            return effectiveValidationStatus.isRunnable
        }
    }

    var needsValidation: Bool {
        backendKind == .ggufLlama && effectiveValidationStatus != .validated
    }

    var isServerRunnable: Bool {
        isServerExposed && isValidatedRunnable
    }

    var canBeSelectedForChat: Bool {
        switch backendKind {
        case .ggufLlama:
            return fileExists && isValidatedRunnable
        case .appleFoundation:
            return true
        case .coreMLPackage:
            return hasRunnableCoreMLPayload
        }
    }

    var validationSummary: String? {
        validationMessage?.nonEmpty
    }

    var effectiveServerCapabilities: ServerModelCapabilities {
        serverCapabilities
            ?? ServerModelCapabilities.conservativeDefaults(
                backendKind: backendKind,
                sourceModelID: sourceModelID,
                displayName: displayName,
                capabilitySummary: ModelCapabilitySummary(
                    sizeBytes: size,
                    quantization: quantization,
                    parameterCountLabel: parameters,
                    contextLength: contextLength,
                    supportsStreaming: backendKind != .appleFoundation,
                    notes: validationMessage
                )
            )
    }

    var conservativeAgentCapabilities: ModelAgentCapabilityProfile {
        ModelAgentCapabilityProfile.conservativeDefaults(
            backendKind: backendKind,
            sourceModelID: sourceModelID,
            displayName: displayName,
            capabilitySummary: ModelCapabilitySummary(
                sizeBytes: size,
                quantization: quantization,
                parameterCountLabel: parameters,
                contextLength: contextLength,
                supportsStreaming: backendKind != .appleFoundation,
                notes: validationMessage
            ),
            serverCapabilities: effectiveServerCapabilities
        )
    }

    var configuredAgentCapabilityOverride: ModelAgentCapabilityOverride? {
        AppSettings.shared.agentCapabilityOverride(for: catalogId)
    }

    var hasAgentCapabilityOverride: Bool {
        configuredAgentCapabilityOverride?.isEmpty == false
    }

    var effectiveAgentCapabilities: ModelAgentCapabilityProfile {
        conservativeAgentCapabilities.applying(configuredAgentCapabilityOverride)
    }

    func matchesStoredReference(_ candidate: String) -> Bool {
        matchPriority(forStoredReference: candidate) != nil
    }

    func matchPriority(forStoredReference candidate: String) -> Int? {
        let normalizedCandidate = candidate.trimmedForLookup.lowercased()
        guard !normalizedCandidate.isEmpty else { return nil }

        if catalogId.trimmedForLookup.lowercased() == normalizedCandidate {
            return 0
        }

        if apiIdentifier.trimmedForLookup.lowercased() == normalizedCandidate {
            return 1
        }

        if modelId.trimmedForLookup.lowercased() == normalizedCandidate {
            return 2
        }

        if localPath.trimmedForLookup.lowercased() == normalizedCandidate {
            return 3
        }

        if displayName.trimmedForLookup.lowercased() == normalizedCandidate {
            return 4
        }

        if aliases.contains(where: { $0.trimmedForLookup.lowercased() == normalizedCandidate }) {
            return 5
        }

        return nil
    }

    static func resolveStoredReference(_ candidate: String, in models: [ModelSnapshot]) -> ModelSnapshot? {
        let normalizedCandidate = candidate.trimmedForLookup
        guard !normalizedCandidate.isEmpty else { return nil }

        return models
            .compactMap { model in
                model.matchPriority(forStoredReference: normalizedCandidate).map { ($0, model) }
            }
            .sorted { lhs, rhs in
                if lhs.0 != rhs.0 {
                    return lhs.0 < rhs.0
                }

                if lhs.1.downloadDate != rhs.1.downloadDate {
                    return lhs.1.downloadDate > rhs.1.downloadDate
                }

                return lhs.1.catalogId.localizedCaseInsensitiveCompare(rhs.1.catalogId) == .orderedAscending
            }
            .first?
            .1
    }
}

extension RuntimePreferences {
    static func fromSettings(_ settings: AppSettings = .shared, contextLength: Int? = nil) -> RuntimePreferences {
        RuntimePreferences(
            contextLength: max(contextLength ?? settings.defaultContextLength, 512),
            gpuLayers: settings.gpuLayers,
            threads: settings.threads,
            batchSize: settings.batchSize,
            kvCachePreset: settings.kvCachePreset,
            flashAttentionEnabled: settings.flashAttentionEnabled,
            mmapEnabled: settings.mmapEnabled,
            mlockEnabled: settings.mlockEnabled,
            keepModelInMemory: settings.keepModelInMemory,
            autoOffloadMinutes: settings.autoOffloadMinutes
        )
    }
}

@MainActor
final class ModelStorage: ObservableObject {
    static let shared = ModelStorage()
    private static let migrationDefaultsKey = "ollamaCoreRegistryMigrationV1"

    @Published private(set) var snapshots: [ModelSnapshot] = []

    private var container: ModelContainer?
    private var isBootstrapping = false

    private init() {}

    func configure(container: ModelContainer) {
        self.container = container

        if !isBootstrapping {
            isBootstrapping = true
            Task {
                await self.bootstrap()
            }
        }
    }

    var installedSnapshots: [ModelSnapshot] {
        snapshots.filter { !$0.isBuiltInAppleModel }
    }

    var selectionSnapshots: [ModelSnapshot] {
        snapshots
    }

    func allSnapshots() -> [ModelSnapshot] {
        snapshots
    }

    func snapshot(name: String) -> ModelSnapshot? {
        ModelSnapshot.resolveStoredReference(name, in: snapshots)
    }

    func bootstrap() async {
        await migrateLegacyModelsIfNeeded()
        await refresh()
        await validatePendingGGUFModels()
    }

    func refresh() async {
        await MainActor.run {
            AppLogStore.shared.record(
                .modelsCatalog,
                level: .info,
                title: "Catalog Refresh Started",
                message: "Refreshing model catalog"
            )
        }

        do {
            let entries = try await RuntimeCoordinator.shared.availableEntries(contextLength: AppSettings.shared.defaultContextLength)
            let installedModels = entries.filter { !$0.isBuiltInAppleModel }
            let totalSize = installedModels.reduce(0) { $0 + $1.capabilitySummary.sizeBytes }
            snapshots = entries.map(ModelSnapshot.init(entry:))

            await MainActor.run {
                AppLogStore.shared.record(
                    .modelsCatalog,
                    level: .info,
                    title: "Catalog Refresh Completed",
                    message: "Found \(installedModels.count) models",
                    metadata: ["total_models": "\(installedModels.count)", "total_size": "\(totalSize)"]
                )
            }
        } catch {
            await MainActor.run {
                AppLogStore.shared.record(
                    .modelsCatalog,
                    level: .error,
                    title: "Failed to refresh model registry",
                    message: "Error: \(error.localizedDescription)",
                    metadata: ["error": error.localizedDescription]
                )
            }
        }
    }

    func upsertDownloadedModel(_ seed: DownloadedModelSeed) async {
        do {
            let entry = try await ModelRegistryStore.shared.registerDownloadedGGUF(
                sourceModelID: seed.modelId,
                displayName: seed.name,
                localPath: seed.localPath,
                size: seed.size,
                quantization: seed.quantization,
                parameterCountLabel: seed.parameters,
                contextLength: seed.contextLength,
                serverCapabilities: seed.serverCapabilities
            )
            _ = await validateModel(catalogId: entry.catalogId)
            await refresh()

            await MainActor.run {
                AppLogStore.shared.record(
                    .modelsCatalog,
                    level: .info,
                    title: "Model Added to Catalog",
                    message: "Added: \(seed.name)",
                    metadata: [
                        "catalog_id": entry.catalogId,
                        "source": "download",
                        "quantization": seed.quantization,
                        "size_bytes": "\(seed.size)"
                    ]
                )
            }
        } catch {
            await MainActor.run {
                AppLogStore.shared.record(
                    .modelsCatalog,
                    level: .error,
                    title: "Failed to upsert downloaded model into registry",
                    message: "Error: \(error.localizedDescription)",
                    metadata: ["error": error.localizedDescription]
                )
            }
        }
    }

    func importGGUFModel(from sourceURL: URL) async throws -> ModelSnapshot {
        let entry = try await ModelRegistryStore.shared.importGGUFFile(
            from: sourceURL,
            defaultContextLength: AppSettings.shared.defaultContextLength
        )
        _ = await validateModel(catalogId: entry.catalogId)
        await refresh()
        return snapshot(name: entry.catalogId) ?? ModelSnapshot(entry: entry)
    }

    func importCoreMLPackage(from sourceURL: URL) async throws -> ModelSnapshot {
        let entry = try await ModelRegistryStore.shared.importCoreMLPackage(
            from: sourceURL,
            defaultContextLength: AppSettings.shared.defaultContextLength
        )
        await refresh()
        return ModelSnapshot(entry: entry)
    }

    func deleteModel(name: String) async -> Bool {
        guard let snapshot = snapshot(name: name) else { return false }
        return await deleteModel(catalogId: snapshot.catalogId)
    }

    func deleteModel(catalogId: String) async -> Bool {
        do {
            let deletedSnapshot = snapshot(name: catalogId)
            _ = try await ModelRegistryStore.shared.deleteModel(catalogId: catalogId)
            if ModelRunner.shared.activeCatalogId == catalogId {
                ModelRunner.shared.unloadModel()
            }
            if let deletedSnapshot,
               deletedSnapshot.matchesStoredReference(AppSettings.shared.defaultModelId) {
                AppSettings.shared.defaultModelId = ""
            }
            await refresh()

            await MainActor.run {
                AppLogStore.shared.record(
                    .modelsCatalog,
                    level: .warning,
                    title: "Model Removed from Catalog",
                    message: "Removed model: \(catalogId)",
                    metadata: ["catalog_id": catalogId]
                )
            }
            return true
        } catch {
            await MainActor.run {
                AppLogStore.shared.record(
                    .modelsCatalog,
                    level: .error,
                    title: "Failed to delete model from registry",
                    message: "Error: \(error.localizedDescription)",
                    metadata: ["catalog_id": catalogId, "error": error.localizedDescription]
                )
            }
            return false
        }
    }

    @discardableResult
    func validateModel(catalogId: String) async -> ModelSnapshot? {
        await MainActor.run {
            AppLogStore.shared.record(
                .modelsCatalog,
                level: .debug,
                title: "Model Validation Started",
                message: "Validating model: \(catalogId)",
                metadata: ["catalog_id": catalogId]
            )
        }

        do {
            guard let entry = try await RuntimeCoordinator.shared.resolveModelReference(
                catalogId,
                contextLength: AppSettings.shared.defaultContextLength
            ) else {
                return nil
            }

            let runtime = RuntimePreferences.validationBaseline(
                contextLength: min(entry.runtimeContextLength, AppSettings.shared.defaultContextLength)
            )
            let outcome = try await RuntimeCoordinator.shared.validateModel(
                catalogId: entry.catalogId,
                runtime: runtime
            )

            _ = try await ModelRegistryStore.shared.updateValidation(
                catalogId: entry.catalogId,
                outcome: outcome
            )
            await refresh()
            let resultSnapshot = snapshot(name: entry.catalogId)
            let summary = resultSnapshot?.validationSummary

            await MainActor.run {
                AppLogStore.shared.record(
                    .modelsCatalog,
                    level: .info,
                    title: "Model Validation Completed",
                    message: "Validation completed for: \(catalogId)",
                    metadata: ["catalog_id": catalogId, "status": "\(outcome.status)", "summary": summary ?? "none"]
                )
            }
            return resultSnapshot
        } catch {
            await MainActor.run {
                AppLogStore.shared.record(
                    .modelsCatalog,
                    level: .error,
                    title: "Failed to validate model",
                    message: "Error: \(error.localizedDescription)",
                    metadata: ["catalog_id": catalogId, "error": error.localizedDescription]
                )
            }
            return nil
        }
    }

    func deleteAllInstalledModels() async {
        do {
            let deletedEntries = try await ModelRegistryStore.shared.deleteAllInstalledModels()
            let deletedCatalogIDs = Set(deletedEntries.map(\.catalogId))
            let deletedSnapshots = deletedEntries.map(ModelSnapshot.init(entry:))

            if let activeCatalogId = ModelRunner.shared.activeCatalogId, deletedCatalogIDs.contains(activeCatalogId) {
                ModelRunner.shared.unloadModel()
            }
            if deletedSnapshots.contains(where: { $0.matchesStoredReference(AppSettings.shared.defaultModelId) }) {
                AppSettings.shared.defaultModelId = ""
            }

            await refresh()
        } catch {
            await MainActor.run {
                AppLogStore.shared.record(
                    .modelsCatalog,
                    level: .error,
                    title: "Failed to delete installed models",
                    message: "Error: \(error.localizedDescription)",
                    metadata: ["error": error.localizedDescription]
                )
            }
        }
    }

    private func migrateLegacyModelsIfNeeded() async {
        guard let container else { return }

        let hasMigrated = UserDefaults.standard.bool(forKey: Self.migrationDefaultsKey)
        guard !hasMigrated else { return }

        let context = ModelContext(container)
        let descriptor = FetchDescriptor<DownloadedModel>(
            sortBy: [SortDescriptor(\DownloadedModel.downloadDate, order: .reverse)]
        )
        let legacyModels = (try? context.fetch(descriptor)) ?? []

        let seeds = legacyModels.map { model in
            LegacyDownloadedModelSeed(
                name: model.name,
                modelId: model.modelId,
                localPath: model.localPath,
                size: model.size,
                downloadDate: model.downloadDate,
                isDownloaded: model.isDownloaded,
                quantization: model.quantization,
                parameters: model.parameters,
                contextLength: model.contextLength
            )
        }

        do {
            _ = try await ModelRegistryStore.shared.migrateLegacyModels(seeds)
            UserDefaults.standard.set(true, forKey: Self.migrationDefaultsKey)
        } catch {
            await MainActor.run {
                AppLogStore.shared.record(
                    .modelsCatalog,
                    level: .error,
                    title: "Failed to migrate legacy model records",
                    message: "Error: \(error.localizedDescription)",
                    metadata: ["error": error.localizedDescription]
                )
            }
        }
    }

    private func validatePendingGGUFModels() async {
        let pendingCatalogIDs = snapshots
            .filter {
                $0.backendKind == .ggufLlama
                    && $0.fileExists
                    && ($0.effectiveValidationStatus == .pending || $0.effectiveValidationStatus == .unknown)
            }
            .map(\.catalogId)

        for catalogId in pendingCatalogIDs {
            _ = await validateModel(catalogId: catalogId)
        }
    }
}
