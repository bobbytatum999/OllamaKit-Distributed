import Foundation
import OllamaCore
import SwiftData
import SwiftUI
import UIKit
#if canImport(FoundationModels)
import FoundationModels
#endif

enum ServerExposureMode: String, CaseIterable, Identifiable {
    case localOnly
    case localNetwork
    case publicManaged
    case publicCustom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .localOnly:
            return "Local Only"
        case .localNetwork:
            return "Local Network"
        case .publicManaged:
            return "Managed Public URL"
        case .publicCustom:
            return "Custom Public URL"
        }
    }

    var description: String {
        switch self {
        case .localOnly:
            return "Only loopback clients on this device can connect."
        case .localNetwork:
            return "Other devices that can reach this device on the network can connect."
        case .publicManaged:
            return "OllamaKit connects to its managed relay service and maintains the public endpoint for you."
        case .publicCustom:
            return "Use your own tunnel or reverse proxy URL as the worldwide endpoint."
        }
    }

    var allowsRemoteConnections: Bool {
        self != .localOnly
    }

    var isPublic: Bool {
        switch self {
        case .publicManaged, .publicCustom:
            return true
        case .localOnly, .localNetwork:
            return false
        }
    }

    var usesManagedRelay: Bool {
        self == .publicManaged
    }
}

enum ServerLogLevel: String, CaseIterable, Identifiable, Codable, Sendable {
    case debug
    case info
    case warning
    case error

    var id: String { rawValue }
}

enum ServerLogCategory: String, CaseIterable, Identifiable, Codable, Sendable {
    case listener
    case connection
    case auth
    case request
    case routing
    case model
    case generation
    case stream
    case response
    case health
    case relay
    case error

    var id: String { rawValue }
}

struct ServerLogEntry: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    let timestamp: Date
    let level: ServerLogLevel
    let category: ServerLogCategory
    let title: String
    let message: String
    let requestID: String?
    let body: String?
    let metadata: [String: String]

    init(
        id: UUID = UUID(),
        timestamp: Date = .now,
        level: ServerLogLevel,
        category: ServerLogCategory,
        title: String,
        message: String,
        requestID: String? = nil,
        body: String? = nil,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.category = category
        self.title = title
        self.message = message
        self.requestID = requestID
        self.body = body?.nonEmpty
        self.metadata = metadata
    }
}

enum AppLogLevel: String, CaseIterable, Identifiable, Codable, Sendable {
    case debug
    case info
    case warning
    case error

    var id: String { rawValue }
}

enum AppLogCategory: String, CaseIterable, Identifiable, Codable, Sendable {
    case navigation
    case interaction
    case chat
    case model
    case settings
    case runtime
    case error

    var id: String { rawValue }
}

struct AppLogEntry: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    let timestamp: Date
    let level: AppLogLevel
    let category: AppLogCategory
    let title: String
    let message: String
    let metadata: [String: String]

    init(
        id: UUID = UUID(),
        timestamp: Date = .now,
        level: AppLogLevel,
        category: AppLogCategory,
        title: String,
        message: String,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.category = category
        self.title = title
        self.message = message
        self.metadata = metadata
    }
}

enum AppPersistencePaths {
    static var applicationSupportURL: URL {
        let fileManager = FileManager.default
        let url = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory.appendingPathComponent("ApplicationSupport", isDirectory: true)
        try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var logsDirectoryURL: URL {
        let url = applicationSupportURL.appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

enum PersistentJSONStore {
    static func load<Value: Decodable>(_ type: Value.Type, from url: URL, fallback: Value) -> Value {
        guard let data = try? Data(contentsOf: url) else {
            return fallback
        }
        return (try? JSONDecoder().decode(type, from: data)) ?? fallback
    }

    static func save<Value: Encodable>(_ value: Value, to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

enum PersistentLogRedactor {
    static func redact(_ value: String?) -> String? {
        guard let value else { return nil }
        var redacted = value
        let replacements: [(pattern: String, template: String)] = [
            ("github_pat_[A-Za-z0-9_]+", "[REDACTED_GITHUB_TOKEN]"),
            ("ghp_[A-Za-z0-9]+", "[REDACTED_GITHUB_TOKEN]"),
            ("(?i)(bearer\\s+)[A-Za-z0-9._\\-]+", "$1[REDACTED]"),
            ("([?&](?:token|api_key|apikey)=)[^&\\s]+", "$1[REDACTED]"),
            ("(?i)(\"(?:token|apiKey|api_key)\"\\s*:\\s*\")[^\"]+(\"?)", "$1[REDACTED]$2")
        ]

        for replacement in replacements {
            redacted = redacted.replacingOccurrences(
                of: replacement.pattern,
                with: replacement.template,
                options: .regularExpression
            )
        }

        return redacted
    }

    static func redact(metadata: [String: String]) -> [String: String] {
        metadata.mapValues { redact($0) ?? "" }
    }
}

@MainActor
final class ServerLogStore: ObservableObject {
    static let shared = ServerLogStore()
    private static let storageURL = AppPersistencePaths.logsDirectoryURL.appendingPathComponent("server-log-buffer.json")
    private let maxEntries = 600

    @Published private(set) var entries: [ServerLogEntry] = []

    var retentionLimit: Int { maxEntries }
    var storageLocationDescription: String { "Application Support/Logs/server-log-buffer.json" }
    var storagePath: String { Self.storageURL.path }
    var persistenceSummary: String { "Stored on device. Keeps the latest \(maxEntries) server/API entries until you clear them." }

    private init() {
        entries = PersistentJSONStore.load([ServerLogEntry].self, from: Self.storageURL, fallback: []).map(Self.sanitized)
    }

    func record(_ entry: ServerLogEntry) {
        entries.append(Self.sanitized(entry))
        let overflow = entries.count - maxEntries
        if overflow > 0 {
            entries.removeFirst(overflow)
        }
        persist()
    }

    func clear() {
        entries.removeAll()
        persist()
    }

    func exportText() -> String {
        entries.map { entry in
            let timestamp = ISO8601DateFormatter().string(from: entry.timestamp)
            let requestPart = entry.requestID.map { " [\($0)]" } ?? ""
            let metadataPart = entry.metadata.isEmpty
                ? ""
                : " " + entry.metadata
                    .sorted { $0.key < $1.key }
                    .map { "\($0.key)=\($0.value)" }
                    .joined(separator: " ")
            let bodyPart = entry.body.map { "\n\($0)" } ?? ""
            return "[\(timestamp)] [\(entry.level.rawValue.uppercased())] [\(entry.category.rawValue)]\(requestPart) \(entry.title): \(entry.message)\(metadataPart)\(bodyPart)"
        }
        .joined(separator: "\n\n")
    }

    private func persist() {
        PersistentJSONStore.save(entries, to: Self.storageURL)
    }

    private static func sanitized(_ entry: ServerLogEntry) -> ServerLogEntry {
        ServerLogEntry(
            id: entry.id,
            timestamp: entry.timestamp,
            level: entry.level,
            category: entry.category,
            title: PersistentLogRedactor.redact(entry.title) ?? entry.title,
            message: PersistentLogRedactor.redact(entry.message) ?? entry.message,
            requestID: PersistentLogRedactor.redact(entry.requestID),
            body: PersistentLogRedactor.redact(entry.body),
            metadata: PersistentLogRedactor.redact(metadata: entry.metadata)
        )
    }
}

@MainActor
final class AppLogStore: ObservableObject {
    static let shared = AppLogStore()
    private static let storageURL = AppPersistencePaths.logsDirectoryURL.appendingPathComponent("app-log-buffer.json")
    private let maxEntries = 800

    @Published private(set) var entries: [AppLogEntry] = []

    var retentionLimit: Int { maxEntries }
    var storageLocationDescription: String { "Application Support/Logs/app-log-buffer.json" }
    var persistenceSummary: String { "App debug logs only (excludes server logs). Keeps latest \(maxEntries) events." }

    private init() {
        entries = PersistentJSONStore.load([AppLogEntry].self, from: Self.storageURL, fallback: []).map(Self.sanitized)
    }

    func record(
        _ category: AppLogCategory,
        level: AppLogLevel = .info,
        title: String,
        message: String,
        metadata: [String: String] = [:]
    ) {
        entries.append(
            Self.sanitized(
                AppLogEntry(
                    level: level,
                    category: category,
                    title: title,
                    message: message,
                    metadata: metadata
                )
            )
        )

        let overflow = entries.count - maxEntries
        if overflow > 0 {
            entries.removeFirst(overflow)
        }
        persist()
    }

    func clear() {
        entries.removeAll()
        persist()
    }

    private func persist() {
        PersistentJSONStore.save(entries, to: Self.storageURL)
    }

    private static func sanitized(_ entry: AppLogEntry) -> AppLogEntry {
        AppLogEntry(
            id: entry.id,
            timestamp: entry.timestamp,
            level: entry.level,
            category: entry.category,
            title: PersistentLogRedactor.redact(entry.title) ?? entry.title,
            message: PersistentLogRedactor.redact(entry.message) ?? entry.message,
            metadata: PersistentLogRedactor.redact(metadata: entry.metadata)
        )
    }
}

struct ModelPerformanceSample: Identifiable, Hashable, Codable, Sendable {
    enum Phase: String, Codable, CaseIterable, Sendable {
        case load
        case generate
    }

    let id: UUID
    let timestamp: Date
    let modelID: String
    let phase: Phase
    let elapsedMs: Double
    let tokens: Int
    let tokensPerSecond: Double
    let wasSuccessful: Bool
    let notes: String?

    init(
        id: UUID = UUID(),
        timestamp: Date = .now,
        modelID: String,
        phase: Phase,
        elapsedMs: Double,
        tokens: Int = 0,
        tokensPerSecond: Double = 0,
        wasSuccessful: Bool,
        notes: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.modelID = modelID
        self.phase = phase
        self.elapsedMs = elapsedMs
        self.tokens = tokens
        self.tokensPerSecond = tokensPerSecond
        self.wasSuccessful = wasSuccessful
        self.notes = notes
    }
}

@MainActor
final class ModelPerformanceStore: ObservableObject {
    static let shared = ModelPerformanceStore()
    private static let storageURL = AppPersistencePaths.logsDirectoryURL.appendingPathComponent("model-performance-buffer.json")
    private let maxEntries = 300

    @Published private(set) var entries: [ModelPerformanceSample] = []

    private init() {
        entries = PersistentJSONStore.load([ModelPerformanceSample].self, from: Self.storageURL, fallback: [])
    }

    func record(_ sample: ModelPerformanceSample) {
        entries.append(sample)
        let overflow = entries.count - maxEntries
        if overflow > 0 {
            entries.removeFirst(overflow)
        }
        PersistentJSONStore.save(entries, to: Self.storageURL)
    }

    func clear() {
        entries.removeAll()
        PersistentJSONStore.save(entries, to: Self.storageURL)
    }
}

@Model
final class DownloadedModel {
    var id: UUID
    var name: String
    var modelId: String
    var localPath: String
    var size: Int64
    var downloadDate: Date
    var isDownloaded: Bool
    var isFavorite: Bool
    var quantization: String
    var parameters: String
    var contextLength: Int

    init(
        id: UUID = UUID(),
        name: String,
        modelId: String,
        localPath: String = "",
        size: Int64 = 0,
        downloadDate: Date = .now,
        isDownloaded: Bool = false,
        isFavorite: Bool = false,
        quantization: String = "GGUF",
        parameters: String = "Unknown",
        contextLength: Int = 4096
    ) {
        self.id = id
        self.name = name
        self.modelId = modelId
        self.localPath = localPath
        self.size = size
        self.downloadDate = downloadDate
        self.isDownloaded = isDownloaded
        self.isFavorite = isFavorite
        self.quantization = quantization
        self.parameters = parameters
        self.contextLength = contextLength
    }

    var displayName: String {
        if !name.isEmpty {
            return name
        }

        let modelName = modelId.split(separator: "/").last.map(String.init)
        return modelName?.replacingOccurrences(of: ".gguf", with: "") ?? modelId
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    var fileExists: Bool {
        !localPath.isEmpty && FileManager.default.fileExists(atPath: localPath)
    }

    var runtimeContextLength: Int {
        max(AppSettings.shared.defaultContextLength, 512)
    }

    var persistentReference: String {
        apiIdentifier
    }

    var apiIdentifier: String {
        guard let name = name.nonEmpty else {
            return modelId
        }

        return "\(modelId)#\(name)"
    }

    var isBuiltInAppleModel: Bool {
        modelId == BuiltInModelCatalog.appleOnDeviceModelID
    }

    func matchesStoredReference(_ candidate: String) -> Bool {
        matchPriority(forStoredReference: candidate) != nil
    }

    func matchPriority(forStoredReference candidate: String) -> Int? {
        let normalizedCandidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedCandidate.isEmpty else { return nil }

        if localPath.caseInsensitiveCompare(normalizedCandidate) == .orderedSame {
            return 0
        }

        if apiIdentifier.caseInsensitiveCompare(normalizedCandidate) == .orderedSame {
            return 1
        }

        if modelId.caseInsensitiveCompare(normalizedCandidate) == .orderedSame {
            return 2
        }

        if name.caseInsensitiveCompare(normalizedCandidate) == .orderedSame {
            return 3
        }

        if displayName.caseInsensitiveCompare(normalizedCandidate) == .orderedSame {
            return 4
        }

        return nil
    }

    static func resolveStoredReference(_ candidate: String, in models: [DownloadedModel]) -> DownloadedModel? {
        let normalizedCandidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
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

                return lhs.1.id.uuidString < rhs.1.id.uuidString
            }
            .first?
            .1
    }
}

struct DownloadedModelSeed: Sendable {
    let modelId: String
    let name: String
    let localPath: String
    let size: Int64
    let quantization: String
    let parameters: String
    let contextLength: Int
    let serverCapabilities: ServerModelCapabilities?
}

extension DownloadedModel {
    var registrySeed: DownloadedModelSeed {
        DownloadedModelSeed(
            modelId: modelId,
            name: name,
            localPath: localPath,
            size: size,
            quantization: quantization,
            parameters: parameters,
            contextLength: contextLength,
            serverCapabilities: nil
        )
    }
}

enum BuiltInModelAvailability: Equatable {
    case available(String)
    case unavailable(String)

    var isAvailable: Bool {
        if case .available = self {
            return true
        }

        return false
    }

    var title: String {
        switch self {
        case .available:
            return "Available"
        case .unavailable:
            return "Unavailable"
        }
    }

    var detail: String {
        switch self {
        case .available(let detail), .unavailable(let detail):
            return detail
        }
    }

    var tint: Color {
        isAvailable ? .green : .orange
    }
}

enum BuiltInModelCatalog {
    static let appleOnDeviceModelID = SystemModelCatalog.appleFoundationCatalogID
    static let appleOnDeviceModelName = SystemModelCatalog.appleFoundationModelName

    static func appleOnDeviceModel() -> ModelSnapshot {
        ModelSnapshot(
            entry: SystemModelCatalog.appleFoundationEntry(
                contextLength: AppSettings.shared.defaultContextLength
            )
        )
    }

    static func selectionModels(downloadedModels: [ModelSnapshot]) -> [ModelSnapshot] {
        let appleIsAvailable = availability().isAvailable

        return downloadedModels.filter { model in
            switch model.backendKind {
            case .ggufLlama:
                return model.canBeSelectedForChat
            case .appleFoundation:
                return appleIsAvailable
            case .coreMLPackage:
                return model.canBeSelectedForChat
            }
        }
    }

    static func resolveStoredReference(_ candidate: String, in downloadedModels: [ModelSnapshot]) -> ModelSnapshot? {
        ModelSnapshot.resolveStoredReference(candidate, in: selectionModels(downloadedModels: downloadedModels))
    }

    static func availability() -> BuiltInModelAvailability {
#if canImport(FoundationModels)
        guard #available(iOS 26.0, *) else {
            return .unavailable("Apple's on-device model requires iOS 26 or newer.")
        }

        let model = SystemLanguageModel.default

        guard model.supportsLocale() else {
            return .unavailable("Apple Intelligence is not enabled for the current language or locale.")
        }

        if case .available = model.availability {
            return .available("Uses Apple's built-in on-device model through the Foundation Models framework. No download is required.")
        }

        let availabilityDescription = String(describing: model.availability)
        if availabilityDescription.localizedCaseInsensitiveContains("deviceNotEligible") {
            return .unavailable("This device is not eligible for Apple's on-device model.")
        }
        if availabilityDescription.localizedCaseInsensitiveContains("appleIntelligenceNotEnabled") {
            return .unavailable("Turn on Apple Intelligence to use Apple's on-device model.")
        }
        if availabilityDescription.localizedCaseInsensitiveContains("modelNotReady") {
            return .unavailable("Apple's on-device model is still preparing on this device.")
        }

        return .unavailable("Apple's on-device model is unavailable on this device.")
#else
        return .unavailable("This build does not include Apple's Foundation Models framework.")
#endif
    }
}

enum ChatRole: String, Codable, CaseIterable {
    case system
    case user
    case assistant
}

@Model
final class ChatSession {
    var id: UUID
    var title: String
    var modelId: String
    var systemPrompt: String
    var createdAt: Date
    var updatedAt: Date

    @Relationship(deleteRule: .cascade, inverse: \ChatMessage.session)
    var messages: [ChatMessage]?

    init(
        title: String? = nil,
        modelId: String,
        systemPrompt: String = "You are a helpful assistant.",
        createdAt: Date = .now,
        updatedAt: Date = .now,
        messages: [ChatMessage]? = []
    ) {
        self.id = UUID()
        self.title = title ?? "New Chat"
        self.modelId = modelId
        self.systemPrompt = systemPrompt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messages = messages
    }

    var orderedMessages: [ChatMessage] {
        (messages ?? []).sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt < rhs.createdAt
            }

            return lhs.id.uuidString < rhs.id.uuidString
        }
    }
}

@Model
final class ChatMessage {
    var id: UUID
    var roleValue: String
    var content: String
    var createdAt: Date
    var tokenCount: Int
    var generationTime: Double
    var isGenerating: Bool
    var session: ChatSession?

    init(
        role: ChatRole,
        content: String,
        createdAt: Date = .now,
        tokenCount: Int = 0,
        generationTime: Double = 0,
        isGenerating: Bool = false
    ) {
        self.id = UUID()
        self.roleValue = role.rawValue
        self.content = content
        self.createdAt = createdAt
        self.tokenCount = tokenCount
        self.generationTime = generationTime
        self.isGenerating = isGenerating
    }

    var role: ChatRole {
        get { ChatRole(rawValue: roleValue) ?? .assistant }
        set { roleValue = newValue.rawValue }
    }
}

struct HuggingFaceSibling: Decodable, Hashable, Sendable {
    let rfilename: String?
    let path: String?

    var filename: String? {
        let candidate = rfilename?.nonEmpty ?? path?.nonEmpty
        return candidate.map { URL(fileURLWithPath: $0).lastPathComponent }
    }
}

struct HuggingFaceGGUFMetadata: Decodable, Hashable, Sendable {
    let contextLength: Int?
    let chatTemplate: String?
}

struct HuggingFaceModel: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let description: String?
    let downloads: Int?
    let likes: Int?
    let tags: [String]?
    let author: String?
    let pipelineTag: String?
    let libraryName: String?
    let gated: Bool?
    let disabled: Bool?
    let siblings: [HuggingFaceSibling]?
    let gguf: HuggingFaceGGUFMetadata?

    var modelId: String { id }

    var displayName: String {
        id.split(separator: "/").last.map(String.init) ?? id
    }

    var organization: String {
        let components = id.split(separator: "/").map(String.init)
        if components.count > 1 {
            return components.dropLast().joined(separator: "/")
        }
        return "Hugging Face"
    }

    var isGated: Bool {
        gated ?? false
    }

    var isDisabled: Bool {
        disabled ?? false
    }

    var siblingFilenames: [String] {
        (siblings ?? []).compactMap(\.filename)
    }

    var repositoryMetadata: HuggingFaceRepositoryMetadata {
        HuggingFaceRepositoryMetadata(
            modelId: modelId,
            displayName: displayName,
            organization: organization,
            description: description,
            downloads: downloads ?? 0,
            likes: likes ?? 0,
            tags: tags ?? [],
            author: author,
            pipelineTag: pipelineTag,
            libraryName: libraryName,
            gated: isGated,
            disabled: isDisabled,
            ggufContextLength: gguf?.contextLength,
            hasChatTemplate: gguf?.chatTemplate?.nonEmpty != nil,
            siblingFilenames: siblingFilenames
        )
    }

    var repositoryAssessment: HuggingFaceRepositoryAssessment {
        HuggingFaceRepositoryAssessor.assess(repositoryMetadata)
    }
}

struct GGUFInfo: Identifiable, Hashable, Sendable {
    let url: URL
    let filename: String
    let size: Int64?
    let quantization: String?

    var id: String { url.absoluteString }
    var displayName: String { filename }
}

struct HuggingFaceRepositoryMetadata: Hashable, Sendable {
    let modelId: String
    let displayName: String
    let organization: String
    let description: String?
    let downloads: Int
    let likes: Int
    let tags: [String]
    let author: String?
    let pipelineTag: String?
    let libraryName: String?
    let gated: Bool
    let disabled: Bool
    let ggufContextLength: Int?
    let hasChatTemplate: Bool
    let siblingFilenames: [String]
}

enum HuggingFaceRepositoryDisposition: String, Hashable, Sendable {
    case recommended
    case caution
    case blocked
}

struct HuggingFaceRepositoryAssessment: Hashable, Sendable {
    let disposition: HuggingFaceRepositoryDisposition
    let reason: String
    let warningBadges: [String]
    let isConversational: Bool
    let isSuggestedEligible: Bool
    let isResolutionEligible: Bool
}

struct HuggingFaceCandidate: Identifiable, Hashable, Sendable {
    let model: HuggingFaceModel
    let file: GGUFInfo
    let assessment: HuggingFaceRepositoryAssessment
    let compatibility: CompatibilityReport

    var id: String {
        "\(model.modelId)#\(file.filename)"
    }

    var isSuggested: Bool {
        assessment.isSuggestedEligible && compatibility.level.isUsable
    }
}

enum HuggingFaceRepositoryAssessor {
    private static let generativePipelineTags: Set<String> = [
        "text-generation",
        "conversational"
    ]

    private static let excludedPipelineTags: Set<String> = [
        "feature-extraction",
        "sentence-similarity",
        "fill-mask",
        "token-classification",
        "text-classification",
        "zero-shot-classification"
    ]

    static func assess(_ metadata: HuggingFaceRepositoryMetadata) -> HuggingFaceRepositoryAssessment {
        let normalizedPipelineTag = metadata.pipelineTag?.trimmedForLookup.lowercased()
        let normalizedModelID = metadata.modelId.trimmedForLookup.lowercased()
        let normalizedDescription = metadata.description?.trimmedForLookup.lowercased() ?? ""
        let normalizedTags = metadata.tags.map { $0.trimmedForLookup.lowercased() }
        let combinedSignals = normalizedTags + [normalizedModelID, normalizedDescription]

        let isPlaceholder = normalizedModelID.contains("models-moved")
            || normalizedModelID.contains("placeholder")
            || normalizedDescription.contains("moved to")
        let isEmbedding = excludedPipelineTags.contains(normalizedPipelineTag ?? "")
            || combinedSignals.contains(where: { $0.contains("embedding") || $0.contains("feature-extraction") || $0.contains("rerank") })
        let isConversational = generativePipelineTags.contains(normalizedPipelineTag ?? "")
            || combinedSignals.contains(where: { $0.contains("instruct") || $0.contains("chat") || $0.contains("assistant") })
            || metadata.hasChatTemplate

        if metadata.disabled {
            return HuggingFaceRepositoryAssessment(
                disposition: .blocked,
                reason: "This repository is disabled on Hugging Face.",
                warningBadges: ["Disabled"],
                isConversational: isConversational,
                isSuggestedEligible: false,
                isResolutionEligible: false
            )
        }

        if metadata.gated {
            return HuggingFaceRepositoryAssessment(
                disposition: .blocked,
                reason: "This repository is gated and may not be downloadable on-device without extra access.",
                warningBadges: ["Gated"],
                isConversational: isConversational,
                isSuggestedEligible: false,
                isResolutionEligible: false
            )
        }

        if isPlaceholder {
            return HuggingFaceRepositoryAssessment(
                disposition: .blocked,
                reason: "This repository looks like a placeholder or redirect, not a real downloadable chat model.",
                warningBadges: ["Placeholder"],
                isConversational: false,
                isSuggestedEligible: false,
                isResolutionEligible: false
            )
        }

        if isEmbedding {
            return HuggingFaceRepositoryAssessment(
                disposition: .caution,
                reason: "This repository looks like an embedding or feature-extraction model, not a normal chat/generation model.",
                warningBadges: ["Embeddings"],
                isConversational: false,
                isSuggestedEligible: false,
                isResolutionEligible: false
            )
        }

        if isConversational {
            return HuggingFaceRepositoryAssessment(
                disposition: .recommended,
                reason: "This repository looks like a real chat or text-generation model.",
                warningBadges: [],
                isConversational: true,
                isSuggestedEligible: true,
                isResolutionEligible: true
            )
        }

        return HuggingFaceRepositoryAssessment(
            disposition: .caution,
            reason: "This repository is downloadable, but it does not clearly advertise itself as a chat/text-generation model.",
            warningBadges: ["Unverified"],
            isConversational: false,
            isSuggestedEligible: false,
            isResolutionEligible: false
        )
    }
}

struct PromptTurn: Sendable {
    let role: String
    let content: String
}

enum PromptComposer {
    static let defaultChatStopSequences = [
        "\nUser:",
        "\nAssistant:",
        "\nSystem:",
        "\nHuman:",
        "\nMe:",
        "\nBot:"
    ]

    static func compose(
        systemPrompt: String? = nil,
        messages: [PromptTurn],
        appendAssistantCue: Bool = false
    ) -> String {
        let systemBlock = systemPrompt?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
            .map { "System:\n\($0)" }

        let conversation = messages
            .map { message in
                let role = message.role.trimmingCharacters(in: .whitespacesAndNewlines).capitalized
                let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !content.isEmpty else { return nil }
                return "\(role):\n\(content)"
            }
            .compactMap { $0 }
            .joined(separator: "\n\n")

        let assistantCue = appendAssistantCue ? "Assistant:\n" : nil

        return [systemBlock, conversation.nonEmpty, assistantCue]
            .compactMap { $0 }
            .joined(separator: "\n\n")
            .nonEmpty ?? ""
    }

    static func guardedSystemPrompt(_ systemPrompt: String?) -> String? {
        let guardInstruction = "Reply with only the assistant's next message. Do not continue the conversation as the user. Do not include speaker labels such as User:, Assistant:, Human:, or Me:."

        return [systemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty, guardInstruction]
            .compactMap { $0 }
            .joined(separator: "\n\n")
            .nonEmpty
    }
}

enum HapticManager {
    @MainActor
    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .light) {
        guard AppSettings.shared.hapticFeedback else { return }
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.prepare()
        generator.impactOccurred()
    }

    @MainActor
    static func selectionChanged() {
        guard AppSettings.shared.hapticFeedback else { return }
        let generator = UISelectionFeedbackGenerator()
        generator.prepare()
        generator.selectionChanged()
    }

    @MainActor
    static func notification(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        guard AppSettings.shared.hapticFeedback else { return }
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(type)
    }
}

enum ModelPathHelper {
    static var modelsDirectoryURL: URL {
        ModelRegistryPath.modelsDirectoryURL
    }

    static func ensureModelsDirectoryExists() throws {
        try FileManager.default.createDirectory(
            at: modelsDirectoryURL,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }
}

final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var defaultTemperature: Double { didSet { save(defaultTemperature, for: Keys.defaultTemperature) } }
    @Published var defaultTopP: Double { didSet { save(defaultTopP, for: Keys.defaultTopP) } }
    @Published var defaultTopK: Int { didSet { save(defaultTopK, for: Keys.defaultTopK) } }
    @Published var defaultRepeatPenalty: Double { didSet { save(defaultRepeatPenalty, for: Keys.defaultRepeatPenalty) } }
    @Published var defaultRepeatLastN: Int { didSet { save(defaultRepeatLastN, for: Keys.defaultRepeatLastN) } }
    @Published var defaultContextLength: Int { didSet { save(defaultContextLength, for: Keys.defaultContextLength) } }
    @Published var maxTokens: Int { didSet { save(maxTokens, for: Keys.maxTokens) } }

    @Published var threads: Int { didSet { save(threads, for: Keys.threads) } }
    @Published var batchSize: Int { didSet { save(batchSize, for: Keys.batchSize) } }
    @Published var gpuLayers: Int { didSet { save(gpuLayers, for: Keys.gpuLayers) } }
    @Published var flashAttentionEnabled: Bool { didSet { save(flashAttentionEnabled, for: Keys.flashAttentionEnabled) } }
    @Published var mmapEnabled: Bool { didSet { save(mmapEnabled, for: Keys.mmapEnabled) } }
    @Published var mlockEnabled: Bool { didSet { save(mlockEnabled, for: Keys.mlockEnabled) } }
    @Published var turboQuantMode: RuntimePreferences.TurboQuantMode {
        didSet { save(turboQuantMode.rawValue, for: Keys.turboQuantMode) }
    }
    @Published var kvCacheTypeK: RuntimePreferences.KVCacheQuantization {
        didSet { save(kvCacheTypeK.rawValue, for: Keys.kvCacheTypeK) }
    }
    @Published var kvCacheTypeV: RuntimePreferences.KVCacheQuantization {
        didSet { save(kvCacheTypeV.rawValue, for: Keys.kvCacheTypeV) }
    }
    @Published var keepModelInMemory: Bool { didSet { save(keepModelInMemory, for: Keys.keepModelInMemory) } }
    @Published var autoOffloadMinutes: Int { didSet { save(autoOffloadMinutes, for: Keys.autoOffloadMinutes) } }

    @Published var huggingFaceToken: String { didSet { save(huggingFaceToken, for: Keys.huggingFaceToken) } }

    @Published var darkMode: Bool { didSet { save(darkMode, for: Keys.darkMode) } }
    @Published var hapticFeedback: Bool { didSet { save(hapticFeedback, for: Keys.hapticFeedback) } }
    @Published var showTokenCount: Bool { didSet { save(showTokenCount, for: Keys.showTokenCount) } }
    @Published var showGenerationSpeed: Bool { didSet { save(showGenerationSpeed, for: Keys.showGenerationSpeed) } }
    @Published var markdownRendering: Bool { didSet { save(markdownRendering, for: Keys.markdownRendering) } }
    @Published var streamingEnabled: Bool { didSet { save(streamingEnabled, for: Keys.streamingEnabled) } }

    @Published var serverEnabled: Bool { didSet { save(serverEnabled, for: Keys.serverEnabled) } }
    @Published var serverPort: Int { didSet { save(serverPort, for: Keys.serverPort) } }
    @Published var serverExposureMode: ServerExposureMode {
        didSet {
            save(serverExposureMode.rawValue, for: Keys.serverExposureMode)
            save(serverExposureMode.allowsRemoteConnections, for: Keys.allowExternalConnections)
            enforcePublicServerSecurity()
        }
    }
    @Published var publicBaseURL: String { didSet { save(publicBaseURL, for: Keys.publicBaseURL) } }
    @Published var managedRelayBaseURL: String {
        didSet {
            if oldValue.trimmedForLookup != managedRelayBaseURL.trimmedForLookup {
                clearManagedRelaySession()
            }
            save(managedRelayBaseURL, for: Keys.managedRelayBaseURL)
        }
    }
    @Published var managedRelayDeviceID: String { didSet { save(managedRelayDeviceID, for: Keys.managedRelayDeviceID) } }
    @Published var managedRelayAccessToken: String { didSet { save(managedRelayAccessToken, for: Keys.managedRelayAccessToken) } }
    @Published var managedRelayAssignedURL: String { didSet { save(managedRelayAssignedURL, for: Keys.managedRelayAssignedURL) } }
    @Published var managedRelayWebSocketURL: String { didSet { save(managedRelayWebSocketURL, for: Keys.managedRelayWebSocketURL) } }
    @Published var requireApiKey: Bool {
        didSet {
            if serverExposureMode.isPublic && !requireApiKey {
                requireApiKey = true
                return
            }
            save(requireApiKey, for: Keys.requireApiKey)
        }
    }
    @Published var apiKey: String {
        didSet {
            if serverExposureMode.isPublic && apiKey.trimmedForLookup.isEmpty {
                apiKey = Self.generatedAPIKey()
                return
            }
            save(apiKey, for: Keys.apiKey)
        }
    }
    @Published var defaultModelId: String { didSet { save(defaultModelId, for: Keys.defaultModelId) } }
    @Published var powerAgentEnabled: Bool { didSet { save(powerAgentEnabled, for: Keys.powerAgentEnabled) } }
    @Published var agentRequireWriteApproval: Bool { didSet { save(agentRequireWriteApproval, for: Keys.agentRequireWriteApproval) } }
    @Published var agentGitHubToken: String { didSet { save(agentGitHubToken, for: Keys.agentGitHubToken) } }
    @Published var agentGitHubClientID: String { didSet { save(agentGitHubClientID, for: Keys.agentGitHubClientID) } }
    @Published var agentGitHubRepository: String { didSet { save(agentGitHubRepository, for: Keys.agentGitHubRepository) } }
    @Published var agentDefaultWorkspaceID: String { didSet { save(agentDefaultWorkspaceID, for: Keys.agentDefaultWorkspaceID) } }
    @Published var agentGitHubDeviceCode: String { didSet { save(agentGitHubDeviceCode, for: Keys.agentGitHubDeviceCode) } }
    @Published var agentGitHubUserCode: String { didSet { save(agentGitHubUserCode, for: Keys.agentGitHubUserCode) } }
    @Published var agentGitHubVerificationURL: String { didSet { save(agentGitHubVerificationURL, for: Keys.agentGitHubVerificationURL) } }
    @Published var agentGitHubDeviceFlowExpiresAt: Date? {
        didSet {
            if let agentGitHubDeviceFlowExpiresAt {
                save(agentGitHubDeviceFlowExpiresAt.timeIntervalSince1970, for: Keys.agentGitHubDeviceFlowExpiresAt)
            } else {
                defaults.removeObject(forKey: Keys.agentGitHubDeviceFlowExpiresAt)
            }
        }
    }
    @Published var agentBrowserHomeURL: String { didSet { save(agentBrowserHomeURL, for: Keys.agentBrowserHomeURL) } }
    @Published var agentBrowserLastURL: String { didSet { save(agentBrowserLastURL, for: Keys.agentBrowserLastURL) } }
    @Published var agentBundleExpertMode: Bool { didSet { save(agentBundleExpertMode, for: Keys.agentBundleExpertMode) } }
    @Published var agentModelCapabilityOverrides: [String: ModelAgentCapabilityOverride] {
        didSet {
            saveCodable(agentModelCapabilityOverrides, for: Keys.agentModelCapabilityOverrides)
        }
    }

    private let defaults: UserDefaults

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        defaultTemperature = defaults.object(forKey: Keys.defaultTemperature) as? Double ?? 0.7
        defaultTopP = defaults.object(forKey: Keys.defaultTopP) as? Double ?? 0.9
        defaultTopK = defaults.object(forKey: Keys.defaultTopK) as? Int ?? 40
        defaultRepeatPenalty = defaults.object(forKey: Keys.defaultRepeatPenalty) as? Double ?? 1.1
        defaultRepeatLastN = defaults.object(forKey: Keys.defaultRepeatLastN) as? Int ?? 64
        defaultContextLength = defaults.object(forKey: Keys.defaultContextLength) as? Int ?? 4096
        maxTokens = defaults.object(forKey: Keys.maxTokens) as? Int ?? 1024

        threads = defaults.object(forKey: Keys.threads) as? Int ?? max(ProcessInfo.processInfo.processorCount - 1, 1)
        batchSize = defaults.object(forKey: Keys.batchSize) as? Int ?? 512
        gpuLayers = defaults.object(forKey: Keys.gpuLayers) as? Int ?? 0
        flashAttentionEnabled = defaults.object(forKey: Keys.flashAttentionEnabled) as? Bool ?? false
        mmapEnabled = defaults.object(forKey: Keys.mmapEnabled) as? Bool ?? true
        mlockEnabled = defaults.object(forKey: Keys.mlockEnabled) as? Bool ?? false
        turboQuantMode = RuntimePreferences.TurboQuantMode(rawValue: defaults.string(forKey: Keys.turboQuantMode) ?? "") ?? .disabled
        kvCacheTypeK = RuntimePreferences.KVCacheQuantization(rawValue: defaults.string(forKey: Keys.kvCacheTypeK) ?? "") ?? .float16
        kvCacheTypeV = RuntimePreferences.KVCacheQuantization(rawValue: defaults.string(forKey: Keys.kvCacheTypeV) ?? "") ?? .float16
        keepModelInMemory = defaults.object(forKey: Keys.keepModelInMemory) as? Bool ?? false
        autoOffloadMinutes = defaults.object(forKey: Keys.autoOffloadMinutes) as? Int ?? 5

        huggingFaceToken = defaults.string(forKey: Keys.huggingFaceToken) ?? ""

        darkMode = defaults.object(forKey: Keys.darkMode) as? Bool ?? true
        hapticFeedback = defaults.object(forKey: Keys.hapticFeedback) as? Bool ?? true
        showTokenCount = defaults.object(forKey: Keys.showTokenCount) as? Bool ?? true
        showGenerationSpeed = defaults.object(forKey: Keys.showGenerationSpeed) as? Bool ?? true
        markdownRendering = defaults.object(forKey: Keys.markdownRendering) as? Bool ?? true
        streamingEnabled = defaults.object(forKey: Keys.streamingEnabled) as? Bool ?? true

        serverEnabled = defaults.object(forKey: Keys.serverEnabled) as? Bool ?? false
        serverPort = defaults.object(forKey: Keys.serverPort) as? Int ?? 11434
        if let rawMode = defaults.string(forKey: Keys.serverExposureMode) {
            switch rawMode {
            case ServerExposureMode.localOnly.rawValue:
                serverExposureMode = .localOnly
            case ServerExposureMode.localNetwork.rawValue:
                serverExposureMode = .localNetwork
            case ServerExposureMode.publicManaged.rawValue:
                serverExposureMode = .publicManaged
            case ServerExposureMode.publicCustom.rawValue, "publicURL":
                serverExposureMode = .publicCustom
            default:
                serverExposureMode = .localOnly
            }
        } else {
            let legacyAllowExternal = defaults.object(forKey: Keys.allowExternalConnections) as? Bool ?? false
            serverExposureMode = legacyAllowExternal ? .localNetwork : .localOnly
        }
        publicBaseURL = defaults.string(forKey: Keys.publicBaseURL) ?? ""
        managedRelayBaseURL = defaults.string(forKey: Keys.managedRelayBaseURL)
            ?? (Bundle.main.object(forInfoDictionaryKey: "OllamaKitManagedRelayBaseURL") as? String)
            ?? ""
        managedRelayDeviceID = defaults.string(forKey: Keys.managedRelayDeviceID) ?? UUID().uuidString.lowercased()
        managedRelayAccessToken = defaults.string(forKey: Keys.managedRelayAccessToken) ?? ""
        managedRelayAssignedURL = defaults.string(forKey: Keys.managedRelayAssignedURL) ?? ""
        managedRelayWebSocketURL = defaults.string(forKey: Keys.managedRelayWebSocketURL) ?? ""
        requireApiKey = defaults.object(forKey: Keys.requireApiKey) as? Bool ?? false
        apiKey = defaults.string(forKey: Keys.apiKey) ?? Self.generatedAPIKey()
        defaultModelId = defaults.string(forKey: Keys.defaultModelId) ?? ""
        powerAgentEnabled = defaults.object(forKey: Keys.powerAgentEnabled) as? Bool ?? true
        agentRequireWriteApproval = defaults.object(forKey: Keys.agentRequireWriteApproval) as? Bool ?? true
        agentGitHubToken = defaults.string(forKey: Keys.agentGitHubToken) ?? ""
        agentGitHubClientID = defaults.string(forKey: Keys.agentGitHubClientID) ?? ""
        agentGitHubRepository = defaults.string(forKey: Keys.agentGitHubRepository) ?? ""
        agentDefaultWorkspaceID = defaults.string(forKey: Keys.agentDefaultWorkspaceID) ?? ""
        agentGitHubDeviceCode = defaults.string(forKey: Keys.agentGitHubDeviceCode) ?? ""
        agentGitHubUserCode = defaults.string(forKey: Keys.agentGitHubUserCode) ?? ""
        agentGitHubVerificationURL = defaults.string(forKey: Keys.agentGitHubVerificationURL) ?? ""
        if let timestamp = defaults.object(forKey: Keys.agentGitHubDeviceFlowExpiresAt) as? Double {
            agentGitHubDeviceFlowExpiresAt = Date(timeIntervalSince1970: timestamp)
        } else {
            agentGitHubDeviceFlowExpiresAt = nil
        }
        agentBrowserHomeURL = defaults.string(forKey: Keys.agentBrowserHomeURL) ?? "https://github.com"
        agentBrowserLastURL = defaults.string(forKey: Keys.agentBrowserLastURL) ?? ""
        agentBundleExpertMode = defaults.object(forKey: Keys.agentBundleExpertMode) as? Bool ?? false
        agentModelCapabilityOverrides = Self.loadCodable(
            [String: ModelAgentCapabilityOverride].self,
            for: Keys.agentModelCapabilityOverrides,
            defaults: defaults
        ) ?? [:]

        enforcePublicServerSecurity()
    }

    var localServerURL: String {
        "http://127.0.0.1:\(serverPort)"
    }

    var buildVariant: AppBuildVariant {
        AppBuildVariant.current
    }

    var isJailbreakBuild: Bool {
        buildVariant == .jailbreak
    }

    var allowExternalConnections: Bool {
        serverExposureMode.allowsRemoteConnections
    }

    var normalizedPublicBaseURL: String? {
        Self.sanitizedPublicBaseURL(from: publicBaseURL)
    }

    var normalizedManagedRelayBaseURL: String? {
        Self.sanitizedPublicBaseURL(from: managedRelayBaseURL)
    }

    var publicServerURL: String {
        switch serverExposureMode {
        case .publicManaged:
            return managedRelayAssignedURL.trimmedForLookup
        case .publicCustom:
            return normalizedPublicBaseURL ?? publicBaseURL.trimmedForLookup
        case .localOnly, .localNetwork:
            return ""
        }
    }

    var isAPIKeyRequiredForCurrentExposure: Bool {
        serverExposureMode.isPublic || requireApiKey
    }

    var serverURL: String {
        switch serverExposureMode {
        case .publicManaged:
            return managedRelayAssignedURL.trimmedForLookup.nonEmpty ?? localServerURL
        case .publicCustom:
            return normalizedPublicBaseURL ?? localServerURL
        case .localOnly, .localNetwork:
            return localServerURL
        }
    }

    var isGitHubAgentConfigured: Bool {
        agentGitHubRepository.nonEmpty != nil
    }

    var hasPendingGitHubDeviceFlow: Bool {
        agentGitHubDeviceCode.nonEmpty != nil &&
        (agentGitHubDeviceFlowExpiresAt ?? .distantPast) > .now
    }

    func agentCapabilityOverride(for catalogId: String) -> ModelAgentCapabilityOverride? {
        agentModelCapabilityOverrides[catalogId]
    }

    func setAgentCapabilityOverride(_ override: ModelAgentCapabilityOverride?, for catalogId: String) {
        let normalizedCatalogId = catalogId.trimmedForLookup
        guard !normalizedCatalogId.isEmpty else { return }

        if let override, !override.isEmpty {
            agentModelCapabilityOverrides[normalizedCatalogId] = override
        } else {
            agentModelCapabilityOverrides.removeValue(forKey: normalizedCatalogId)
        }
    }

    func resetToDefaults() {
        defaultTemperature = 0.7
        defaultTopP = 0.9
        defaultTopK = 40
        defaultRepeatPenalty = 1.1
        defaultRepeatLastN = 64
        defaultContextLength = 4096
        maxTokens = 1024

        threads = max(ProcessInfo.processInfo.processorCount - 1, 1)
        batchSize = 512
        gpuLayers = 0
        flashAttentionEnabled = false
        mmapEnabled = true
        mlockEnabled = false
        turboQuantMode = .disabled
        kvCacheTypeK = .float16
        kvCacheTypeV = .float16
        keepModelInMemory = false
        autoOffloadMinutes = 5

        huggingFaceToken = ""

        darkMode = true
        hapticFeedback = true
        showTokenCount = true
        showGenerationSpeed = true
        markdownRendering = true
        streamingEnabled = true

        serverEnabled = false
        serverPort = 11434
        serverExposureMode = .localOnly
        publicBaseURL = ""
        managedRelayBaseURL = ""
        managedRelayDeviceID = UUID().uuidString.lowercased()
        managedRelayAccessToken = ""
        managedRelayAssignedURL = ""
        managedRelayWebSocketURL = ""
        requireApiKey = false
        apiKey = Self.generatedAPIKey()
        defaultModelId = ""
        powerAgentEnabled = true
        agentRequireWriteApproval = true
        agentGitHubToken = ""
        agentGitHubClientID = ""
        agentGitHubRepository = ""
        agentDefaultWorkspaceID = ""
        agentGitHubDeviceCode = ""
        agentGitHubUserCode = ""
        agentGitHubVerificationURL = ""
        agentGitHubDeviceFlowExpiresAt = nil
        agentBrowserHomeURL = "https://github.com"
        agentBrowserLastURL = ""
        agentBundleExpertMode = false
        agentModelCapabilityOverrides = [:]
    }

    private func save(_ value: Any?, for key: String) {
        defaults.set(value, forKey: key)
    }

    private func saveCodable<T: Encodable>(_ value: T, for key: String) {
        if let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: key)
        }
    }

    private static func loadCodable<T: Decodable>(_ type: T.Type, for key: String, defaults: UserDefaults) -> T? {
        guard let data = defaults.data(forKey: key) else {
            return nil
        }

        return try? JSONDecoder().decode(type, from: data)
    }

    private func enforcePublicServerSecurity() {
        guard serverExposureMode.isPublic else { return }

        if serverExposureMode == .publicCustom && publicBaseURL.trimmedForLookup.isEmpty {
            save("", for: Keys.publicBaseURL)
        }

        if !requireApiKey {
            requireApiKey = true
        }

        if apiKey.trimmedForLookup.isEmpty {
            apiKey = Self.generatedAPIKey()
        }
    }

    func clearManagedRelaySession() {
        managedRelayAccessToken = ""
        managedRelayAssignedURL = ""
        managedRelayWebSocketURL = ""
    }

    private static func generatedAPIKey() -> String {
        String(UUID().uuidString.prefix(16)).uppercased()
    }

    private static func sanitizedPublicBaseURL(from rawValue: String) -> String? {
        let trimmed = rawValue.trimmedForLookup
        guard !trimmed.isEmpty else { return nil }

        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host?.nonEmpty != nil
        else {
            return nil
        }

        components.path = components.path == "/" ? "" : components.path
        components.query = nil
        components.fragment = nil
        return components.string?.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private enum Keys {
        static let defaultTemperature = "defaultTemperature"
        static let defaultTopP = "defaultTopP"
        static let defaultTopK = "defaultTopK"
        static let defaultRepeatPenalty = "defaultRepeatPenalty"
        static let defaultRepeatLastN = "defaultRepeatLastN"
        static let defaultContextLength = "defaultContextLength"
        static let maxTokens = "maxTokens"

        static let threads = "threads"
        static let batchSize = "batchSize"
        static let gpuLayers = "gpuLayers"
        static let flashAttentionEnabled = "flashAttentionEnabled"
        static let mmapEnabled = "mmapEnabled"
        static let mlockEnabled = "mlockEnabled"
        static let turboQuantMode = "turboQuantMode"
        static let kvCacheTypeK = "kvCacheTypeK"
        static let kvCacheTypeV = "kvCacheTypeV"
        static let keepModelInMemory = "keepModelInMemory"
        static let autoOffloadMinutes = "autoOffloadMinutes"

        static let huggingFaceToken = "huggingFaceToken"

        static let darkMode = "darkMode"
        static let hapticFeedback = "hapticFeedback"
        static let showTokenCount = "showTokenCount"
        static let showGenerationSpeed = "showGenerationSpeed"
        static let markdownRendering = "markdownRendering"
        static let streamingEnabled = "streamingEnabled"

        static let serverEnabled = "serverEnabled"
        static let serverPort = "serverPort"
        static let allowExternalConnections = "allowExternalConnections"
        static let serverExposureMode = "serverExposureMode"
        static let publicBaseURL = "publicBaseURL"
        static let managedRelayBaseURL = "managedRelayBaseURL"
        static let managedRelayDeviceID = "managedRelayDeviceID"
        static let managedRelayAccessToken = "managedRelayAccessToken"
        static let managedRelayAssignedURL = "managedRelayAssignedURL"
        static let managedRelayWebSocketURL = "managedRelayWebSocketURL"
        static let requireApiKey = "requireApiKey"
        static let apiKey = "apiKey"
        static let defaultModelId = "defaultModelId"
        static let powerAgentEnabled = "powerAgentEnabled"
        static let agentRequireWriteApproval = "agentRequireWriteApproval"
        static let agentGitHubToken = "agentGitHubToken"
        static let agentGitHubClientID = "agentGitHubClientID"
        static let agentGitHubRepository = "agentGitHubRepository"
        static let agentDefaultWorkspaceID = "agentDefaultWorkspaceID"
        static let agentGitHubDeviceCode = "agentGitHubDeviceCode"
        static let agentGitHubUserCode = "agentGitHubUserCode"
        static let agentGitHubVerificationURL = "agentGitHubVerificationURL"
        static let agentGitHubDeviceFlowExpiresAt = "agentGitHubDeviceFlowExpiresAt"
        static let agentBrowserHomeURL = "agentBrowserHomeURL"
        static let agentBrowserLastURL = "agentBrowserLastURL"
        static let agentBundleExpertMode = "agentBundleExpertMode"
        static let agentModelCapabilityOverrides = "agentModelCapabilityOverrides"
    }
}
