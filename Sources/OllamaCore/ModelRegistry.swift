import CryptoKit
import Foundation

public enum ModelRegistryPath {
    public static let manifestFilename = "model-package.json"
    public static let registryFilename = "registry.json"

    public static var documentsDirectoryURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    }

    public static var modelsDirectoryURL: URL {
        documentsDirectoryURL.appendingPathComponent("Models", isDirectory: true)
    }

    public static var registryFileURL: URL {
        modelsDirectoryURL.appendingPathComponent(registryFilename)
    }
}

private struct ModelRegistryEnvelope: Codable {
    let formatVersion: Int
    let entries: [ModelCatalogEntry]
}

public actor ModelRegistryStore {
    public static let shared = ModelRegistryStore()

    private let fileManager = FileManager.default
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var cachedEntries: [ModelCatalogEntry]?

    public init() {
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    public func ensureStorageExists() throws {
        try fileManager.createDirectory(
            at: ModelRegistryPath.modelsDirectoryURL,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }

    public func allEntries(includeBuiltIn: Bool = true, contextLength: Int = 4096) throws -> [ModelCatalogEntry] {
        var entries = try installedEntries()
        if includeBuiltIn {
            entries.insert(SystemModelCatalog.appleFoundationEntry(contextLength: contextLength), at: 0)
        }
        return sortEntries(entries)
    }

    public func installedEntries() throws -> [ModelCatalogEntry] {
        sortEntries(try loadStoredEntries())
    }

    public func resolve(reference: String, contextLength: Int = 4096) throws -> ModelCatalogEntry? {
        let normalizedReference = reference.trimmedForLookup
        guard !normalizedReference.isEmpty else { return nil }

        return try allEntries(includeBuiltIn: true, contextLength: contextLength)
            .compactMap { entry in
                referenceMatchPriority(for: normalizedReference, entry: entry).map { ($0, entry) }
            }
            .sorted { lhs, rhs in
                if lhs.0 != rhs.0 {
                    return lhs.0 < rhs.0
                }
                if lhs.1.updatedAt != rhs.1.updatedAt {
                    return lhs.1.updatedAt > rhs.1.updatedAt
                }
                return lhs.1.displayName.localizedCaseInsensitiveCompare(rhs.1.displayName) == .orderedAscending
            }
            .first?
            .1
    }

    @discardableResult
    public func upsert(_ entry: ModelCatalogEntry) throws -> ModelCatalogEntry {
        guard !entry.isBuiltInAppleModel else {
            return entry
        }

        var entries = try loadStoredEntries()
        if let existingIndex = entries.firstIndex(where: { $0.catalogId == entry.catalogId }) {
            entries[existingIndex] = entry
        } else {
            entries.append(entry)
        }

        try saveStoredEntries(entries)
        try writeManifestIfPossible(for: entry)
        return entry
    }

    public func migrateLegacyModels(_ seeds: [LegacyDownloadedModelSeed]) throws -> [ModelCatalogEntry] {
        var migratedEntries: [ModelCatalogEntry] = []

        for seed in seeds where seed.isDownloaded {
            guard !seed.modelId.trimmedForLookup.isEmpty else { continue }
            guard !seed.localPath.trimmedForLookup.isEmpty else { continue }
            guard fileManager.fileExists(atPath: seed.localPath) else { continue }

            let existing = try resolve(reference: legacyServerIdentifier(sourceModelID: seed.modelId, displayName: seed.name))
            if existing != nil {
                continue
            }

            let localFileURL = URL(fileURLWithPath: seed.localPath)
            let packageRootURL = localFileURL.deletingLastPathComponent()
            let manifestURL = preferredManifestURL(forGGUFAt: localFileURL)
            let capability = ModelCapabilitySummary(
                sizeBytes: seed.size,
                quantization: seed.quantization,
                parameterCountLabel: seed.parameters,
                contextLength: seed.contextLength,
                supportsStreaming: true,
                notes: nil
            )

            let entry = ModelCatalogEntry(
                catalogId: catalogIdentifier(
                    backendKind: .ggufLlama,
                    sourceModelID: seed.modelId,
                    displayName: seed.name.nonEmpty ?? localFileURL.deletingPathExtension().lastPathComponent
                ),
                sourceModelID: seed.modelId,
                displayName: seed.name.nonEmpty ?? localFileURL.deletingPathExtension().lastPathComponent,
                serverIdentifier: legacyServerIdentifier(sourceModelID: seed.modelId, displayName: seed.name.nonEmpty ?? localFileURL.deletingPathExtension().lastPathComponent),
                backendKind: .ggufLlama,
                localPath: localFileURL.path,
                packageRootPath: packageRootURL.path,
                manifestPath: manifestURL.path,
                importSource: .migratedLegacy,
                isServerExposed: false,
                validationStatus: .unknown,
                validationMessage: "This migrated GGUF model has not been revalidated on this device yet.",
                aliases: legacyAliases(
                    sourceModelID: seed.modelId,
                    displayName: seed.name.nonEmpty ?? localFileURL.deletingPathExtension().lastPathComponent,
                    localPath: seed.localPath
                ),
                capabilitySummary: capability,
                serverCapabilities: ServerModelCapabilities.conservativeDefaults(
                    backendKind: .ggufLlama,
                    sourceModelID: seed.modelId,
                    displayName: seed.name.nonEmpty ?? localFileURL.deletingPathExtension().lastPathComponent,
                    capabilitySummary: capability
                ),
                createdAt: seed.downloadDate,
                updatedAt: seed.downloadDate
            )

            try upsert(entry)
            migratedEntries.append(entry)
        }

        return migratedEntries
    }

    @discardableResult
    public func registerDownloadedGGUF(
        sourceModelID: String,
        displayName: String,
        localPath: String,
        size: Int64,
        quantization: String,
        parameterCountLabel: String,
        contextLength: Int,
        serverCapabilities: ServerModelCapabilities? = nil
    ) throws -> ModelCatalogEntry {
        let localFileURL = URL(fileURLWithPath: localPath)
        let packageRootURL = localFileURL.deletingLastPathComponent()
        let manifestURL = preferredManifestURL(forGGUFAt: localFileURL)
        let effectiveDisplayName = displayName.nonEmpty ?? localFileURL.deletingPathExtension().lastPathComponent
        let capabilitySummary = ModelCapabilitySummary(
            sizeBytes: size,
            quantization: quantization,
            parameterCountLabel: parameterCountLabel,
            contextLength: contextLength,
            supportsStreaming: true,
            notes: nil
        )

        let entry = ModelCatalogEntry(
            catalogId: catalogIdentifier(
                backendKind: .ggufLlama,
                sourceModelID: sourceModelID,
                displayName: effectiveDisplayName
            ),
            sourceModelID: sourceModelID,
            displayName: effectiveDisplayName,
            serverIdentifier: legacyServerIdentifier(sourceModelID: sourceModelID, displayName: effectiveDisplayName),
            backendKind: .ggufLlama,
            localPath: localPath,
            packageRootPath: packageRootURL.path,
            manifestPath: manifestURL.path,
            importSource: .huggingFaceDownload,
            isServerExposed: false,
            validationStatus: .pending,
            validationMessage: "Validation will run after the download finishes.",
            aliases: legacyAliases(
                sourceModelID: sourceModelID,
                displayName: effectiveDisplayName,
                localPath: localPath
            ),
            capabilitySummary: capabilitySummary,
            serverCapabilities: serverCapabilities
                ?? ServerModelCapabilities.conservativeDefaults(
                    backendKind: .ggufLlama,
                    sourceModelID: sourceModelID,
                    displayName: effectiveDisplayName,
                    capabilitySummary: capabilitySummary
                )
        )

        return try upsert(entry)
    }

    @discardableResult
    public func importGGUFFile(from sourceURL: URL, defaultContextLength: Int = 4096) throws -> ModelCatalogEntry {
        let sourcePath = sourceURL.path
        guard fileManager.fileExists(atPath: sourcePath) else {
            throw InferenceError.importFailed("The selected GGUF file is no longer available.")
        }

        guard sourceURL.pathExtension.lowercased() == "gguf" else {
            throw InferenceError.importFailed("Please choose a GGUF model file.")
        }

        try ensureStorageExists()

        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let sourceModelID = "local/\(sanitizeIdentifier(baseName))"
        let packageRootURL = uniqueDirectoryURL(
            baseDirectory: ModelRegistryPath.modelsDirectoryURL.appendingPathComponent("Imported", isDirectory: true),
            preferredName: sanitizeIdentifier(baseName)
        )

        try fileManager.createDirectory(at: packageRootURL, withIntermediateDirectories: true, attributes: nil)

        let destinationFileURL = packageRootURL.appendingPathComponent(sourceURL.lastPathComponent)
        if fileManager.fileExists(atPath: destinationFileURL.path) {
            try fileManager.removeItem(at: destinationFileURL)
        }
        try fileManager.copyItem(at: sourceURL, to: destinationFileURL)

        let fileSize = (try fileManager.attributesOfItem(atPath: destinationFileURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        let displayName = baseName
        let manifestURL = packageRootURL.appendingPathComponent(ModelRegistryPath.manifestFilename)

        let entry = ModelCatalogEntry(
            catalogId: catalogIdentifier(
                backendKind: .ggufLlama,
                sourceModelID: sourceModelID,
                displayName: displayName
            ),
            sourceModelID: sourceModelID,
            displayName: displayName,
            serverIdentifier: legacyServerIdentifier(sourceModelID: sourceModelID, displayName: displayName),
            backendKind: .ggufLlama,
            localPath: destinationFileURL.path,
            packageRootPath: packageRootURL.path,
            manifestPath: manifestURL.path,
            importSource: .localImport,
            isServerExposed: false,
            validationStatus: .pending,
            validationMessage: "Validation will run after the import finishes.",
            aliases: legacyAliases(
                sourceModelID: sourceModelID,
                displayName: displayName,
                localPath: destinationFileURL.path
            ),
            capabilitySummary: ModelCapabilitySummary(
                sizeBytes: fileSize,
                quantization: detectQuantization(from: destinationFileURL.lastPathComponent) ?? "GGUF",
                parameterCountLabel: detectParameterSize(from: destinationFileURL.lastPathComponent),
                contextLength: defaultContextLength,
                supportsStreaming: true,
                notes: nil
            ),
            serverCapabilities: ServerModelCapabilities.conservativeDefaults(
                backendKind: .ggufLlama,
                sourceModelID: sourceModelID,
                displayName: displayName,
                capabilitySummary: ModelCapabilitySummary(
                    sizeBytes: fileSize,
                    quantization: detectQuantization(from: destinationFileURL.lastPathComponent) ?? "GGUF",
                    parameterCountLabel: detectParameterSize(from: destinationFileURL.lastPathComponent),
                    contextLength: defaultContextLength,
                    supportsStreaming: true,
                    notes: nil
                )
            )
        )

        return try upsert(entry)
    }

    @discardableResult
    public func importCoreMLPackage(from sourceURL: URL, defaultContextLength: Int = 4096) throws -> ModelCatalogEntry {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw InferenceError.importFailed("Choose a CoreML package directory or compiled model bundle.")
        }

        try ensureStorageExists()

        let wrapperRootURL = uniqueDirectoryURL(
            baseDirectory: ModelRegistryPath.modelsDirectoryURL.appendingPathComponent("CoreML", isDirectory: true),
            preferredName: sanitizeIdentifier(sourceURL.deletingPathExtension().lastPathComponent)
        )
        try fileManager.createDirectory(at: wrapperRootURL, withIntermediateDirectories: true, attributes: nil)

        let copiedPayloadURL = wrapperRootURL.appendingPathComponent(sourceURL.lastPathComponent, isDirectory: true)
        try fileManager.copyItem(at: sourceURL, to: copiedPayloadURL)

        let upstreamManifest = loadUpstreamManifest(in: sourceURL)
        let inferredModelID = upstreamManifest?.modelId.nonEmpty
            ?? "coreml/\(sanitizeIdentifier(sourceURL.deletingPathExtension().lastPathComponent))"
        let displayName = upstreamManifest?.displayName.nonEmpty
            ?? sourceURL.deletingPathExtension().lastPathComponent
        let manifestURL = wrapperRootURL.appendingPathComponent(ModelRegistryPath.manifestFilename)

        let manifestFiles = try snapshotPackageFiles(rootURL: wrapperRootURL)
        let totalSize = manifestFiles.reduce(Int64(0)) { partialResult, file in
            partialResult + (file.sizeBytes ?? 0)
        }

        let entry = ModelCatalogEntry(
            catalogId: catalogIdentifier(
                backendKind: .coreMLPackage,
                sourceModelID: inferredModelID,
                displayName: displayName
            ),
            sourceModelID: inferredModelID,
            displayName: displayName,
            serverIdentifier: inferredModelID,
            backendKind: .coreMLPackage,
            packageRootPath: wrapperRootURL.path,
            manifestPath: manifestURL.path,
            importSource: .coreMLImport,
            aliases: [displayName, sourceURL.lastPathComponent, sourceURL.path],
            capabilitySummary: upstreamManifest?.capabilitySummary ?? ModelCapabilitySummary(
                sizeBytes: totalSize,
                quantization: "CoreML",
                parameterCountLabel: "Package",
                contextLength: defaultContextLength,
                supportsStreaming: true,
                notes: "Imported ANEMLL/CoreML package."
            ),
            serverCapabilities: upstreamManifest?.serverCapabilities
                ?? ServerModelCapabilities.conservativeDefaults(
                    backendKind: .coreMLPackage,
                    sourceModelID: inferredModelID,
                    displayName: displayName,
                    capabilitySummary: upstreamManifest?.capabilitySummary ?? ModelCapabilitySummary(
                        sizeBytes: totalSize,
                        quantization: "CoreML",
                        parameterCountLabel: "Package",
                        contextLength: defaultContextLength,
                        supportsStreaming: true,
                        notes: "Imported ANEMLL/CoreML package."
                    )
                )
        )

        try upsert(entry)
        return entry
    }

    @discardableResult
    public func updateValidation(
        catalogId: String,
        outcome: ModelValidationOutcome
    ) throws -> ModelCatalogEntry {
        guard var entry = try resolve(reference: catalogId, contextLength: 4096),
              !entry.isBuiltInAppleModel
        else {
            throw InferenceError.registryFailure("The selected model could not be found in the registry.")
        }

        entry.validationStatus = outcome.status
        entry.validationMessage = outcome.message
        entry.validatedAt = outcome.validatedAt
        entry.updatedAt = outcome.validatedAt

        if entry.backendKind == .ggufLlama {
            entry.isServerExposed = outcome.isRunnable
        }

        return try upsert(entry)
    }

    @discardableResult
    public func deleteModel(catalogId: String) throws -> ModelCatalogEntry? {
        var entries = try loadStoredEntries()
        guard let index = entries.firstIndex(where: { $0.catalogId == catalogId }) else {
            return nil
        }

        let entry = entries.remove(at: index)
        try deleteEntryFiles(entry)
        try saveStoredEntries(entries)
        return entry
    }

    public func deleteAllInstalledModels() throws -> [ModelCatalogEntry] {
        let entries = try loadStoredEntries()
        for entry in entries {
            try deleteEntryFiles(entry)
        }
        try saveStoredEntries([])
        return entries
    }

    public func exportPackage(catalogId: String, to destinationURL: URL) throws -> URL {
        guard let entry = try resolve(reference: catalogId, contextLength: 4096) else {
            throw InferenceError.registryFailure("The selected model could not be found in the registry.")
        }

        let exportName = sanitizeIdentifier(entry.displayName)
        let exportURL = uniqueDirectoryURL(baseDirectory: destinationURL, preferredName: exportName)
        try fileManager.createDirectory(at: exportURL, withIntermediateDirectories: true, attributes: nil)

        if let packageRootURL = entry.packageRootURL, fileManager.fileExists(atPath: packageRootURL.path) {
            let destination = exportURL.appendingPathComponent(packageRootURL.lastPathComponent, isDirectory: true)
            try fileManager.copyItem(at: packageRootURL, to: destination)
            return exportURL
        }

        if let localFileURL = entry.localFileURL, fileManager.fileExists(atPath: localFileURL.path) {
            let destination = exportURL.appendingPathComponent(localFileURL.lastPathComponent)
            try fileManager.copyItem(at: localFileURL, to: destination)

            if let manifestURL = entry.manifestURL, fileManager.fileExists(atPath: manifestURL.path) {
                let manifestDestination = exportURL.appendingPathComponent(manifestURL.lastPathComponent)
                try fileManager.copyItem(at: manifestURL, to: manifestDestination)
            }
            return exportURL
        }

        throw InferenceError.exportFailed("The selected model no longer exists on disk.")
    }

    public func manifest(for entry: ModelCatalogEntry) throws -> ModelPackageManifest? {
        guard let manifestURL = entry.manifestURL, fileManager.fileExists(atPath: manifestURL.path) else {
            return nil
        }

        let data = try Data(contentsOf: manifestURL)
        return try decoder.decode(ModelPackageManifest.self, from: data)
    }

    private func loadStoredEntries() throws -> [ModelCatalogEntry] {
        if let cachedEntries {
            return cachedEntries
        }

        try ensureStorageExists()

        guard fileManager.fileExists(atPath: ModelRegistryPath.registryFileURL.path) else {
            cachedEntries = []
            return []
        }

        let data = try Data(contentsOf: ModelRegistryPath.registryFileURL)
        let envelope = try decoder.decode(ModelRegistryEnvelope.self, from: data)
        cachedEntries = envelope.entries
        return envelope.entries
    }

    private func saveStoredEntries(_ entries: [ModelCatalogEntry]) throws {
        try ensureStorageExists()

        let envelope = ModelRegistryEnvelope(
            formatVersion: ModelPackageManifest.currentFormatVersion,
            entries: sortEntries(entries)
        )
        let data = try encoder.encode(envelope)
        try data.write(to: ModelRegistryPath.registryFileURL, options: .atomic)
        cachedEntries = envelope.entries
    }

    private func sortEntries(_ entries: [ModelCatalogEntry]) -> [ModelCatalogEntry] {
        entries.sorted { lhs, rhs in
            if lhs.isBuiltInAppleModel != rhs.isBuiltInAppleModel {
                return lhs.isBuiltInAppleModel
            }
            if lhs.updatedAt != rhs.updatedAt {
                return lhs.updatedAt > rhs.updatedAt
            }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    private func referenceMatchPriority(for candidate: String, entry: ModelCatalogEntry) -> Int? {
        let normalized = candidate.trimmedForLookup.lowercased()
        guard !normalized.isEmpty else { return nil }

        if entry.catalogId.trimmedForLookup.lowercased() == normalized { return 0 }
        if entry.serverIdentifier.trimmedForLookup.lowercased() == normalized { return 1 }
        if entry.sourceModelID.trimmedForLookup.lowercased() == normalized { return 2 }
        if entry.localPath?.trimmedForLookup.lowercased() == normalized { return 3 }
        if entry.displayName.trimmedForLookup.lowercased() == normalized { return 4 }
        if entry.aliases.contains(where: { $0.trimmedForLookup.lowercased() == normalized }) { return 5 }
        return nil
    }

    private func writeManifestIfPossible(for entry: ModelCatalogEntry) throws {
        let manifestURL: URL
        let manifest: ModelPackageManifest

        switch entry.backendKind {
        case .appleFoundation:
            return
        case .ggufLlama:
            guard let localFileURL = entry.localFileURL else { return }
            manifestURL = entry.manifestURL ?? preferredManifestURL(forGGUFAt: localFileURL)
            manifest = try buildManifestForGGUF(entry: entry, localFileURL: localFileURL)
        case .coreMLPackage:
            guard let packageRootURL = entry.packageRootURL else { return }
            manifestURL = entry.manifestURL ?? packageRootURL.appendingPathComponent(ModelRegistryPath.manifestFilename)
            manifest = try buildManifestForPackage(entry: entry, packageRootURL: packageRootURL)
        }

        if let parentURL = manifestURL.deletingLastPathComponent() as URL? {
            try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true, attributes: nil)
        }

        let data = try encoder.encode(manifest)
        try data.write(to: manifestURL, options: .atomic)
    }

    private func buildManifestForGGUF(entry: ModelCatalogEntry, localFileURL: URL) throws -> ModelPackageManifest {
        let sha = try sha256(for: localFileURL)
        let size = (try fileManager.attributesOfItem(atPath: localFileURL.path)[.size] as? NSNumber)?.int64Value

        return ModelPackageManifest(
            modelId: entry.sourceModelID,
            displayName: entry.displayName,
            backendKind: .ggufLlama,
            capabilitySummary: entry.capabilitySummary,
            serverCapabilities: entry.serverCapabilities,
            files: [
                ModelPackageFile(
                    path: localFileURL.lastPathComponent,
                    sha256: sha,
                    sizeBytes: size
                )
            ]
        )
    }

    private func buildManifestForPackage(entry: ModelCatalogEntry, packageRootURL: URL) throws -> ModelPackageManifest {
        let files = try snapshotPackageFiles(rootURL: packageRootURL)
        return ModelPackageManifest(
            modelId: entry.sourceModelID,
            displayName: entry.displayName,
            backendKind: entry.backendKind,
            capabilitySummary: entry.capabilitySummary,
            serverCapabilities: entry.serverCapabilities,
            files: files
        )
    }

    private func snapshotPackageFiles(rootURL: URL) throws -> [ModelPackageFile] {
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var files: [ModelPackageFile] = []

        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { continue }

            let relativePath = fileURL.path.replacingOccurrences(of: rootURL.path + "/", with: "")
            files.append(
                ModelPackageFile(
                    path: relativePath,
                    sha256: try sha256(for: fileURL),
                    sizeBytes: values.fileSize.map(Int64.init)
                )
            )
        }

        return files.sorted { lhs, rhs in
            lhs.path.localizedCaseInsensitiveCompare(rhs.path) == .orderedAscending
        }
    }

    private func deleteEntryFiles(_ entry: ModelCatalogEntry) throws {
        switch entry.backendKind {
        case .appleFoundation:
            return
        case .coreMLPackage:
            if let packageRootURL = entry.packageRootURL, fileManager.fileExists(atPath: packageRootURL.path) {
                try fileManager.removeItem(at: packageRootURL)
            }
        case .ggufLlama:
            if let localFileURL = entry.localFileURL, fileManager.fileExists(atPath: localFileURL.path) {
                try fileManager.removeItem(at: localFileURL)
            }

            if let manifestURL = entry.manifestURL, fileManager.fileExists(atPath: manifestURL.path) {
                try? fileManager.removeItem(at: manifestURL)
            }

            if let packageRootURL = entry.packageRootURL,
               packageRootURL.path.hasPrefix(ModelRegistryPath.modelsDirectoryURL.path),
               canDeleteContainingDirectory(packageRootURL) {
                try? fileManager.removeItem(at: packageRootURL)
            }
        }
    }

    private func canDeleteContainingDirectory(_ directoryURL: URL) -> Bool {
        let remainingItems = ((try? fileManager.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { $0.lastPathComponent != ModelRegistryPath.manifestFilename }
            .filter { !$0.lastPathComponent.hasPrefix(".") }

        return remainingItems.isEmpty
    }

    private func uniqueDirectoryURL(baseDirectory: URL, preferredName: String) -> URL {
        var candidate = baseDirectory.appendingPathComponent(preferredName, isDirectory: true)
        var suffix = 2

        while fileManager.fileExists(atPath: candidate.path) {
            candidate = baseDirectory.appendingPathComponent("\(preferredName)-\(suffix)", isDirectory: true)
            suffix += 1
        }

        return candidate
    }

    private func preferredManifestURL(forGGUFAt localFileURL: URL) -> URL {
        let parentURL = localFileURL.deletingLastPathComponent()
        let siblingEntries = ((try? fileManager.contentsOfDirectory(at: parentURL, includingPropertiesForKeys: nil)) ?? [])
        let ggufCount = siblingEntries.filter { $0.pathExtension.lowercased() == "gguf" }.count

        if ggufCount <= 1 {
            return parentURL.appendingPathComponent(ModelRegistryPath.manifestFilename)
        }

        return parentURL.appendingPathComponent(".\(localFileURL.lastPathComponent).model-package.json")
    }

    private func loadUpstreamManifest(in sourceURL: URL) -> ModelPackageManifest? {
        let upstreamManifestURL = sourceURL.appendingPathComponent(ModelRegistryPath.manifestFilename)
        guard fileManager.fileExists(atPath: upstreamManifestURL.path) else {
            return nil
        }

        guard let data = try? Data(contentsOf: upstreamManifestURL) else {
            return nil
        }

        return try? decoder.decode(ModelPackageManifest.self, from: data)
    }

    private func sanitizeIdentifier(_ value: String) -> String {
        let sanitized = value
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9._/-]+"#, with: "-", options: .regularExpression)
            .replacingOccurrences(of: "//", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-/"))

        return sanitized.isEmpty ? "model" : sanitized
    }

    private func catalogIdentifier(
        backendKind: ModelBackendKind,
        sourceModelID: String,
        displayName: String
    ) -> String {
        let backendPrefix = backendKind.rawValue
        let normalizedSource = sanitizeIdentifier(sourceModelID)
        let normalizedDisplayName = sanitizeIdentifier(displayName)
        return "\(backendPrefix)/\(normalizedSource)/\(normalizedDisplayName)"
    }

    private func legacyServerIdentifier(sourceModelID: String, displayName: String) -> String {
        guard let nonEmptyDisplayName = displayName.nonEmpty else {
            return sourceModelID
        }
        return "\(sourceModelID)#\(nonEmptyDisplayName)"
    }

    private func legacyAliases(sourceModelID: String, displayName: String, localPath: String) -> [String] {
        [
            sourceModelID,
            displayName,
            localPath,
            legacyServerIdentifier(sourceModelID: sourceModelID, displayName: displayName)
        ]
    }

    private func detectQuantization(from filename: String) -> String? {
        let patterns = [
            "Q2_K", "Q3_K_S", "Q3_K_M", "Q3_K_L",
            "Q4_0", "Q4_K_S", "Q4_K_M",
            "Q5_0", "Q5_K_S", "Q5_K_M",
            "Q6_K", "Q8_0", "F16", "FP16", "FP32"
        ]

        return patterns.first { filename.localizedCaseInsensitiveContains($0) }
    }

    private func detectParameterSize(from filename: String) -> String {
        let matches = filename.range(of: #"\d+(\.\d+)?[Bb]"#, options: .regularExpression)
        return matches.map { String(filename[$0]).uppercased() } ?? "Unknown"
    }

    private func sha256(for fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let data = handle.readData(ofLength: 1_048_576)
            if data.isEmpty {
                break
            }
            hasher.update(data: data)
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private extension InferenceError {
    static func exportFailed(_ message: String) -> InferenceError {
        .registryFailure(message)
    }
}
