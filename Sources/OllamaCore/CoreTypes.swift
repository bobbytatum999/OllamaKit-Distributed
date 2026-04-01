import Foundation

#if canImport(UIKit)
import UIKit
#endif

public enum ModelBackendKind: String, Codable, CaseIterable, Sendable {
    case ggufLlama = "gguf_llama"
    case coreMLPackage = "coreml_package"
    case appleFoundation = "apple_foundation"
}

public enum AppBuildVariant: String, Codable, CaseIterable, Identifiable, Sendable {
    case stockSideload
    case jailbreak

    public static let infoDictionaryKey = "OllamaKitBuildVariant"
    public static let environmentKey = "OLLAMAKIT_BUILD_VARIANT"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .stockSideload:
            return "Stock Sideload"
        case .jailbreak:
            return "Jailbreak"
        }
    }

    public var allowsLiveBundleWorkspace: Bool {
        self == .jailbreak
    }

    public var artifactSuffix: String {
        rawValue
    }

    public static func resolve(
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> AppBuildVariant {
        if let rawValue = environment[Self.environmentKey] ?? infoDictionary?[Self.infoDictionaryKey] as? String,
           let variant = Self(rawValue: rawValue.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return variant
        }

        #if OLLAMAKIT_VARIANT_JAILBREAK
        return .jailbreak
        #else
        return .stockSideload
        #endif
    }

    public static var current: AppBuildVariant {
        resolve()
    }
}

public enum ModelImportSource: String, Codable, CaseIterable, Sendable {
    case builtIn
    case huggingFaceDownload
    case localImport
    case coreMLImport
    case migratedLegacy
}

public enum ModelCompatibilityLevel: String, Codable, CaseIterable, Sendable {
    case recommended
    case supported
    case unavailable
    case unknown

    public var isUsable: Bool {
        switch self {
        case .recommended, .supported:
            return true
        case .unavailable, .unknown:
            return false
        }
    }
}

public enum ModelValidationStatus: String, Codable, CaseIterable, Sendable {
    case unknown
    case pending
    case validated
    case failed

    public var isRunnable: Bool {
        self == .validated
    }
}

public enum DeviceInterfaceKind: String, Codable, CaseIterable, Sendable {
    case phone
    case pad
    case mac
    case other
}

public enum ServerSupportedRoute: String, Codable, CaseIterable, Hashable, Sendable {
    case apiTags = "/api/tags"
    case apiShow = "/api/show"
    case apiGenerate = "/api/generate"
    case apiChat = "/api/chat"
    case apiEmbed = "/api/embed"
    case apiPull = "/api/pull"
    case apiDelete = "/api/delete"
    case apiPS = "/api/ps"
    case v1Models = "/v1/models"
    case v1Completions = "/v1/completions"
    case v1ChatCompletions = "/v1/chat/completions"
    case v1Embeddings = "/v1/embeddings"
    case v1Responses = "/v1/responses"
}

public struct ServerModelCapabilities: Codable, Hashable, Sendable {
    public var textGeneration: Bool
    public var chat: Bool
    public var streaming: Bool
    public var embeddings: Bool
    public var toolCalling: Bool
    public var reasoningControls: Bool
    public var imageInput: Bool
    public var audioInput: Bool
    public var videoInput: Bool
    public var multilingual: Bool
    public var supportedRoutes: [ServerSupportedRoute]

    public init(
        textGeneration: Bool = false,
        chat: Bool = false,
        streaming: Bool = false,
        embeddings: Bool = false,
        toolCalling: Bool = false,
        reasoningControls: Bool = false,
        imageInput: Bool = false,
        audioInput: Bool = false,
        videoInput: Bool = false,
        multilingual: Bool = false,
        supportedRoutes: [ServerSupportedRoute] = []
    ) {
        self.textGeneration = textGeneration
        self.chat = chat
        self.streaming = streaming
        self.embeddings = embeddings
        self.toolCalling = toolCalling
        self.reasoningControls = reasoningControls
        self.imageInput = imageInput
        self.audioInput = audioInput
        self.videoInput = videoInput
        self.multilingual = multilingual
        self.supportedRoutes = supportedRoutes
    }

    public static func conservativeDefaults(
        backendKind: ModelBackendKind,
        sourceModelID: String,
        displayName: String,
        capabilitySummary: ModelCapabilitySummary,
        hintedMultilingual: Bool = false
    ) -> ServerModelCapabilities {
        let signals = [sourceModelID, displayName, capabilitySummary.notes ?? ""]
            .joined(separator: " ")
            .lowercased()

        let looksLikeEmbeddingModel = ["embedding", "feature-extraction", "rerank", "retrieval"]
            .contains { signals.contains($0) }

        let embeddings = looksLikeEmbeddingModel
        let textGeneration = !looksLikeEmbeddingModel
        let chat = textGeneration
        let streaming = textGeneration && capabilitySummary.supportsStreaming
        let multilingual = hintedMultilingual || signals.contains("multilingual")

        var supportedRoutes: [ServerSupportedRoute] = [
            .apiShow,
            .apiPull,
            .apiDelete,
            .apiPS,
            .apiTags,
            .v1Models
        ]

        if textGeneration {
            supportedRoutes.append(contentsOf: [
                .apiGenerate,
                .apiChat,
                .v1Completions,
                .v1ChatCompletions,
                .v1Responses
            ])
        }

        if embeddings {
            supportedRoutes.append(contentsOf: [
                .apiEmbed,
                .v1Embeddings
            ])
        }

        return ServerModelCapabilities(
            textGeneration: textGeneration,
            chat: chat,
            streaming: streaming,
            embeddings: embeddings,
            toolCalling: false,
            reasoningControls: false,
            imageInput: false,
            audioInput: false,
            videoInput: false,
            multilingual: multilingual,
            supportedRoutes: supportedRoutes
        )
    }
}

public enum AgentToolCapabilityKey: String, Codable, CaseIterable, Hashable, Sendable {
    case browserRead = "browser_read"
    case browserActions = "browser_actions"
    case internetRead = "internet_read"
    case internetWrite = "internet_write"
    case workspaceRead = "workspace_read"
    case workspaceWrite = "workspace_write"
    case codeTools = "code_tools"
    case jsRuntime = "js_runtime"
    case pythonRuntime = "python_runtime"
    case nodeRuntime = "node_runtime"
    case swiftRuntime = "swift_runtime"
    case gitRead = "git_read"
    case gitWrite = "git_write"
    case githubAccess = "github_access"
    case remoteCI = "remote_ci"
    case managedRelayAccess = "managed_relay_access"
    case bundleEdits = "bundle_edits"
}

public enum ManagedRelayConnectionState: String, Codable, CaseIterable, Hashable, Sendable {
    case disconnected
    case registering
    case connecting
    case connected
    case error
}

public struct ManagedPublicEndpoint: Codable, Hashable, Sendable {
    public var serviceBaseURL: String
    public var assignedURL: String
    public var websocketURL: String

    public init(
        serviceBaseURL: String = "",
        assignedURL: String = "",
        websocketURL: String = ""
    ) {
        self.serviceBaseURL = serviceBaseURL
        self.assignedURL = assignedURL
        self.websocketURL = websocketURL
    }
}

public struct RelayAuthToken: Codable, Hashable, Sendable {
    public var value: String
    public var issuedAt: Date?
    public var expiresAt: Date?

    public init(value: String = "", issuedAt: Date? = nil, expiresAt: Date? = nil) {
        self.value = value
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
    }
}

public struct ModelAgentCapabilityOverride: Codable, Hashable, Sendable {
    public var browserRead: Bool?
    public var browserActions: Bool?
    public var internetRead: Bool?
    public var internetWrite: Bool?
    public var workspaceRead: Bool?
    public var workspaceWrite: Bool?
    public var codeTools: Bool?
    public var jsRuntime: Bool?
    public var pythonRuntime: Bool?
    public var nodeRuntime: Bool?
    public var swiftRuntime: Bool?
    public var gitRead: Bool?
    public var gitWrite: Bool?
    public var githubAccess: Bool?
    public var remoteCI: Bool?
    public var managedRelayAccess: Bool?
    public var bundleEdits: Bool?

    public init(
        browserRead: Bool? = nil,
        browserActions: Bool? = nil,
        internetRead: Bool? = nil,
        internetWrite: Bool? = nil,
        workspaceRead: Bool? = nil,
        workspaceWrite: Bool? = nil,
        codeTools: Bool? = nil,
        jsRuntime: Bool? = nil,
        pythonRuntime: Bool? = nil,
        nodeRuntime: Bool? = nil,
        swiftRuntime: Bool? = nil,
        gitRead: Bool? = nil,
        gitWrite: Bool? = nil,
        githubAccess: Bool? = nil,
        remoteCI: Bool? = nil,
        managedRelayAccess: Bool? = nil,
        bundleEdits: Bool? = nil
    ) {
        self.browserRead = browserRead
        self.browserActions = browserActions
        self.internetRead = internetRead
        self.internetWrite = internetWrite
        self.workspaceRead = workspaceRead
        self.workspaceWrite = workspaceWrite
        self.codeTools = codeTools
        self.jsRuntime = jsRuntime
        self.pythonRuntime = pythonRuntime
        self.nodeRuntime = nodeRuntime
        self.swiftRuntime = swiftRuntime
        self.gitRead = gitRead
        self.gitWrite = gitWrite
        self.githubAccess = githubAccess
        self.remoteCI = remoteCI
        self.managedRelayAccess = managedRelayAccess
        self.bundleEdits = bundleEdits
    }

    public var isEmpty: Bool {
        AgentToolCapabilityKey.allCases.allSatisfy { value(for: $0) == nil }
    }

    public func value(for capability: AgentToolCapabilityKey) -> Bool? {
        switch capability {
        case .browserRead:
            return browserRead
        case .browserActions:
            return browserActions
        case .internetRead:
            return internetRead
        case .internetWrite:
            return internetWrite
        case .workspaceRead:
            return workspaceRead
        case .workspaceWrite:
            return workspaceWrite
        case .codeTools:
            return codeTools
        case .jsRuntime:
            return jsRuntime
        case .pythonRuntime:
            return pythonRuntime
        case .nodeRuntime:
            return nodeRuntime
        case .swiftRuntime:
            return swiftRuntime
        case .gitRead:
            return gitRead
        case .gitWrite:
            return gitWrite
        case .githubAccess:
            return githubAccess
        case .remoteCI:
            return remoteCI
        case .managedRelayAccess:
            return managedRelayAccess
        case .bundleEdits:
            return bundleEdits
        }
    }

    public func setting(_ value: Bool?, for capability: AgentToolCapabilityKey) -> ModelAgentCapabilityOverride {
        var copy = self
        switch capability {
        case .browserRead:
            copy.browserRead = value
        case .browserActions:
            copy.browserActions = value
        case .internetRead:
            copy.internetRead = value
        case .internetWrite:
            copy.internetWrite = value
        case .workspaceRead:
            copy.workspaceRead = value
        case .workspaceWrite:
            copy.workspaceWrite = value
        case .codeTools:
            copy.codeTools = value
        case .jsRuntime:
            copy.jsRuntime = value
        case .pythonRuntime:
            copy.pythonRuntime = value
        case .nodeRuntime:
            copy.nodeRuntime = value
        case .swiftRuntime:
            copy.swiftRuntime = value
        case .gitRead:
            copy.gitRead = value
        case .gitWrite:
            copy.gitWrite = value
        case .githubAccess:
            copy.githubAccess = value
        case .remoteCI:
            copy.remoteCI = value
        case .managedRelayAccess:
            copy.managedRelayAccess = value
        case .bundleEdits:
            copy.bundleEdits = value
        }
        return copy
    }
}

public struct ModelAgentCapabilityProfile: Codable, Hashable, Sendable {
    public var browserRead: Bool
    public var browserActions: Bool
    public var internetRead: Bool
    public var internetWrite: Bool
    public var workspaceRead: Bool
    public var workspaceWrite: Bool
    public var codeTools: Bool
    public var jsRuntime: Bool
    public var pythonRuntime: Bool
    public var nodeRuntime: Bool
    public var swiftRuntime: Bool
    public var gitRead: Bool
    public var gitWrite: Bool
    public var githubAccess: Bool
    public var remoteCI: Bool
    public var managedRelayAccess: Bool
    public var bundleEdits: Bool

    public init(
        browserRead: Bool = false,
        browserActions: Bool = false,
        internetRead: Bool = false,
        internetWrite: Bool = false,
        workspaceRead: Bool = false,
        workspaceWrite: Bool = false,
        codeTools: Bool = false,
        jsRuntime: Bool = false,
        pythonRuntime: Bool = false,
        nodeRuntime: Bool = false,
        swiftRuntime: Bool = false,
        gitRead: Bool = false,
        gitWrite: Bool = false,
        githubAccess: Bool = false,
        remoteCI: Bool = false,
        managedRelayAccess: Bool = false,
        bundleEdits: Bool = false
    ) {
        self.browserRead = browserRead
        self.browserActions = browserActions
        self.internetRead = internetRead
        self.internetWrite = internetWrite
        self.workspaceRead = workspaceRead
        self.workspaceWrite = workspaceWrite
        self.codeTools = codeTools
        self.jsRuntime = jsRuntime
        self.pythonRuntime = pythonRuntime
        self.nodeRuntime = nodeRuntime
        self.swiftRuntime = swiftRuntime
        self.gitRead = gitRead
        self.gitWrite = gitWrite
        self.githubAccess = githubAccess
        self.remoteCI = remoteCI
        self.managedRelayAccess = managedRelayAccess
        self.bundleEdits = bundleEdits
    }

    public func supports(_ capability: AgentToolCapabilityKey) -> Bool {
        switch capability {
        case .browserRead:
            return browserRead
        case .browserActions:
            return browserActions
        case .internetRead:
            return internetRead
        case .internetWrite:
            return internetWrite
        case .workspaceRead:
            return workspaceRead
        case .workspaceWrite:
            return workspaceWrite
        case .codeTools:
            return codeTools
        case .jsRuntime:
            return jsRuntime
        case .pythonRuntime:
            return pythonRuntime
        case .nodeRuntime:
            return nodeRuntime
        case .swiftRuntime:
            return swiftRuntime
        case .gitRead:
            return gitRead
        case .gitWrite:
            return gitWrite
        case .githubAccess:
            return githubAccess
        case .remoteCI:
            return remoteCI
        case .managedRelayAccess:
            return managedRelayAccess
        case .bundleEdits:
            return bundleEdits
        }
    }

    public func setting(_ value: Bool, for capability: AgentToolCapabilityKey) -> ModelAgentCapabilityProfile {
        var copy = self
        switch capability {
        case .browserRead:
            copy.browserRead = value
        case .browserActions:
            copy.browserActions = value
        case .internetRead:
            copy.internetRead = value
        case .internetWrite:
            copy.internetWrite = value
        case .workspaceRead:
            copy.workspaceRead = value
        case .workspaceWrite:
            copy.workspaceWrite = value
        case .codeTools:
            copy.codeTools = value
        case .jsRuntime:
            copy.jsRuntime = value
        case .pythonRuntime:
            copy.pythonRuntime = value
        case .nodeRuntime:
            copy.nodeRuntime = value
        case .swiftRuntime:
            copy.swiftRuntime = value
        case .gitRead:
            copy.gitRead = value
        case .gitWrite:
            copy.gitWrite = value
        case .githubAccess:
            copy.githubAccess = value
        case .remoteCI:
            copy.remoteCI = value
        case .managedRelayAccess:
            copy.managedRelayAccess = value
        case .bundleEdits:
            copy.bundleEdits = value
        }
        return copy
    }

    public func applying(_ override: ModelAgentCapabilityOverride?) -> ModelAgentCapabilityProfile {
        guard let override else { return self }

        var copy = self
        for capability in AgentToolCapabilityKey.allCases {
            if let value = override.value(for: capability) {
                copy = copy.setting(value, for: capability)
            }
        }
        return copy
    }

    public static func conservativeDefaults(
        backendKind: ModelBackendKind,
        sourceModelID: String,
        displayName: String,
        capabilitySummary: ModelCapabilitySummary,
        serverCapabilities: ServerModelCapabilities? = nil
    ) -> ModelAgentCapabilityProfile {
        let signals = [sourceModelID, displayName, capabilitySummary.notes ?? ""]
            .joined(separator: " ")
            .lowercased()

        let signalTerms = Set(signals.split { !$0.isLetter && !$0.isNumber }.map(String.init))
        let containsAny: (Set<String>) -> Bool = { needles in
            !signalTerms.isDisjoint(with: needles) || needles.contains { signals.contains($0) }
        }

        let embeddingSignals: Set<String> = [
            "embedding", "embeddings", "rerank", "retrieval", "feature-extraction",
            "featureextraction", "sentence-similarity", "similarity"
        ]
        let codingSignals: Set<String> = [
            "code", "coder", "coding", "programmer", "programming", "devstral",
            "codestral", "starcoder", "deepseek-coder", "qwen2.5-coder", "swift"
        ]
        let conversationalSignals: Set<String> = [
            "chat", "instruct", "assistant", "conversation", "conversational"
        ]
        let agentSignals: Set<String> = [
            "agent", "tool", "tools", "function", "browser", "search", "web"
        ]

        let looksLikeEmbedding = serverCapabilities?.embeddings == true || containsAny(embeddingSignals)
        let looksConversational = serverCapabilities?.chat == true || containsAny(conversationalSignals)
        let looksGenerative = !looksLikeEmbedding && (serverCapabilities?.textGeneration == true || looksConversational || backendKind == .appleFoundation)
        let looksCoder = containsAny(codingSignals)
        let looksAgentic = serverCapabilities?.toolCalling == true || containsAny(agentSignals)

        guard looksGenerative else {
            return ModelAgentCapabilityProfile()
        }

        let readResearch = looksConversational || looksCoder || backendKind == .appleFoundation || looksAgentic
        let allowCode = looksCoder || looksConversational || backendKind == .appleFoundation
        let allowWrites = looksConversational || looksCoder || backendKind == .appleFoundation
        let allowNetworkWrites = looksCoder || looksAgentic
        let allowGitWrites = looksCoder || looksAgentic
        let allowRemoteCI = looksCoder || looksAgentic || backendKind == .appleFoundation
        let allowSwiftRuntime = looksCoder || backendKind == .appleFoundation
        let allowManagedRelay = allowNetworkWrites || looksConversational

        return ModelAgentCapabilityProfile(
            browserRead: readResearch,
            browserActions: allowNetworkWrites,
            internetRead: readResearch,
            internetWrite: allowNetworkWrites,
            workspaceRead: true,
            workspaceWrite: allowWrites,
            codeTools: allowCode,
            jsRuntime: allowCode,
            pythonRuntime: allowCode,
            nodeRuntime: looksCoder,
            swiftRuntime: allowSwiftRuntime,
            gitRead: allowCode,
            gitWrite: allowGitWrites,
            githubAccess: readResearch,
            remoteCI: allowRemoteCI,
            managedRelayAccess: allowManagedRelay,
            bundleEdits: false
        )
    }
}

public struct ModelCapabilitySummary: Codable, Hashable, Sendable {
    public var sizeBytes: Int64
    public var quantization: String
    public var parameterCountLabel: String
    public var contextLength: Int
    public var supportsStreaming: Bool
    public var notes: String?

    public init(
        sizeBytes: Int64 = 0,
        quantization: String = "Unknown",
        parameterCountLabel: String = "Unknown",
        contextLength: Int = 4096,
        supportsStreaming: Bool = true,
        notes: String? = nil
    ) {
        self.sizeBytes = sizeBytes
        self.quantization = quantization
        self.parameterCountLabel = parameterCountLabel
        self.contextLength = contextLength
        self.supportsStreaming = supportsStreaming
        self.notes = notes
    }
}

public struct ModelPackageFile: Codable, Hashable, Sendable {
    public let path: String
    public let sha256: String
    public let sizeBytes: Int64?

    public init(path: String, sha256: String, sizeBytes: Int64?) {
        self.path = path
        self.sha256 = sha256
        self.sizeBytes = sizeBytes
    }
}

public struct ModelPackageManifest: Codable, Hashable, Sendable {
    public static let currentFormatVersion = 1

    public var formatVersion: Int
    public var modelId: String
    public var displayName: String
    public var backendKind: ModelBackendKind
    public var minimumOSVersion: String?
    public var capabilitySummary: ModelCapabilitySummary
    public var serverCapabilities: ServerModelCapabilities?
    public var files: [ModelPackageFile]

    public init(
        formatVersion: Int = ModelPackageManifest.currentFormatVersion,
        modelId: String,
        displayName: String,
        backendKind: ModelBackendKind,
        minimumOSVersion: String? = nil,
        capabilitySummary: ModelCapabilitySummary,
        serverCapabilities: ServerModelCapabilities? = nil,
        files: [ModelPackageFile]
    ) {
        self.formatVersion = formatVersion
        self.modelId = modelId
        self.displayName = displayName
        self.backendKind = backendKind
        self.minimumOSVersion = minimumOSVersion
        self.capabilitySummary = capabilitySummary
        self.serverCapabilities = serverCapabilities
        self.files = files
    }
}

public struct ModelCatalogEntry: Codable, Hashable, Identifiable, Sendable {
    public let catalogId: String
    public var sourceModelID: String
    public var displayName: String
    public var serverIdentifier: String
    public let backendKind: ModelBackendKind
    public var localPath: String?
    public var packageRootPath: String?
    public var manifestPath: String?
    public var importSource: ModelImportSource
    public var isServerExposed: Bool
    public var validationStatus: ModelValidationStatus?
    public var validationMessage: String?
    public var validatedAt: Date?
    public var aliases: [String]
    public var capabilitySummary: ModelCapabilitySummary
    public var serverCapabilities: ServerModelCapabilities?
    public var createdAt: Date
    public var updatedAt: Date

    public var id: String { catalogId }

    public init(
        catalogId: String,
        sourceModelID: String,
        displayName: String,
        serverIdentifier: String,
        backendKind: ModelBackendKind,
        localPath: String? = nil,
        packageRootPath: String? = nil,
        manifestPath: String? = nil,
        importSource: ModelImportSource,
        isServerExposed: Bool = true,
        validationStatus: ModelValidationStatus? = nil,
        validationMessage: String? = nil,
        validatedAt: Date? = nil,
        aliases: [String] = [],
        capabilitySummary: ModelCapabilitySummary,
        serverCapabilities: ServerModelCapabilities? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.catalogId = catalogId
        self.sourceModelID = sourceModelID
        self.displayName = displayName
        self.serverIdentifier = serverIdentifier
        self.backendKind = backendKind
        self.localPath = localPath
        self.packageRootPath = packageRootPath
        self.manifestPath = manifestPath
        self.importSource = importSource
        self.isServerExposed = isServerExposed
        self.validationStatus = validationStatus
        self.validationMessage = validationMessage
        self.validatedAt = validatedAt
        self.aliases = aliases
        self.capabilitySummary = capabilitySummary
        self.serverCapabilities = serverCapabilities
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var isBuiltInAppleModel: Bool {
        catalogId == SystemModelCatalog.appleFoundationCatalogID
    }

    public var localFileURL: URL? {
        guard let localPath, !localPath.isEmpty else { return nil }
        return URL(fileURLWithPath: localPath)
    }

    public var packageRootURL: URL? {
        guard let packageRootPath, !packageRootPath.isEmpty else { return nil }
        return URL(fileURLWithPath: packageRootPath)
    }

    public var manifestURL: URL? {
        guard let manifestPath, !manifestPath.isEmpty else { return nil }
        return URL(fileURLWithPath: manifestPath)
    }

    public var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: capabilitySummary.sizeBytes, countStyle: .file)
    }

    public var runtimeContextLength: Int {
        max(capabilitySummary.contextLength, 512)
    }

    public var effectiveValidationStatus: ModelValidationStatus {
        if let validationStatus {
            return validationStatus
        }

        switch backendKind {
        case .ggufLlama:
            return .unknown
        case .coreMLPackage, .appleFoundation:
            return .validated
        }
    }

    public var isValidatedRunnable: Bool {
        switch backendKind {
        case .ggufLlama:
            guard effectiveValidationStatus.isRunnable, let localFileURL else { return false }
            return FileManager.default.fileExists(atPath: localFileURL.path)
        case .coreMLPackage:
            return CoreMLPackageLocator.looksRunnable(packageRootPath: packageRootPath)
        case .appleFoundation:
            return effectiveValidationStatus.isRunnable
        }
    }

    public var isServerRunnable: Bool {
        isServerExposed && isValidatedRunnable
    }

    public var effectiveServerCapabilities: ServerModelCapabilities {
        serverCapabilities
            ?? ServerModelCapabilities.conservativeDefaults(
                backendKind: backendKind,
                sourceModelID: sourceModelID,
                displayName: displayName,
                capabilitySummary: capabilitySummary
            )
    }

    public func matchesReference(_ candidate: String) -> Bool {
        allReferenceTokens().contains(candidate.trimmedForLookup.lowercased())
    }

    public func allReferenceTokens() -> [String] {
        let rawValues = [
            catalogId,
            sourceModelID,
            displayName,
            serverIdentifier,
            localPath
        ] + aliases

        var deduplicated: [String] = []
        var seen = Set<String>()

        for rawValue in rawValues {
            let normalized = rawValue?.trimmedForLookup.lowercased() ?? ""
            guard !normalized.isEmpty, !seen.contains(normalized) else { continue }
            seen.insert(normalized)
            deduplicated.append(normalized)
        }

        return deduplicated
    }
}

public struct LegacyDownloadedModelSeed: Sendable {
    public let name: String
    public let modelId: String
    public let localPath: String
    public let size: Int64
    public let downloadDate: Date
    public let isDownloaded: Bool
    public let quantization: String
    public let parameters: String
    public let contextLength: Int

    public init(
        name: String,
        modelId: String,
        localPath: String,
        size: Int64,
        downloadDate: Date,
        isDownloaded: Bool,
        quantization: String,
        parameters: String,
        contextLength: Int
    ) {
        self.name = name
        self.modelId = modelId
        self.localPath = localPath
        self.size = size
        self.downloadDate = downloadDate
        self.isDownloaded = isDownloaded
        self.quantization = quantization
        self.parameters = parameters
        self.contextLength = contextLength
    }
}

public struct RuntimePreferences: Hashable, Sendable {
    public var contextLength: Int
    public var gpuLayers: Int
    public var threads: Int
    public var batchSize: Int
    public var flashAttentionEnabled: Bool
    public var mmapEnabled: Bool
    public var mlockEnabled: Bool
    public var keepModelInMemory: Bool
    public var autoOffloadMinutes: Int

    public init(
        contextLength: Int = 4096,
        gpuLayers: Int = 0,
        threads: Int = 1,
        batchSize: Int = 512,
        flashAttentionEnabled: Bool = false,
        mmapEnabled: Bool = true,
        mlockEnabled: Bool = false,
        keepModelInMemory: Bool = false,
        autoOffloadMinutes: Int = 5
    ) {
        self.contextLength = max(contextLength, 512)
        self.gpuLayers = max(gpuLayers, 0)
        self.threads = max(threads, 1)
        self.batchSize = max(batchSize, 32)
        self.flashAttentionEnabled = flashAttentionEnabled
        self.mmapEnabled = mmapEnabled
        self.mlockEnabled = mlockEnabled
        self.keepModelInMemory = keepModelInMemory
        self.autoOffloadMinutes = max(autoOffloadMinutes, 1)
    }

    public static func validationBaseline(contextLength: Int = 2048) -> RuntimePreferences {
        RuntimePreferences(
            contextLength: min(max(contextLength, 512), 2048),
            gpuLayers: 0,
            threads: max(min(ProcessInfo.processInfo.activeProcessorCount, 4), 1),
            batchSize: 128,
            flashAttentionEnabled: false,
            mmapEnabled: true,
            mlockEnabled: false,
            keepModelInMemory: false,
            autoOffloadMinutes: 1
        )
    }
}

public struct ModelValidationOutcome: Hashable, Sendable {
    public let status: ModelValidationStatus
    public let message: String?
    public let validatedAt: Date

    public init(
        status: ModelValidationStatus,
        message: String? = nil,
        validatedAt: Date = .now
    ) {
        self.status = status
        self.message = message?.trimmedForLookup.nonEmpty
        self.validatedAt = validatedAt
    }

    public var isRunnable: Bool {
        status.isRunnable
    }
}

public enum ConversationContentPartKind: String, Codable, CaseIterable, Sendable {
    case text
    case imageURL = "image_url"
    case audioURL = "audio_url"
    case videoURL = "video_url"
    case fileURL = "file_url"
}

public struct ConversationContentPart: Codable, Hashable, Sendable {
    public let kind: ConversationContentPartKind
    public let text: String?
    public let url: String?
    public let mimeType: String?
    public let detail: String?

    public init(
        kind: ConversationContentPartKind,
        text: String? = nil,
        url: String? = nil,
        mimeType: String? = nil,
        detail: String? = nil
    ) {
        self.kind = kind
        self.text = text?.trimmedForLookup.nonEmpty
        self.url = url?.trimmedForLookup.nonEmpty
        self.mimeType = mimeType?.trimmedForLookup.nonEmpty
        self.detail = detail?.trimmedForLookup.nonEmpty
    }

    public static func text(_ text: String) -> ConversationContentPart {
        ConversationContentPart(kind: .text, text: text)
    }

    public var isText: Bool {
        kind == .text
    }
}

public struct InferenceToolDefinition: Codable, Hashable, Sendable {
    public let name: String
    public let description: String?
    public let inputSchemaJSON: String?

    public init(name: String, description: String? = nil, inputSchemaJSON: String? = nil) {
        self.name = name.trimmedForLookup
        self.description = description?.trimmedForLookup.nonEmpty
        self.inputSchemaJSON = inputSchemaJSON?.trimmedForLookup.nonEmpty
    }
}

public struct InferenceReasoningOptions: Codable, Hashable, Sendable {
    public let effort: String?
    public let summary: String?

    public init(effort: String? = nil, summary: String? = nil) {
        self.effort = effort?.trimmedForLookup.nonEmpty
        self.summary = summary?.trimmedForLookup.nonEmpty
    }
}

public struct ConversationTurn: Codable, Hashable, Sendable {
    public let role: String
    public let content: String
    public let parts: [ConversationContentPart]?

    public init(role: String, content: String) {
        self.role = role
        self.content = content
        self.parts = content.trimmedForLookup.isEmpty ? nil : [.text(content)]
    }

    public init(role: String, parts: [ConversationContentPart]) {
        self.role = role
        self.parts = parts.isEmpty ? nil : parts
        self.content = parts
            .compactMap(\.text)
            .joined()
    }

    public var containsNonTextParts: Bool {
        parts?.contains(where: { !$0.isText }) ?? false
    }
}

public enum ConversationPrompting {
    public static let defaultChatStopSequences = [
        "User:",
        "\nUser:",
        "Assistant:",
        "\nAssistant:",
        "System:",
        "\nSystem:",
        "Human:",
        "\nHuman:",
        "Me:",
        "\nMe:",
        "Bot:",
        "\nBot:"
    ]

    public static let assistantGuardInstruction =
        "Reply with only the assistant's next message. Do not continue the conversation as the user. Do not include speaker labels such as User:, Assistant:, Human:, Me:, or Bot:."

    public static func normalizedTurns(_ turns: [ConversationTurn]) -> [ConversationTurn] {
        turns.compactMap { turn in
            let role = normalizedRole(for: turn.role)
            let content = turn.content.trimmedForLookup
            guard let role, !content.isEmpty else { return nil }
            return ConversationTurn(role: role, content: content)
        }
    }

    public static func guardedSystemPrompt(_ systemPrompt: String?, includeGuard: Bool) -> String? {
        let trimmedSystemPrompt = systemPrompt?.trimmedForLookup.nonEmpty
        guard includeGuard else {
            return trimmedSystemPrompt
        }

        return [trimmedSystemPrompt, assistantGuardInstruction]
            .compactMap { $0 }
            .joined(separator: "\n\n")
            .nonEmpty
    }

    public static func transcriptPrompt(
        systemPrompt: String?,
        turns: [ConversationTurn],
        appendAssistantCue: Bool
    ) -> String {
        let systemBlock = guardedSystemPrompt(systemPrompt, includeGuard: true)
            .map { "System:\n\($0)" }

        let conversation = normalizedTurns(turns)
            .compactMap { turn -> String? in
                switch turn.role {
                case "system":
                    return "System:\n\(turn.content)"
                case "assistant":
                    return "Assistant:\n\(turn.content)"
                case "user":
                    return "User:\n\(turn.content)"
                default:
                    return nil
                }
            }
            .joined(separator: "\n\n")
            .nonEmpty

        let assistantCue = appendAssistantCue ? "Assistant:\n" : nil

        return [systemBlock, conversation, assistantCue]
            .compactMap { $0 }
            .joined(separator: "\n\n")
            .nonEmpty ?? ""
    }

    public static func promptForAssistant(
        systemPrompt: String?,
        turns: [ConversationTurn]
    ) -> String {
        transcriptPrompt(
            systemPrompt: systemPrompt,
            turns: turns,
            appendAssistantCue: true
        )
    }

    public static func mergedStopSequences(_ stopSequences: [String], includeDefaultChatStops: Bool) -> [String] {
        let candidateStops = stopSequences + (includeDefaultChatStops ? defaultChatStopSequences : [])
        var deduplicated: [String] = []
        var seen = Set<String>()

        for stop in candidateStops {
            guard !stop.isEmpty, seen.insert(stop).inserted else { continue }
            deduplicated.append(stop)
        }

        return deduplicated
    }

    public static func visibleAssistantText(
        from rawText: String,
        stopSequences: [String]
    ) -> (visibleText: String, shouldStop: Bool) {
        let sanitizedText = stripLeadingAssistantLabels(from: rawText)
        guard !stopSequences.isEmpty else {
            return (sanitizedText, false)
        }

        let matches = stopSequences.compactMap { sequence in
            sanitizedText.range(of: sequence).map { range in
                (range, sequence)
            }
        }

        if let earliestMatch = matches.min(by: { lhs, rhs in
            lhs.0.lowerBound < rhs.0.lowerBound
        }) {
            return (String(sanitizedText[..<earliestMatch.0.lowerBound]), true)
        }

        let withheldCount = stopSequences.reduce(into: 0) { partialResult, sequence in
            let maxCandidateLength = min(sequence.count - 1, sanitizedText.count)
            guard maxCandidateLength > 0 else { return }

            for length in stride(from: maxCandidateLength, through: 1, by: -1) {
                let suffixStart = sanitizedText.index(sanitizedText.endIndex, offsetBy: -length)
                let suffix = String(sanitizedText[suffixStart...])
                if sequence.hasPrefix(suffix) {
                    partialResult = max(partialResult, length)
                    break
                }
            }
        }

        guard withheldCount > 0 else {
            return (sanitizedText, false)
        }

        let visibleEnd = sanitizedText.index(sanitizedText.endIndex, offsetBy: -withheldCount)
        return (String(sanitizedText[..<visibleEnd]), false)
    }

    public static func finalizedAssistantText(
        from rawText: String,
        stopSequences: [String]
    ) -> String {
        visibleAssistantText(from: rawText, stopSequences: stopSequences).visibleText.trimmedForLookup
    }

    private static func normalizedRole(for role: String) -> String? {
        switch role.trimmedForLookup.lowercased() {
        case "system", "developer":
            return "system"
        case "assistant", "bot":
            return "assistant"
        case "user", "human", "me":
            return "user"
        default:
            return nil
        }
    }

    private static func stripLeadingAssistantLabels(from text: String) -> String {
        var current = text

        while true {
            let trimmed = current.drop(while: { $0.isWhitespace })
            let lowered = trimmed.lowercased()

            if lowered.hasPrefix("assistant:") {
                current = String(trimmed.dropFirst("assistant:".count))
                continue
            }

            if lowered.hasPrefix("bot:") {
                current = String(trimmed.dropFirst("bot:".count))
                continue
            }

            return String(trimmed)
        }
    }
}

public struct SamplingParameters: Codable, Hashable, Sendable {
    public var temperature: Double
    public var topP: Double
    public var topK: Int
    public var repeatPenalty: Double
    public var repeatLastN: Int
    public var maxTokens: Int
    public var stopSequences: [String]

    public init(
        temperature: Double = 0.7,
        topP: Double = 0.9,
        topK: Int = 40,
        repeatPenalty: Double = 1.1,
        repeatLastN: Int = 64,
        maxTokens: Int = 1024,
        stopSequences: [String] = []
    ) {
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.repeatPenalty = repeatPenalty
        self.repeatLastN = repeatLastN
        self.maxTokens = maxTokens
        self.stopSequences = stopSequences
    }

    public static var `default`: SamplingParameters {
        SamplingParameters()
    }
}

public struct InferenceRequest: Sendable {
    public let catalogId: String
    public let prompt: String
    public let systemPrompt: String?
    public let conversationTurns: [ConversationTurn]
    public let tools: [InferenceToolDefinition]
    public let reasoning: InferenceReasoningOptions?
    public let parameters: SamplingParameters
    public let runtimePreferences: RuntimePreferences

    public init(
        catalogId: String,
        prompt: String,
        systemPrompt: String? = nil,
        conversationTurns: [ConversationTurn] = [],
        tools: [InferenceToolDefinition] = [],
        reasoning: InferenceReasoningOptions? = nil,
        parameters: SamplingParameters = .default,
        runtimePreferences: RuntimePreferences
    ) {
        self.catalogId = catalogId
        self.prompt = prompt
        self.systemPrompt = systemPrompt
        self.conversationTurns = conversationTurns
        self.tools = tools
        self.reasoning = reasoning
        self.parameters = parameters
        self.runtimePreferences = runtimePreferences
    }

    public var isChatRequest: Bool {
        !conversationTurns.isEmpty
    }

    public var requestsToolCalling: Bool {
        !tools.isEmpty
    }

    public var hasNonTextInputs: Bool {
        conversationTurns.contains(where: \.containsNonTextParts)
    }

    public var hasImageInputs: Bool {
        conversationTurns.contains { turn in
            turn.parts?.contains(where: { $0.kind == .imageURL }) ?? false
        }
    }

    public var hasAudioInputs: Bool {
        conversationTurns.contains { turn in
            turn.parts?.contains(where: { $0.kind == .audioURL }) ?? false
        }
    }

    public var hasVideoInputs: Bool {
        conversationTurns.contains { turn in
            turn.parts?.contains(where: { $0.kind == .videoURL }) ?? false
        }
    }

    public var requestsReasoningControls: Bool {
        reasoning != nil
    }
}

public struct InferenceChunk: Sendable {
    public let text: String

    public init(text: String) {
        self.text = text
    }
}

public struct InferenceResult: Sendable {
    public let text: String
    public let tokensGenerated: Int
    public let promptTokens: Int
    public let generationTime: Double
    public let tokensPerSecond: Double
    public let wasCancelled: Bool

    public init(
        text: String,
        tokensGenerated: Int,
        promptTokens: Int,
        generationTime: Double,
        tokensPerSecond: Double,
        wasCancelled: Bool
    ) {
        self.text = text
        self.tokensGenerated = tokensGenerated
        self.promptTokens = promptTokens
        self.generationTime = generationTime
        self.tokensPerSecond = tokensPerSecond
        self.wasCancelled = wasCancelled
    }

    public var totalTokens: Int {
        tokensGenerated + promptTokens
    }
}

public enum InferenceError: Error, LocalizedError, Sendable {
    case modelNotFound(String)
    case invalidPath
    case noModelSelected
    case noModelLoaded
    case failedToLoadModel
    case failedToCreateContext
    case failedToInitializeBackend
    case tokenizationError
    case decodeError
    case generationCancelled
    case appleModelUnavailable(String)
    case unsupportedBackend(String)
    case backendUnavailable(String)
    case importFailed(String)
    case registryFailure(String)
    case compatibilityFailure(String)

    public var errorDescription: String? {
        switch self {
        case .modelNotFound(let detail):
            return detail
        case .invalidPath:
            return "Invalid model path. Please re-import or re-download the model."
        case .noModelSelected:
            return "No model is currently selected."
        case .noModelLoaded:
            return "No model is currently loaded."
        case .failedToLoadModel:
            return "Failed to load the GGUF model with llama.cpp."
        case .failedToCreateContext:
            return "Failed to create the llama.cpp inference context."
        case .failedToInitializeBackend:
            return "Failed to initialize the selected inference backend."
        case .tokenizationError:
            return "Failed to tokenize the prompt for inference."
        case .decodeError:
            return "Model decoding failed."
        case .generationCancelled:
            return "Generation was cancelled."
        case .appleModelUnavailable(let message),
             .unsupportedBackend(let message),
             .backendUnavailable(let message),
             .importFailed(let message),
             .registryFailure(let message),
             .compatibilityFailure(let message):
            return message
        }
    }
}

public enum CoreMLPackageLocator {
    public static func looksRunnable(packageRootPath: String?) -> Bool {
        guard let packageRootPath = packageRootPath?.nonEmpty else { return false }
        return runtimeModelRootURL(packageRootURL: URL(fileURLWithPath: packageRootPath)) != nil
    }

    public static func runtimeModelRootURL(packageRootURL: URL) -> URL? {
        if hasRunnablePayload(at: packageRootURL) {
            return packageRootURL
        }

        guard let enumerator = FileManager.default.enumerator(
            at: packageRootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        var candidateRoots: [URL] = []

        for case let fileURL as URL in enumerator {
            guard fileURL.lastPathComponent.localizedCaseInsensitiveCompare("meta.yaml") == .orderedSame else {
                continue
            }

            let candidateRoot = fileURL.deletingLastPathComponent()
            if hasRunnablePayload(at: candidateRoot) {
                candidateRoots.append(candidateRoot)
            }
        }

        return candidateRoots.min { lhs, rhs in
            if lhs.pathComponents.count != rhs.pathComponents.count {
                return lhs.pathComponents.count < rhs.pathComponents.count
            }

            return lhs.path.localizedCaseInsensitiveCompare(rhs.path) == .orderedAscending
        }
    }

    private static func hasRunnablePayload(at candidateRoot: URL) -> Bool {
        let fileManager = FileManager.default
        let metaURL = candidateRoot.appendingPathComponent("meta.yaml")

        guard fileManager.fileExists(atPath: metaURL.path) else {
            return false
        }

        let tokenizerFilenames = [
            "tokenizer.json",
            "tokenizer_config.json",
            "tokenizer.model",
        ]

        let hasTokenizerAssets = tokenizerFilenames.contains { filename in
            fileManager.fileExists(atPath: candidateRoot.appendingPathComponent(filename).path)
        }

        guard hasTokenizerAssets else {
            return false
        }

        guard let payloadEnumerator = fileManager.enumerator(
            at: candidateRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }

        for case let fileURL as URL in payloadEnumerator {
            let ext = fileURL.pathExtension.lowercased()
            if ext == "mlmodelc" || ext == "mlpackage" {
                return true
            }
        }

        return false
    }
}

public struct DeviceProfile: Hashable, Sendable {
    public let machineIdentifier: String
    public let chipFamily: String
    public let systemVersion: String
    public let physicalMemoryBytes: Int64
    public let recommendedGGUFBudgetBytes: Int64
    public let supportedGGUFBudgetBytes: Int64

    public init(
        machineIdentifier: String,
        chipFamily: String,
        systemVersion: String,
        physicalMemoryBytes: Int64,
        recommendedGGUFBudgetBytes: Int64,
        supportedGGUFBudgetBytes: Int64
    ) {
        self.machineIdentifier = machineIdentifier
        self.chipFamily = chipFamily
        self.systemVersion = systemVersion
        self.physicalMemoryBytes = physicalMemoryBytes
        self.recommendedGGUFBudgetBytes = recommendedGGUFBudgetBytes
        self.supportedGGUFBudgetBytes = supportedGGUFBudgetBytes
    }

    public var deviceLabel: String {
        #if canImport(UIKit)
        switch UIDevice.current.userInterfaceIdiom {
        case .pad:
            return "This iPad"
        case .phone:
            return "This iPhone"
        default:
            return "This Device"
        }
        #else
        return "This Device"
        #endif
    }

    public var formattedPhysicalMemory: String {
        ByteCountFormatter.string(fromByteCount: physicalMemoryBytes, countStyle: .memory)
    }

    public var formattedRecommendedBudget: String {
        ByteCountFormatter.string(fromByteCount: recommendedGGUFBudgetBytes, countStyle: .file)
    }

    public var formattedSupportedBudget: String {
        ByteCountFormatter.string(fromByteCount: supportedGGUFBudgetBytes, countStyle: .file)
    }
}

public struct DeviceRuntimeProfile: Hashable, Sendable {
    public let machineIdentifier: String
    public let chipFamily: String
    public let systemVersion: String
    public let physicalMemoryBytes: Int64
    public let interfaceKind: DeviceInterfaceKind
    public let recommendedGGUFBudgetBytes: Int64
    public let supportedGGUFBudgetBytes: Int64
    public let hasMetalDevice: Bool
    public let metalDeviceName: String?

    public init(
        machineIdentifier: String,
        chipFamily: String,
        systemVersion: String,
        physicalMemoryBytes: Int64,
        interfaceKind: DeviceInterfaceKind,
        recommendedGGUFBudgetBytes: Int64,
        supportedGGUFBudgetBytes: Int64,
        hasMetalDevice: Bool,
        metalDeviceName: String? = nil
    ) {
        self.machineIdentifier = machineIdentifier
        self.chipFamily = chipFamily
        self.systemVersion = systemVersion
        self.physicalMemoryBytes = physicalMemoryBytes
        self.interfaceKind = interfaceKind
        self.recommendedGGUFBudgetBytes = recommendedGGUFBudgetBytes
        self.supportedGGUFBudgetBytes = supportedGGUFBudgetBytes
        self.hasMetalDevice = hasMetalDevice
        self.metalDeviceName = metalDeviceName?.trimmedForLookup.nonEmpty
    }

    public var deviceLabel: String {
        switch interfaceKind {
        case .pad:
            return "This iPad"
        case .phone:
            return "This iPhone"
        case .mac:
            return "This Mac"
        case .other:
            return "This Device"
        }
    }

    public var formattedPhysicalMemory: String {
        ByteCountFormatter.string(fromByteCount: physicalMemoryBytes, countStyle: .memory)
    }

    public var formattedRecommendedBudget: String {
        ByteCountFormatter.string(fromByteCount: recommendedGGUFBudgetBytes, countStyle: .file)
    }

    public var formattedSupportedBudget: String {
        ByteCountFormatter.string(fromByteCount: supportedGGUFBudgetBytes, countStyle: .file)
    }

    public var compatibilityProfile: DeviceProfile {
        DeviceProfile(
            machineIdentifier: machineIdentifier,
            chipFamily: chipFamily,
            systemVersion: systemVersion,
            physicalMemoryBytes: physicalMemoryBytes,
            recommendedGGUFBudgetBytes: recommendedGGUFBudgetBytes,
            supportedGGUFBudgetBytes: supportedGGUFBudgetBytes
        )
    }
}

public struct CompatibilityReport: Hashable, Sendable {
    public let backendKind: ModelBackendKind
    public let level: ModelCompatibilityLevel
    public let title: String
    public let message: String

    public init(
        backendKind: ModelBackendKind,
        level: ModelCompatibilityLevel,
        title: String,
        message: String
    ) {
        self.backendKind = backendKind
        self.level = level
        self.title = title
        self.message = message
    }

    public var isUsable: Bool {
        level.isUsable
    }
}

public enum SystemModelCatalog {
    public static let appleFoundationCatalogID = "apple/foundation-model"
    public static let appleFoundationModelName = "Apple On-Device"

    public static func appleFoundationEntry(contextLength: Int = 4096) -> ModelCatalogEntry {
        let capability = ModelCapabilitySummary(
            sizeBytes: 0,
            quantization: "Apple AI",
            parameterCountLabel: "Built In",
            contextLength: max(contextLength, 2048),
            supportsStreaming: false,
            notes: "Uses Apple's built-in on-device Foundation Models runtime."
        )

        return ModelCatalogEntry(
            catalogId: appleFoundationCatalogID,
            sourceModelID: appleFoundationCatalogID,
            displayName: appleFoundationModelName,
            serverIdentifier: appleFoundationCatalogID,
            backendKind: .appleFoundation,
            importSource: .builtIn,
            isServerExposed: true,
            aliases: [
                appleFoundationModelName,
                "\(appleFoundationCatalogID)#\(appleFoundationModelName)"
            ],
            capabilitySummary: capability,
            serverCapabilities: ServerModelCapabilities.conservativeDefaults(
                backendKind: .appleFoundation,
                sourceModelID: appleFoundationCatalogID,
                displayName: appleFoundationModelName,
                capabilitySummary: capability
            ),
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
    }
}

public protocol InferenceBackend: AnyObject {
    var kind: ModelBackendKind { get }
    var activeCatalogId: String? { get }

    func load(entry: ModelCatalogEntry, runtime: RuntimePreferences) async throws
    func unload() async
    func generate(
        entry: ModelCatalogEntry,
        request: InferenceRequest,
        onChunk: @escaping @Sendable (InferenceChunk) -> Void
    ) async throws -> InferenceResult
    func stopGeneration() async
}

public extension String {
    var trimmedForLookup: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var nonEmpty: String? {
        let trimmed = trimmedForLookup
        return trimmed.isEmpty ? nil : trimmed
    }
}
