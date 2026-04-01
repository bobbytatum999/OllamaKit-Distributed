import Combine
import CryptoKit
import Darwin
import Foundation
import OllamaCore
import UIKit
#if canImport(WebKit)
import WebKit
#endif
#if canImport(JavaScriptCore)
import JavaScriptCore
#endif

enum AgentWorkspaceKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case builtInMirror
    case dataLayer
    case repoClone
    case downloadedSite
    case bundleLive
    case clonedRepository
    case externalFolder

    var id: String { rawValue }

    var title: String {
        switch self {
        case .builtInMirror:
            return "Built-In Mirror"
        case .dataLayer:
            return "Data Layer"
        case .repoClone:
            return "Repo Clone"
        case .downloadedSite:
            return "Downloaded Site"
        case .bundleLive:
            return "Live Bundle"
        case .clonedRepository:
            return "Cloned Repository"
        case .externalFolder:
            return "External Folder"
        }
    }
}

enum AgentToolCategory: String, CaseIterable, Identifiable, Codable, Sendable {
    case context
    case workspace
    case checkpoints
    case browser
    case diagnostics
    case bundle
    case shell
    case javascript
    case python
    case node
    case swift
    case git
    case github
    case githubActions
    case internet
    case webPreview
    case relay
    case remote

    var id: String { rawValue }
}

enum AgentRuntimeTier: String, CaseIterable, Identifiable, Codable, Sendable {
    case stockSideload
    case jailbreak

    var id: String { rawValue }

    var title: String {
        switch self {
        case .stockSideload:
            return "Stock Sideload"
        case .jailbreak:
            return "Jailbreak"
        }
    }
}

enum AgentNetworkScope: String, Codable, Sendable {
    case none
    case readOnly
    case credentialedRead
    case sideEffecting
}

enum AgentWriteScope: String, Codable, Sendable {
    case none
    case workspace
    case destructive
}

enum AgentApprovalStatus: String, Codable, Sendable {
    case pending
    case approved
    case rejected
}

enum AgentExecutionStatus: String, Codable, Sendable {
    case success
    case pendingApproval
    case failure
}

enum AgentLogLevel: String, CaseIterable, Identifiable, Codable, Sendable {
    case debug
    case info
    case warning
    case error

    var id: String { rawValue }
}

enum AgentLogCategory: String, CaseIterable, Identifiable, Codable, Sendable {
    case workspace
    case checkpoint
    case approval
    case browser
    case diagnostics
    case bundle
    case git
    case github
    case githubActions
    case internet
    case shell
    case javascript
    case runtime
    case relay
    case preview
    case server
    case tool
    case error

    var id: String { rawValue }
}

enum AgentJSONValue: Hashable, Codable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case object([String: AgentJSONValue])
    case array([AgentJSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: AgentJSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([AgentJSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value.")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    static func fromFoundation(_ value: Any?) -> AgentJSONValue? {
        guard let value else {
            return .null
        }

        if value is NSNull {
            return .null
        }

        if let value = value as? AgentJSONValue {
            return value
        }

        if let value = value as? String {
            return .string(value)
        }

        if let value = value as? Bool {
            return .bool(value)
        }

        if let value = value as? Int {
            return .int(value)
        }

        if let value = value as? Int64 {
            return .int(Int(value))
        }

        if let value = value as? Double {
            return .double(value)
        }

        if let value = value as? Float {
            return .double(Double(value))
        }

        if let value = value as? NSNumber {
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                return .bool(value.boolValue)
            }
            let doubleValue = value.doubleValue
            if floor(doubleValue) == doubleValue {
                return .int(value.intValue)
            }
            return .double(doubleValue)
        }

        if let value = value as? [String: Any] {
            var object: [String: AgentJSONValue] = [:]
            for (key, nested) in value {
                object[key] = AgentJSONValue.fromFoundation(nested) ?? .null
            }
            return .object(object)
        }

        if let value = value as? [Any] {
            return .array(value.compactMap { AgentJSONValue.fromFoundation($0) })
        }

        return .string(String(describing: value))
    }

    var foundationObject: Any {
        switch self {
        case .string(let value):
            return value
        case .int(let value):
            return value
        case .double(let value):
            return value
        case .bool(let value):
            return value
        case .object(let value):
            return value.mapValues(\.foundationObject)
        case .array(let value):
            return value.map(\.foundationObject)
        case .null:
            return NSNull()
        }
    }

    var stringValue: String? {
        switch self {
        case .string(let value):
            return value
        case .int(let value):
            return String(value)
        case .double(let value):
            return String(value)
        case .bool(let value):
            return value ? "true" : "false"
        case .object, .array, .null:
            return nil
        }
    }

    var boolValue: Bool? {
        switch self {
        case .bool(let value):
            return value
        case .string(let value):
            if value.caseInsensitiveCompare("true") == .orderedSame {
                return true
            }
            if value.caseInsensitiveCompare("false") == .orderedSame {
                return false
            }
            return nil
        case .int(let value):
            return value != 0
        case .double(let value):
            return value != 0
        case .object, .array, .null:
            return nil
        }
    }

    var intValue: Int? {
        switch self {
        case .int(let value):
            return value
        case .double(let value):
            return Int(value)
        case .string(let value):
            return Int(value)
        case .bool(let value):
            return value ? 1 : 0
        case .object, .array, .null:
            return nil
        }
    }

    var objectValue: [String: AgentJSONValue]? {
        if case .object(let value) = self {
            return value
        }
        return nil
    }

    var arrayValue: [AgentJSONValue]? {
        if case .array(let value) = self {
            return value
        }
        return nil
    }
}

struct AgentToolDescriptor: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let title: String
    let category: AgentToolCategory
    let detail: String
    let networkScope: AgentNetworkScope
    let writeScope: AgentWriteScope
    let needsApproval: Bool
    let available: Bool
    let availabilityReason: String?
    let timeoutSeconds: Int
    let quotaDescription: String
    var requiredCapabilities: [AgentToolCapabilityKey] = []
}

struct AgentWorkspaceRecord: Identifiable, Hashable, Codable, Sendable {
    let id: String
    var name: String
    let kind: AgentWorkspaceKind
    var rootPath: String
    var sourceDescription: String
    var lastSeedVersion: String?
    var lastSeededAt: Date?
    var lastRefreshedAt: Date?
    var linkedRepository: String?
    var linkedBranch: String?
}

struct AgentCheckpointRecord: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    let workspaceID: String
    let name: String
    let reason: String?
    let createdAt: Date
    let snapshotPath: String
}

struct AgentFileEntry: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let path: String
    let isDirectory: Bool
    let sizeBytes: Int64
    let modifiedAt: Date?
}

struct AgentSearchMatch: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let path: String
    let line: Int
    let preview: String
}

struct BrowserSessionRecord: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    var title: String
    var currentURL: String
    var lastLoadedAt: Date?
    var canGoBack: Bool
    var canGoForward: Bool
    var pageSummary: String?
    var lastError: String?
}

struct GitRepositoryRecord: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    let workspaceID: String
    var repository: String
    var branch: String
    var defaultBranch: String
    var lastCommitSHA: String?
    var lastSyncedAt: Date?
}

enum RuntimePackageAvailabilityState: String, Codable, Sendable {
    case installed
    case unavailableInCurrentIPA = "unavailable_in_current_ipa"
    case bridgeLoadFailed = "bridge_load_failed"
    case disabledByModelPolicy = "disabled_by_model_policy"

    var title: String {
        switch self {
        case .installed:
            return "Installed"
        case .unavailableInCurrentIPA:
            return "Unavailable in current IPA"
        case .bridgeLoadFailed:
            return "Bridge load failed"
        case .disabledByModelPolicy:
            return "Disabled by model policy"
        }
    }
}

struct RuntimePackageRecord: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let title: String
    let runtime: String
    let bundled: Bool
    let bridgeLoaded: Bool
    let resourceBundlePresent: Bool
    let toolExposed: Bool
    let available: Bool
    let state: RuntimePackageAvailabilityState
    let availabilityReason: String?
    let version: String?
    let supportedOperations: [String]

    var statusTitle: String {
        state.title
    }
}

struct EmbeddedRuntimeManifest: Codable, Sendable {
    let generatedAt: String?
    let runtimes: [EmbeddedRuntimeManifestRecord]
}

struct EmbeddedRuntimeManifestRecord: Hashable, Codable, Sendable {
    let id: String
    let title: String
    let frameworkName: String
    let version: String
    let bundled: Bool
    let bridgeSymbol: String
    let resourceBundlePresent: Bool
    let supportedOperations: [String]
    let requiredResources: [String]
    let supportFrameworks: [String]
}

struct BundlePatchRecord: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    let workspaceID: String
    let relativePath: String
    let backupPath: String?
    let operation: String
    let createdAt: Date
    let requiresRestart: Bool
}

struct AgentCapabilityProfile: Hashable, Codable, Sendable {
    let runtimeTier: AgentRuntimeTier
    let supportsEmbeddedBrowser: Bool
    let supportsJavaScriptRuntime: Bool
    let supportsPythonRuntime: Bool
    let supportsNodeRuntime: Bool
    let supportsSwiftRuntime: Bool
    let supportsGitHubActions: Bool
    let supportsManagedRelay: Bool
    let supportsLiveBundleEditing: Bool
    let supportsExpertBundleEditing: Bool
}

struct AgentApprovalRequest: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    let toolID: String
    let title: String
    let summary: String
    let workspaceID: String?
    let createdAt: Date
    let arguments: AgentJSONValue
    var status: AgentApprovalStatus
}

struct AgentExecutionResult: Hashable, Codable, Sendable {
    let status: AgentExecutionStatus
    let toolID: String
    let message: String
    let data: AgentJSONValue?
    let approvalRequest: AgentApprovalRequest?

    static func success(toolID: String, message: String, data: AgentJSONValue? = nil) -> AgentExecutionResult {
        AgentExecutionResult(status: .success, toolID: toolID, message: message, data: data, approvalRequest: nil)
    }

    static func failure(toolID: String, message: String) -> AgentExecutionResult {
        AgentExecutionResult(status: .failure, toolID: toolID, message: message, data: nil, approvalRequest: nil)
    }

    static func pending(toolID: String, message: String, request: AgentApprovalRequest) -> AgentExecutionResult {
        AgentExecutionResult(status: .pendingApproval, toolID: toolID, message: message, data: nil, approvalRequest: request)
    }
}

struct AgentLogEntry: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    let timestamp: Date
    let level: AgentLogLevel
    let category: AgentLogCategory
    let title: String
    let message: String
    let metadata: [String: String]
    let body: String?

    init(
        id: UUID = UUID(),
        timestamp: Date = .now,
        level: AgentLogLevel,
        category: AgentLogCategory,
        title: String,
        message: String,
        metadata: [String: String] = [:],
        body: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.category = category
        self.title = title
        self.message = message
        self.metadata = metadata
        self.body = body?.nonEmpty
    }
}

private struct AgentWorkspacePersistedState: Codable {
    var workspaces: [AgentWorkspaceRecord]
    var checkpoints: [String: [AgentCheckpointRecord]]
}

@MainActor
final class AgentLogStore: ObservableObject {
    static let shared = AgentLogStore()
    private static let storageURL = AppPersistencePaths.logsDirectoryURL.appendingPathComponent("agent-log-buffer.json")
    private let maxEntries = 500

    @Published private(set) var entries: [AgentLogEntry] = []

    var retentionLimit: Int { maxEntries }
    var storageLocationDescription: String { "Application Support/Logs/agent-log-buffer.json" }
    var storagePath: String { Self.storageURL.path }
    var persistenceSummary: String { "Stored on device. Keeps the latest \(maxEntries) power-agent entries until you clear them." }

    private init() {
        entries = PersistentJSONStore.load([AgentLogEntry].self, from: Self.storageURL, fallback: []).map { entry in
            AgentLogEntry(
                id: entry.id,
                timestamp: entry.timestamp,
                level: entry.level,
                category: entry.category,
                title: PersistentLogRedactor.redact(entry.title) ?? entry.title,
                message: PersistentLogRedactor.redact(entry.message) ?? entry.message,
                metadata: PersistentLogRedactor.redact(metadata: entry.metadata),
                body: PersistentLogRedactor.redact(entry.body)
            )
        }
    }

    func record(
        _ category: AgentLogCategory,
        level: AgentLogLevel = .info,
        title: String,
        message: String,
        metadata: [String: String] = [:],
        body: String? = nil
    ) {
        entries.append(
            AgentLogEntry(
                level: level,
                category: category,
                title: PersistentLogRedactor.redact(title) ?? title,
                message: PersistentLogRedactor.redact(message) ?? message,
                metadata: PersistentLogRedactor.redact(metadata: metadata),
                body: PersistentLogRedactor.redact(body)
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

    func exportText() -> String {
        entries.map { entry in
            let timestamp = ISO8601DateFormatter().string(from: entry.timestamp)
            let metadataText = entry.metadata
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: " ")
            let metadataSuffix = metadataText.isEmpty ? "" : "\n\(metadataText)"
            let bodySuffix = entry.body.map { "\n\($0)" } ?? ""
            return "[\(timestamp)] [\(entry.level.rawValue.uppercased())] [\(entry.category.rawValue)] \(entry.title)\n\(entry.message)\(metadataSuffix)\(bodySuffix)"
        }
        .joined(separator: "\n\n")
    }

    private func persist() {
        PersistentJSONStore.save(entries, to: Self.storageURL)
    }
}

enum AgentWorkspaceError: LocalizedError {
    case workspaceNotFound
    case pathOutsideWorkspace
    case pathNotFound(String)
    case invalidInput(String)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .workspaceNotFound:
            return "The requested workspace could not be found."
        case .pathOutsideWorkspace:
            return "The requested path is outside the approved workspace."
        case .pathNotFound(let value):
            return "The path \(value) could not be found."
        case .invalidInput(let value):
            return value
        case .unsupported(let value):
            return value
        }
    }
}

enum AgentPathHelper {
    static func normalizedRelativePath(_ rawValue: String?) -> String {
        let trimmed = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return "" }
        return trimmed
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    static func resolvedURL(relativePath: String, workspaceRoot: URL) throws -> URL {
        let normalized = normalizedRelativePath(relativePath)
        let baseURL = workspaceRoot.standardizedFileURL
        let resolved = normalized.isEmpty
            ? baseURL
            : baseURL.appendingPathComponent(normalized).standardizedFileURL
        guard resolved.path == baseURL.path || resolved.path.hasPrefix(baseURL.path + "/") else {
            throw AgentWorkspaceError.pathOutsideWorkspace
        }
        return resolved
    }

    static func relativePath(for fileURL: URL, rootURL: URL) -> String {
        let rootPath = rootURL.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath) else {
            return fileURL.lastPathComponent
        }
        let trimmed = String(filePath.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmed.isEmpty ? "." : trimmed
    }
}

enum AgentStoragePaths {
    static var baseAgentURL: URL {
        let fileManager = FileManager.default
        let supportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return supportURL.appendingPathComponent("PowerAgent", isDirectory: true)
    }

    static var workspacesURL: URL {
        baseAgentURL.appendingPathComponent("workspaces", isDirectory: true)
    }

    static var checkpointsURL: URL {
        baseAgentURL.appendingPathComponent("checkpoints", isDirectory: true)
    }

    static var browserURL: URL {
        baseAgentURL.appendingPathComponent("browser", isDirectory: true)
    }

    static var bundleBackupsURL: URL {
        baseAgentURL.appendingPathComponent("bundle-backups", isDirectory: true)
    }
}

@MainActor
final class BundlePatchStore: ObservableObject {
    static let shared = BundlePatchStore()

    @Published private(set) var records: [BundlePatchRecord] = []

    private let fileManager = FileManager.default
    private var hasBootstrapped = false

    private init() {}

    func bootstrapIfNeeded() {
        guard !hasBootstrapped else { return }
        hasBootstrapped = true
        try? fileManager.createDirectory(at: AgentStoragePaths.bundleBackupsURL, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: metadataURL),
           let decoded = try? JSONDecoder().decode([BundlePatchRecord].self, from: data) {
            records = decoded
        }
    }

    func recordBackup(
        workspaceID: String,
        relativePath: String,
        sourceURL: URL?,
        operation: String
    ) throws -> BundlePatchRecord {
        bootstrapIfNeeded()

        let patchID = UUID()
        let backupRoot = AgentStoragePaths.bundleBackupsURL
            .appendingPathComponent(workspaceID, isDirectory: true)
            .appendingPathComponent(patchID.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: backupRoot, withIntermediateDirectories: true)

        var backupPath: String?
        if let sourceURL, fileManager.fileExists(atPath: sourceURL.path) {
            let target = backupRoot.appendingPathComponent("payload", isDirectory: true)
            if sourceURL.hasDirectoryPath {
                try copyDirectoryContents(from: sourceURL, to: target)
            } else {
                try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.copyItem(at: sourceURL, to: target)
            }
            backupPath = target.path
        }

        let record = BundlePatchRecord(
            id: patchID,
            workspaceID: workspaceID,
            relativePath: relativePath,
            backupPath: backupPath,
            operation: operation,
            createdAt: .now,
            requiresRestart: true
        )
        records.insert(record, at: 0)
        persist()
        AgentLogStore.shared.record(
            .bundle,
            title: "Bundle Backup Created",
            message: relativePath,
            metadata: ["operation": operation]
        )
        return record
    }

    private var metadataURL: URL {
        AgentStoragePaths.bundleBackupsURL.appendingPathComponent("metadata.json")
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(records) {
            try? data.write(to: metadataURL, options: .atomic)
        }
    }

    private func copyDirectoryContents(from sourceURL: URL, to destinationURL: URL) throws {
        try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        let enumerator = fileManager.enumerator(
            at: sourceURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        while let fileURL = enumerator?.nextObject() as? URL {
            let relativePath = AgentPathHelper.relativePath(for: fileURL, rootURL: sourceURL)
            let destination = destinationURL.appendingPathComponent(relativePath)
            let values = try fileURL.resourceValues(forKeys: [.isDirectoryKey])
            if values.isDirectory == true {
                try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
            } else {
                try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.copyItem(at: fileURL, to: destination)
            }
        }
    }
}

#if canImport(WebKit)
@MainActor
final class BrowserSessionManager: NSObject, ObservableObject {
    static let shared = BrowserSessionManager()

    @Published private(set) var sessions: [BrowserSessionRecord] = []
    @Published private(set) var activeSessionID: UUID?

    private let fileManager = FileManager.default
    private var hasBootstrapped = false
    private var webViews: [UUID: WKWebView] = [:]
    private var sessionIDsByWebView: [ObjectIdentifier: UUID] = [:]
    private var navigationContinuations: [UUID: CheckedContinuation<Void, Never>] = [:]

    private override init() {
        super.init()
    }

    func bootstrapIfNeeded() {
        guard !hasBootstrapped else { return }
        hasBootstrapped = true
        try? fileManager.createDirectory(at: AgentStoragePaths.browserURL, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: metadataURL),
           let state = try? JSONDecoder().decode(BrowserState.self, from: data) {
            sessions = state.sessions
            activeSessionID = state.activeSessionID
        }

        if sessions.isEmpty {
            let record = BrowserSessionRecord(
                id: UUID(),
                title: "New Tab",
                currentURL: AppSettings.shared.agentBrowserLastURL.nonEmpty ?? AppSettings.shared.agentBrowserHomeURL.nonEmpty ?? "https://github.com",
                lastLoadedAt: nil,
                canGoBack: false,
                canGoForward: false,
                pageSummary: nil,
                lastError: nil
            )
            sessions = [record]
            activeSessionID = record.id
            persist()
        }

        if let activeSessionID {
            _ = webView(for: activeSessionID)
        }
    }

    func activeSession() -> BrowserSessionRecord? {
        bootstrapIfNeeded()
        guard let activeSessionID else { return sessions.first }
        return sessions.first(where: { $0.id == activeSessionID }) ?? sessions.first
    }

    func webView(for sessionID: UUID) -> WKWebView {
        bootstrapIfNeeded()
        if let existing = webViews[sessionID] {
            return existing
        }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webViews[sessionID] = webView
        sessionIDsByWebView[ObjectIdentifier(webView)] = sessionID
        if let record = sessions.first(where: { $0.id == sessionID }),
           let url = URL(string: record.currentURL) {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func openTab(urlString: String?) async -> BrowserSessionRecord {
        bootstrapIfNeeded()
        let target = urlString?.trimmedForLookup.nonEmpty ?? AppSettings.shared.agentBrowserHomeURL.nonEmpty ?? "https://github.com"
        let record = BrowserSessionRecord(
            id: UUID(),
            title: "New Tab",
            currentURL: target,
            lastLoadedAt: nil,
            canGoBack: false,
            canGoForward: false,
            pageSummary: nil,
            lastError: nil
        )
        sessions.append(record)
        activeSessionID = record.id
        persist()
        let webView = webView(for: record.id)
        if let url = URL(string: target) {
            _ = webView.load(URLRequest(url: url))
            await waitForNavigation(for: record.id)
            await refreshSessionState(sessionID: record.id)
        }
        AgentLogStore.shared.record(
            .browser,
            title: "Browser Tab Opened",
            message: target,
            metadata: ["session_id": record.id.uuidString]
        )
        return activeSession() ?? record
    }

    func setActiveSession(id: UUID) {
        bootstrapIfNeeded()
        guard sessions.contains(where: { $0.id == id }) else { return }
        activeSessionID = id
        _ = webView(for: id)
        persist()
    }

    func navigate(sessionID: UUID?, urlString: String) async throws -> BrowserSessionRecord {
        let record = try requiredSession(sessionID)
        guard let url = URL(string: urlString) else {
            throw AgentWorkspaceError.invalidInput("A valid browser URL is required.")
        }
        activeSessionID = record.id
        let webView = webView(for: record.id)
        _ = webView.load(URLRequest(url: url))
        await waitForNavigation(for: record.id)
        await refreshSessionState(sessionID: record.id)
        AgentLogStore.shared.record(
            .browser,
            title: "Browser Navigate",
            message: url.absoluteString,
            metadata: ["session_id": record.id.uuidString]
        )
        return try requiredSession(record.id)
    }

    func back(sessionID: UUID?) async throws -> BrowserSessionRecord {
        let record = try requiredSession(sessionID)
        let webView = webView(for: record.id)
        guard webView.canGoBack else { return record }
        webView.goBack()
        await waitForNavigation(for: record.id)
        await refreshSessionState(sessionID: record.id)
        return try requiredSession(record.id)
    }

    func forward(sessionID: UUID?) async throws -> BrowserSessionRecord {
        let record = try requiredSession(sessionID)
        let webView = webView(for: record.id)
        guard webView.canGoForward else { return record }
        webView.goForward()
        await waitForNavigation(for: record.id)
        await refreshSessionState(sessionID: record.id)
        return try requiredSession(record.id)
    }

    func reload(sessionID: UUID?) async throws -> BrowserSessionRecord {
        let record = try requiredSession(sessionID)
        let webView = webView(for: record.id)
        webView.reload()
        await waitForNavigation(for: record.id)
        await refreshSessionState(sessionID: record.id)
        return try requiredSession(record.id)
    }

    func readPage(sessionID: UUID?) async throws -> AgentJSONValue {
        let record = try requiredSession(sessionID)
        let webView = webView(for: record.id)
        let script = """
        (() => ({
          title: document.title || "",
          url: location.href || "",
          text: (document.body?.innerText || "").slice(0, 60000),
          html: document.documentElement?.outerHTML?.slice(0, 120000) || "",
          links: Array.from(document.querySelectorAll('a[href]')).slice(0, 50).map(a => ({text: (a.innerText || a.textContent || '').trim(), href: a.href}))
        }))();
        """
        guard let payload = try await webView.agentEvaluateJSON(script) else {
            throw AgentWorkspaceError.unsupported("The browser page did not return readable content.")
        }
        await refreshSessionState(sessionID: record.id)
        return payload
    }

    func queryDOM(sessionID: UUID?, selector: String, limit: Int) async throws -> AgentJSONValue {
        let record = try requiredSession(sessionID)
        let webView = webView(for: record.id)
        let escapedSelector = selector.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        let maxCount = max(1, min(limit, 50))
        let script = """
        (() => Array.from(document.querySelectorAll('\(escapedSelector)')).slice(0, \(maxCount)).map(node => ({
          text: (node.innerText || node.textContent || '').trim(),
          html: (node.outerHTML || '').slice(0, 5000),
          href: node.href || '',
          value: node.value || '',
          tag: node.tagName || ''
        })))();
        """
        return try await webView.agentEvaluateJSON(script) ?? .array([])
    }

    func extractLinks(sessionID: UUID?) async throws -> AgentJSONValue {
        let record = try requiredSession(sessionID)
        let webView = webView(for: record.id)
        let script = """
        (() => Array.from(document.querySelectorAll('a[href]')).slice(0, 200).map(node => ({
          text: (node.innerText || node.textContent || '').trim(),
          href: node.href || ''
        })))();
        """
        return try await webView.agentEvaluateJSON(script) ?? .array([])
    }

    func type(sessionID: UUID?, selector: String, text: String) async throws -> AgentJSONValue {
        let record = try requiredSession(sessionID)
        let webView = webView(for: record.id)
        let escapedSelector = selector.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        let escapedText = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
        let script = """
        (() => {
          const node = document.querySelector('\(escapedSelector)');
          if (!node) return {success:false,error:'selector_not_found'};
          node.focus();
          node.value = '\(escapedText)';
          node.dispatchEvent(new Event('input', { bubbles: true }));
          node.dispatchEvent(new Event('change', { bubbles: true }));
          return {success:true, value: node.value || ''};
        })();
        """
        return try await webView.agentEvaluateJSON(script) ?? .object([:])
    }

    func click(sessionID: UUID?, selector: String) async throws -> AgentJSONValue {
        let record = try requiredSession(sessionID)
        let webView = webView(for: record.id)
        let escapedSelector = selector.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        let script = """
        (() => {
          const node = document.querySelector('\(escapedSelector)');
          if (!node) return {success:false,error:'selector_not_found'};
          node.click();
          return {success:true};
        })();
        """
        let value = try await webView.agentEvaluateJSON(script) ?? .object([:])
        await refreshSessionState(sessionID: record.id)
        return value
    }

    func submitForm(sessionID: UUID?, selector: String) async throws -> AgentJSONValue {
        let record = try requiredSession(sessionID)
        let webView = webView(for: record.id)
        let escapedSelector = selector.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        let script = """
        (() => {
          const node = document.querySelector('\(escapedSelector)');
          if (!node) return {success:false,error:'selector_not_found'};
          if (node.requestSubmit) {
            node.requestSubmit();
          } else {
            node.submit();
          }
          return {success:true};
        })();
        """
        let value = try await webView.agentEvaluateJSON(script) ?? .object([:])
        await refreshSessionState(sessionID: record.id)
        return value
    }

    func savePageToWorkspace(sessionID: UUID?, workspaceID: String?, relativePath: String?) async throws -> AgentJSONValue {
        let record = try requiredSession(sessionID)
        let payload = try await readPage(sessionID: record.id)
        guard let object = payload.objectValue else {
            throw AgentWorkspaceError.unsupported("The current page could not be serialized.")
        }
        let path = relativePath?.nonEmpty ?? "downloads/pages/\(safeFilename(from: object["title"]?.stringValue ?? "page")).html"
        try AgentWorkspaceManager.shared.writeFile(
            workspaceID: workspaceID,
            relativePath: path,
            content: object["html"]?.stringValue ?? ""
        )
        AgentLogStore.shared.record(
            .browser,
            title: "Browser Page Saved",
            message: path,
            metadata: [
                "session_id": record.id.uuidString,
                "workspace_id": workspaceID ?? AgentWorkspaceManager.shared.activeWorkspaceID
            ]
        )
        return .object([
            "workspace_path": .string(path),
            "session_id": .string(record.id.uuidString)
        ])
    }

    func download(
        sessionID: UUID?,
        urlString: String?,
        workspaceID: String?,
        relativePath: String?
    ) async throws -> AgentJSONValue {
        let record = try requiredSession(sessionID)
        let targetURLString = urlString?.nonEmpty ?? record.currentURL
        guard let url = URL(string: targetURLString) else {
            throw AgentWorkspaceError.invalidInput("A valid download URL is required.")
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        let filename = relativePath?.nonEmpty
            ?? "downloads/browser/\((response.suggestedFilename?.nonEmpty ?? url.lastPathComponent.nonEmpty) ?? safeFilename(from: url.absoluteString))"
        try AgentWorkspaceManager.shared.writeDataFile(workspaceID: workspaceID, relativePath: filename, data: data)
        AgentLogStore.shared.record(
            .browser,
            title: "Browser Download Saved",
            message: filename,
            metadata: [
                "session_id": record.id.uuidString,
                "url": url.absoluteString,
                "bytes": String(data.count)
            ]
        )
        return .object([
            "workspace_path": .string(filename),
            "bytes": .int(data.count),
            "content_type": .string(response.mimeType ?? "")
        ])
    }

    func capture(sessionID: UUID?, workspaceID: String?, relativePath: String?) async throws -> AgentJSONValue {
        let record = try requiredSession(sessionID)
        let webView = webView(for: record.id)
        let image = try await webView.agentSnapshot()
        guard let data = image.pngData() else {
            throw AgentWorkspaceError.unsupported("The current page snapshot could not be encoded.")
        }
        let path = relativePath?.nonEmpty ?? "downloads/captures/\(safeFilename(from: record.title)).png"
        try AgentWorkspaceManager.shared.writeDataFile(workspaceID: workspaceID, relativePath: path, data: data)
        AgentLogStore.shared.record(
            .browser,
            title: "Browser Capture Saved",
            message: path,
            metadata: [
                "session_id": record.id.uuidString,
                "bytes": String(data.count)
            ]
        )
        return .object([
            "workspace_path": .string(path),
            "bytes": .int(data.count)
        ])
    }

    func pageSummaryJSON(sessionID: UUID?) async throws -> AgentJSONValue {
        let record = try requiredSession(sessionID)
        await refreshSessionState(sessionID: record.id)
        let refreshed = try requiredSession(record.id)
        return .object([
            "id": .string(refreshed.id.uuidString),
            "title": .string(refreshed.title),
            "url": .string(refreshed.currentURL),
            "can_go_back": .bool(refreshed.canGoBack),
            "can_go_forward": .bool(refreshed.canGoForward),
            "page_summary": .string(refreshed.pageSummary ?? ""),
            "last_error": .string(refreshed.lastError ?? "")
        ])
    }

    private func requiredSession(_ id: UUID?) throws -> BrowserSessionRecord {
        bootstrapIfNeeded()
        let resolvedID = id ?? activeSessionID
        guard let resolvedID,
              let record = sessions.first(where: { $0.id == resolvedID })
        else {
            throw AgentWorkspaceError.workspaceNotFound
        }
        return record
    }

    private func waitForNavigation(for sessionID: UUID) async {
        await withCheckedContinuation { continuation in
            navigationContinuations[sessionID] = continuation
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if let continuation = navigationContinuations.removeValue(forKey: sessionID) {
                    continuation.resume()
                }
            }
        }
    }

    fileprivate func refreshSessionState(sessionID: UUID) async {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        let webView = webView(for: sessionID)
        let title = (try? await webView.agentEvaluateString("document.title")) ?? sessions[index].title
        let summary = (try? await webView.agentEvaluateString("(document.body?.innerText || '').slice(0, 400)")) ?? sessions[index].pageSummary ?? ""
        sessions[index].title = title.nonEmpty ?? sessions[index].title
        sessions[index].currentURL = webView.url?.absoluteString ?? sessions[index].currentURL
        sessions[index].lastLoadedAt = .now
        sessions[index].canGoBack = webView.canGoBack
        sessions[index].canGoForward = webView.canGoForward
        sessions[index].pageSummary = summary.nonEmpty
        sessions[index].lastError = nil
        activeSessionID = sessionID
        AppSettings.shared.agentBrowserLastURL = sessions[index].currentURL
        persist()
    }

    private func safeFilename(from value: String) -> String {
        let invalid = CharacterSet(charactersIn: "\\/:*?\"<>|")
        let pieces = value.components(separatedBy: invalid).joined(separator: "-")
        return pieces.trimmedForLookup.nonEmpty ?? "artifact"
    }

    private var metadataURL: URL {
        AgentStoragePaths.browserURL.appendingPathComponent("sessions.json")
    }

    private func persist() {
        let state = BrowserState(sessions: sessions, activeSessionID: activeSessionID)
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: metadataURL, options: .atomic)
        }
    }

    private struct BrowserState: Codable {
        var sessions: [BrowserSessionRecord]
        var activeSessionID: UUID?
    }
}

extension BrowserSessionManager: WKNavigationDelegate, WKUIDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let sessionID = sessionIDsByWebView[ObjectIdentifier(webView)] else { return }
        Task { @MainActor in
            await refreshSessionState(sessionID: sessionID)
            navigationContinuations.removeValue(forKey: sessionID)?.resume()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard let sessionID = sessionIDsByWebView[ObjectIdentifier(webView)],
              let index = sessions.firstIndex(where: { $0.id == sessionID })
        else {
            return
        }
        sessions[index].lastError = error.localizedDescription
        persist()
        navigationContinuations.removeValue(forKey: sessionID)?.resume()
        AgentLogStore.shared.record(
            .browser,
            level: .error,
            title: "Browser Navigation Failed",
            message: error.localizedDescription,
            metadata: ["session_id": sessionID.uuidString]
        )
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        self.webView(webView, didFail: navigation, withError: error)
    }
}

private extension WKWebView {
    func agentEvaluateString(_ script: String) async throws -> String? {
        let result = try await evaluateJavaScriptAsync(script)
        return AgentJSONValue.fromFoundation(result)?.stringValue
    }

    func agentEvaluateJSON(_ script: String) async throws -> AgentJSONValue? {
        let result = try await evaluateJavaScriptAsync(script)
        return AgentJSONValue.fromFoundation(result)
    }

    func evaluateJavaScriptAsync(_ script: String) async throws -> Any? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any?, Error>) in
            evaluateJavaScript(script) { value, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: value)
                }
            }
        }
    }

    func agentSnapshot() async throws -> UIImage {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UIImage, Error>) in
            takeSnapshot(with: nil) { image, error in
                if let image {
                    continuation.resume(returning: image)
                } else if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(throwing: AgentWorkspaceError.unsupported("The browser snapshot failed."))
                }
            }
        }
    }
}
#endif

@MainActor
final class AgentWorkspaceManager: ObservableObject {
    static let shared = AgentWorkspaceManager()
    static let builtInWorkspaceID = "ollamakit-mirror"
    static let dataLayerWorkspaceID = "ollamakit-data"
    static let downloadedSiteWorkspaceID = "downloaded-sites"
    static let liveBundleWorkspaceID = "live-bundle"
    static let mirroredPrefixes = [
        ".github/workflows/",
        "LiveContainerFix/",
        "Scripts/",
        "Sources/OllamaCore/",
        "Sources/OllamaKit/",
        "Tests/",
        "Vendor/anemll-swift-cli/",
        "OllamaKit.xcodeproj/",
        "README.md",
        "Package.swift",
        "LICENSE"
    ]
    static let mirroredExactFiles: Set<String> = [
        "LICENSE",
        "Package.swift",
        "README.md",
        "OllamaKit.xcodeproj/project.pbxproj"
    ]
    static let mirroredTextExtensions: Set<String> = [
        "c",
        "cc",
        "cfg",
        "cpp",
        "entitlements",
        "h",
        "htm",
        "html",
        "java",
        "js",
        "json",
        "m",
        "md",
        "pbxproj",
        "plist",
        "prompt",
        "py",
        "rb",
        "sh",
        "strings",
        "swift",
        "txt",
        "xcconfig",
        "xcscheme",
        "xml",
        "yaml",
        "yml"
    ]

    @Published private(set) var workspaces: [AgentWorkspaceRecord] = []
    @Published private(set) var checkpointsByWorkspace: [String: [AgentCheckpointRecord]] = [:]

    private let fileManager = FileManager.default
    private var hasBootstrapped = false

    private init() {}

    static func shouldMirrorPath(_ rawPath: String) -> Bool {
        let path = rawPath.replacingOccurrences(of: "\\", with: "/").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return false }

        if mirroredExactFiles.contains(path) {
            return true
        }

        guard mirroredPrefixes.contains(where: { prefix in
            path == prefix || path.hasPrefix(prefix)
        }) else {
            return false
        }

        let fileExtension = URL(fileURLWithPath: path).pathExtension.lowercased()
        if fileExtension.isEmpty {
            return mirroredExactFiles.contains(path)
        }

        return mirroredTextExtensions.contains(fileExtension)
    }

    var activeWorkspaceID: String {
        if let configured = AppSettings.shared.agentDefaultWorkspaceID.nonEmpty,
           workspaces.contains(where: { $0.id == configured }) {
            return configured
        }
        return Self.builtInWorkspaceID
    }

    func bootstrapIfNeeded() {
        guard !hasBootstrapped else { return }
        hasBootstrapped = true
        do {
            try ensureContainerDirectories()
            loadPersistedState()
            try ensureBuiltInWorkspace()
            try ensureDataLayerWorkspace()
            try ensureDownloadedSiteWorkspace()
            try ensureBundleLiveWorkspaceIfAvailable()
            BundlePatchStore.shared.bootstrapIfNeeded()
#if canImport(WebKit)
            BrowserSessionManager.shared.bootstrapIfNeeded()
#endif
            if AppSettings.shared.agentDefaultWorkspaceID.trimmedForLookup.isEmpty {
                AppSettings.shared.agentDefaultWorkspaceID = Self.builtInWorkspaceID
            }
        } catch {
            AgentLogStore.shared.record(
                .workspace,
                level: .error,
                title: "Workspace Bootstrap Failed",
                message: error.localizedDescription
            )
        }
    }

    func setActiveWorkspace(id: String) {
        bootstrapIfNeeded()
        guard workspaces.contains(where: { $0.id == id }) else { return }
        AppSettings.shared.agentDefaultWorkspaceID = id
    }

    func activeWorkspace() -> AgentWorkspaceRecord? {
        bootstrapIfNeeded()
        return workspace(id: activeWorkspaceID)
    }

    func workspace(id: String?) -> AgentWorkspaceRecord? {
        bootstrapIfNeeded()
        let targetID = id?.nonEmpty ?? activeWorkspaceID
        return workspaces.first(where: { $0.id == targetID })
    }

    func checkpointRecords(workspaceID: String? = nil) -> [AgentCheckpointRecord] {
        bootstrapIfNeeded()
        return (checkpointsByWorkspace[workspaceID?.nonEmpty ?? activeWorkspaceID] ?? [])
            .sorted { $0.createdAt > $1.createdAt }
    }

    func listFiles(workspaceID: String? = nil, relativePath: String = "", recursive: Bool = false, limit: Int = 200) throws -> [AgentFileEntry] {
        let record = try requiredWorkspace(workspaceID)
        let baseURL = workspaceRootURL(for: record)
        let targetURL = try AgentPathHelper.resolvedURL(relativePath: relativePath, workspaceRoot: baseURL)
        guard fileManager.fileExists(atPath: targetURL.path) else {
            throw AgentWorkspaceError.pathNotFound(relativePath)
        }

        if recursive {
            return try recursiveEntries(in: targetURL, rootURL: baseURL, limit: limit)
        }

        let urls = try fileManager.contentsOfDirectory(
            at: targetURL,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )

        return try urls
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
            .prefix(limit)
            .map { try makeFileEntry(for: $0, rootURL: baseURL) }
    }

    func readFile(workspaceID: String? = nil, relativePath: String) throws -> String {
        let record = try requiredWorkspace(workspaceID)
        let baseURL = workspaceRootURL(for: record)
        let fileURL = try AgentPathHelper.resolvedURL(relativePath: relativePath, workspaceRoot: baseURL)
        guard fileManager.fileExists(atPath: fileURL.path) else {
            throw AgentWorkspaceError.pathNotFound(relativePath)
        }
        return try String(contentsOf: fileURL, encoding: .utf8)
    }

    func search(workspaceID: String? = nil, needle: String, limit: Int = 100) throws -> [AgentSearchMatch] {
        let normalizedNeedle = needle.trimmedForLookup
        guard !normalizedNeedle.isEmpty else {
            throw AgentWorkspaceError.invalidInput("Search text cannot be empty.")
        }

        let record = try requiredWorkspace(workspaceID)
        let baseURL = workspaceRootURL(for: record)
        let urls = try allFileURLs(in: baseURL)
        var matches: [AgentSearchMatch] = []

        for fileURL in urls where matches.count < limit {
            guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            let lines = content.components(separatedBy: .newlines)
            for (index, line) in lines.enumerated() where matches.count < limit {
                if line.localizedCaseInsensitiveContains(normalizedNeedle) {
                    let path = AgentPathHelper.relativePath(for: fileURL, rootURL: baseURL)
                    matches.append(
                        AgentSearchMatch(
                            id: "\(path)#\(index + 1)",
                            path: path,
                            line: index + 1,
                            preview: line.trimmingCharacters(in: .whitespaces)
                        )
                    )
                }
            }
        }

        return matches
    }

    @discardableResult
    func createCheckpoint(workspaceID: String? = nil, name: String? = nil, reason: String? = nil) throws -> AgentCheckpointRecord {
        let record = try requiredWorkspace(workspaceID)
        let snapshotID = UUID()
        let snapshotRoot = checkpointsContainerURL
            .appendingPathComponent(record.id, isDirectory: true)
            .appendingPathComponent(snapshotID.uuidString, isDirectory: true)
        let snapshotWorkspace = snapshotRoot.appendingPathComponent("snapshot", isDirectory: true)
        try fileManager.createDirectory(at: snapshotWorkspace, withIntermediateDirectories: true)
        try copyDirectoryContents(from: workspaceRootURL(for: record), to: snapshotWorkspace)

        let checkpoint = AgentCheckpointRecord(
            id: snapshotID,
            workspaceID: record.id,
            name: name?.nonEmpty ?? "Checkpoint \(checkpointRecords(workspaceID: record.id).count + 1)",
            reason: reason?.nonEmpty,
            createdAt: .now,
            snapshotPath: snapshotWorkspace.path
        )

        checkpointsByWorkspace[record.id, default: []].append(checkpoint)
        persistState()
        AgentLogStore.shared.record(
            .checkpoint,
            title: "Checkpoint Created",
            message: checkpoint.name,
            metadata: ["workspace": record.name]
        )
        return checkpoint
    }

    func restoreCheckpoint(workspaceID: String? = nil, checkpointID: UUID) throws -> AgentCheckpointRecord {
        let record = try requiredWorkspace(workspaceID)
        guard let checkpoint = checkpointRecords(workspaceID: record.id).first(where: { $0.id == checkpointID }) else {
            throw AgentWorkspaceError.pathNotFound(checkpointID.uuidString)
        }

        let workspaceURL = workspaceRootURL(for: record)
        try removeDirectoryContents(at: workspaceURL)
        try copyDirectoryContents(from: URL(fileURLWithPath: checkpoint.snapshotPath), to: workspaceURL)

        AgentLogStore.shared.record(
            .checkpoint,
            title: "Checkpoint Restored",
            message: checkpoint.name,
            metadata: ["workspace": record.name]
        )

        return checkpoint
    }

    func diffFromLatestCheckpoint(workspaceID: String? = nil, limit: Int = 200) throws -> AgentJSONValue {
        let record = try requiredWorkspace(workspaceID)
        let workspaceURL = workspaceRootURL(for: record)
        let latestCheckpoint = checkpointRecords(workspaceID: record.id).first
        let baselineURL: URL
        if let latestCheckpoint {
            baselineURL = URL(fileURLWithPath: latestCheckpoint.snapshotPath)
        } else {
            baselineURL = agentSeedBaselineURL
            if !fileManager.fileExists(atPath: baselineURL.path) {
                try materializeWorkspaceSeed(into: baselineURL)
            }
        }

        let currentFiles = try fileFingerprintMap(rootURL: workspaceURL)
        let baselineFiles = try fileFingerprintMap(rootURL: baselineURL)

        let added = Set(currentFiles.keys).subtracting(Set(baselineFiles.keys)).sorted()
        let removed = Set(baselineFiles.keys).subtracting(Set(currentFiles.keys)).sorted()
        let modified = Set(currentFiles.keys)
            .intersection(Set(baselineFiles.keys))
            .filter { currentFiles[$0] != baselineFiles[$0] }
            .sorted()

        return .object([
            "workspace_id": .string(record.id),
            "baseline": .string(latestCheckpoint?.name ?? "seed"),
            "added": .array(added.prefix(limit).map(AgentJSONValue.string)),
            "removed": .array(removed.prefix(limit).map(AgentJSONValue.string)),
            "modified": .array(modified.prefix(limit).map(AgentJSONValue.string)),
            "changed_count": .int(added.count + removed.count + modified.count)
        ])
    }

    func writeFile(workspaceID: String? = nil, relativePath: String, content: String) throws {
        let record = try requiredWorkspace(workspaceID)
        let workspaceURL = workspaceRootURL(for: record)
        let fileURL = try AgentPathHelper.resolvedURL(relativePath: relativePath, workspaceRoot: workspaceURL)
        try validateMutationAllowed(for: record, relativePath: relativePath, sourceURL: fileURL, operation: "write")
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
        AgentLogStore.shared.record(
            record.kind == .bundleLive ? .bundle : .workspace,
            title: "File Written",
            message: relativePath,
            metadata: ["workspace": record.name]
        )
    }

    func writeDataFile(workspaceID: String? = nil, relativePath: String, data: Data) throws {
        let record = try requiredWorkspace(workspaceID)
        let workspaceURL = workspaceRootURL(for: record)
        let fileURL = try AgentPathHelper.resolvedURL(relativePath: relativePath, workspaceRoot: workspaceURL)
        try validateMutationAllowed(for: record, relativePath: relativePath, sourceURL: fileURL, operation: "write-data")
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
        AgentLogStore.shared.record(
            record.kind == .bundleLive ? .bundle : .workspace,
            title: "Binary File Written",
            message: relativePath,
            metadata: ["workspace": record.name, "bytes": String(data.count)]
        )
    }

    func createFolder(workspaceID: String? = nil, relativePath: String) throws {
        let record = try requiredWorkspace(workspaceID)
        let workspaceURL = workspaceRootURL(for: record)
        let folderURL = try AgentPathHelper.resolvedURL(relativePath: relativePath, workspaceRoot: workspaceURL)
        try validateMutationAllowed(for: record, relativePath: relativePath, sourceURL: folderURL, operation: "mkdir")
        try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
        AgentLogStore.shared.record(
            record.kind == .bundleLive ? .bundle : .workspace,
            title: "Folder Created",
            message: relativePath,
            metadata: ["workspace": record.name]
        )
    }

    func moveItem(workspaceID: String? = nil, from sourcePath: String, to destinationPath: String) throws {
        let record = try requiredWorkspace(workspaceID)
        let workspaceURL = workspaceRootURL(for: record)
        let sourceURL = try AgentPathHelper.resolvedURL(relativePath: sourcePath, workspaceRoot: workspaceURL)
        let destinationURL = try AgentPathHelper.resolvedURL(relativePath: destinationPath, workspaceRoot: workspaceURL)
        try validateMutationAllowed(for: record, relativePath: sourcePath, sourceURL: sourceURL, operation: "move-source")
        try validateMutationAllowed(for: record, relativePath: destinationPath, sourceURL: destinationURL, operation: "move-destination")
        try fileManager.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.moveItem(at: sourceURL, to: destinationURL)
        AgentLogStore.shared.record(
            record.kind == .bundleLive ? .bundle : .workspace,
            title: "Item Moved",
            message: "\(sourcePath) -> \(destinationPath)",
            metadata: ["workspace": record.name]
        )
    }

    func deleteItem(workspaceID: String? = nil, relativePath: String) throws {
        let record = try requiredWorkspace(workspaceID)
        let workspaceURL = workspaceRootURL(for: record)
        let targetURL = try AgentPathHelper.resolvedURL(relativePath: relativePath, workspaceRoot: workspaceURL)
        guard fileManager.fileExists(atPath: targetURL.path) else {
            throw AgentWorkspaceError.pathNotFound(relativePath)
        }
        try validateMutationAllowed(for: record, relativePath: relativePath, sourceURL: targetURL, operation: "delete")
        try fileManager.removeItem(at: targetURL)
        AgentLogStore.shared.record(
            record.kind == .bundleLive ? .bundle : .workspace,
            level: .warning,
            title: "Item Deleted",
            message: relativePath,
            metadata: ["workspace": record.name]
        )
    }

    func cloneRepositoryWorkspace(repository: String, ref: String?) async throws -> AgentWorkspaceRecord {
        let snapshot = try await GitHubService.shared.fetchRepositorySnapshot(repository: repository, ref: ref)
        let workspaceID = "repo-\(UUID().uuidString.lowercased())"
        let rootURL = workspacesContainerURL
            .appendingPathComponent(workspaceID, isDirectory: true)
            .appendingPathComponent("current", isDirectory: true)
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try materializeFiles(snapshot.files, into: rootURL)

        let record = AgentWorkspaceRecord(
            id: workspaceID,
            name: snapshot.repository.replacingOccurrences(of: "/", with: " "),
            kind: .repoClone,
            rootPath: rootURL.path,
            sourceDescription: "GitHub snapshot clone from \(snapshot.repository) @ \(snapshot.reference)",
            lastSeedVersion: nil,
            lastSeededAt: nil,
            lastRefreshedAt: .now,
            linkedRepository: snapshot.repository,
            linkedBranch: snapshot.reference
        )

        workspaces.append(record)
        AppSettings.shared.agentDefaultWorkspaceID = record.id
        persistState()
        AgentLogStore.shared.record(
            .git,
            title: "Repository Workspace Cloned",
            message: snapshot.repository,
            metadata: ["ref": snapshot.reference]
        )
        return record
    }

    @discardableResult
    func resetBuiltInWorkspaceToSeed() throws -> AgentCheckpointRecord {
        let checkpoint = try createCheckpoint(workspaceID: Self.builtInWorkspaceID, name: "Pre-Seed Reset", reason: "Resetting the built-in mirror to the bundled seed.")
        let record = try requiredWorkspace(Self.builtInWorkspaceID)
        let workspaceURL = workspaceRootURL(for: record)
        try removeDirectoryContents(at: workspaceURL)
        try materializeWorkspaceSeed(into: workspaceURL)
        updateWorkspace(id: record.id) { workspace in
            workspace.lastSeedVersion = AgentWorkspaceSeed.version
            workspace.lastSeededAt = .now
        }
        AgentLogStore.shared.record(
            .workspace,
            title: "Workspace Reset To Seed",
            message: "Recreated the built-in OllamaKit mirror from the bundled project snapshot."
        )
        return checkpoint
    }

    func refreshBuiltInWorkspaceFromGitHub(repository: String, ref: String?) async throws -> AgentJSONValue {
        let record = try requiredWorkspace(Self.builtInWorkspaceID)
        _ = try createCheckpoint(
            workspaceID: record.id,
            name: "Pre-GitHub Refresh",
            reason: "Refreshing the built-in workspace from GitHub."
        )
        let refresh = try await GitHubService.shared.fetchWorkspaceFiles(repository: repository, ref: ref)
        let workspaceURL = workspaceRootURL(for: record)
        try removeDirectoryContents(at: workspaceURL)
        try materializeFiles(refresh.files, into: workspaceURL)
        updateWorkspace(id: record.id) { workspace in
            workspace.lastRefreshedAt = .now
            workspace.lastSeedVersion = AgentWorkspaceSeed.version
            workspace.sourceDescription = "GitHub refresh from \(repository) @ \(refresh.reference)"
            workspace.linkedRepository = repository
            workspace.linkedBranch = refresh.reference
        }
        AgentLogStore.shared.record(
            .github,
            title: "Workspace Refreshed",
            message: "Updated the built-in workspace from GitHub.",
            metadata: ["repository": repository, "ref": refresh.reference]
        )
        return .object([
            "repository": .string(repository),
            "reference": .string(refresh.reference),
            "file_count": .int(refresh.files.count)
        ])
    }

    func currentPreviewURL(workspaceID: String? = nil) -> URL? {
        guard let record = workspace(id: workspaceID) else { return nil }
        let rootURL = workspaceRootURL(for: record)
        let preferredRelativePaths = [
            "preview/index.html",
            "web/index.html",
            "index.html"
        ]

        for relativePath in preferredRelativePaths {
            let url = rootURL.appendingPathComponent(relativePath)
            if fileManager.fileExists(atPath: url.path) {
                return url
            }
        }

        let enumerator = fileManager.enumerator(at: rootURL, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
        while let fileURL = enumerator?.nextObject() as? URL {
            if fileURL.lastPathComponent.caseInsensitiveCompare("index.html") == .orderedSame {
                return fileURL
            }
        }

        return nil
    }

    func projectSummaryJSON(workspaceID: String? = nil) throws -> AgentJSONValue {
        let record = try requiredWorkspace(workspaceID)
        let workspaceURL = workspaceRootURL(for: record)
        let files = try allFileURLs(in: workspaceURL).map { AgentPathHelper.relativePath(for: $0, rootURL: workspaceURL) }.sorted()
        let manifests = files.filter {
            ["Package.swift", "README.md", "OllamaKit.xcodeproj/project.pbxproj", "Sources/OllamaKit/Info.plist"].contains($0)
        }
        let entryPoints = files.filter {
            [
                "Sources/OllamaKit/OllamaKitApp.swift",
                "Sources/OllamaKit/Views/ContentView.swift",
                "Sources/OllamaKit/Services/ServerManager.swift",
                "Sources/OllamaKit/Services/ModelRunner.swift",
                "Sources/OllamaKit/Services/UnifiedModelCatalog.swift",
                "Sources/OllamaKit/Views/ChatView.swift",
                "Sources/OllamaKit/Views/ModelsView.swift",
                "Sources/OllamaKit/Views/ServerView.swift",
                "Sources/OllamaKit/Views/SettingsView.swift"
            ].contains($0)
        }
        let dependencies = dependencyLines(from: workspaceURL.appendingPathComponent("Package.swift"))
        let diff = try diffFromLatestCheckpoint(workspaceID: record.id)

#if canImport(WebKit)
        let browserSummary = BrowserSessionManager.shared.activeSession().map { session in
            AgentJSONValue.object([
                "id": .string(session.id.uuidString),
                "title": .string(session.title),
                "url": .string(session.currentURL),
                "summary": .string(session.pageSummary ?? "")
            ])
        } ?? .null
#else
        let browserSummary: AgentJSONValue = .null
#endif

        return .object([
            "workspace": .object([
                "id": .string(record.id),
                "name": .string(record.name),
                "kind": .string(record.kind.rawValue),
                "root_path": .string(record.rootPath),
                "checkpoint_count": .int(checkpointRecords(workspaceID: record.id).count),
                "file_count": .int(files.count),
                "linked_repository": .string(record.linkedRepository ?? ""),
                "linked_branch": .string(record.linkedBranch ?? "")
            ]),
            "manifests": .array(manifests.map(AgentJSONValue.string)),
            "entry_points": .array(entryPoints.map(AgentJSONValue.string)),
            "dependencies": .array(dependencies.map(AgentJSONValue.string)),
            "diff": diff,
            "browser": browserSummary,
            "bundle_patch_count": .int(BundlePatchStore.shared.records.filter { $0.workspaceID == record.id }.count)
        ])
    }

    private func requiredWorkspace(_ workspaceID: String?) throws -> AgentWorkspaceRecord {
        bootstrapIfNeeded()
        guard let record = workspace(id: workspaceID) else {
            throw AgentWorkspaceError.workspaceNotFound
        }
        return record
    }

    private var baseAgentURL: URL {
        AgentStoragePaths.baseAgentURL
    }

    private var workspacesContainerURL: URL {
        AgentStoragePaths.workspacesURL
    }

    private var checkpointsContainerURL: URL {
        AgentStoragePaths.checkpointsURL
    }

    private var metadataURL: URL {
        baseAgentURL.appendingPathComponent("metadata.json")
    }

    private var agentSeedBaselineURL: URL {
        baseAgentURL.appendingPathComponent("seed-baseline", isDirectory: true)
    }

    private func ensureContainerDirectories() throws {
        try fileManager.createDirectory(at: baseAgentURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: workspacesContainerURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: checkpointsContainerURL, withIntermediateDirectories: true)
    }

    private func loadPersistedState() {
        guard let data = try? Data(contentsOf: metadataURL),
              let state = try? JSONDecoder().decode(AgentWorkspacePersistedState.self, from: data)
        else {
            workspaces = []
            checkpointsByWorkspace = [:]
            return
        }

        workspaces = state.workspaces
        checkpointsByWorkspace = state.checkpoints
    }

    private func persistState() {
        let state = AgentWorkspacePersistedState(workspaces: workspaces, checkpoints: checkpointsByWorkspace)
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: metadataURL, options: .atomic)
        }
    }

    private func ensureBuiltInWorkspace() throws {
        if workspaces.contains(where: { $0.id == Self.builtInWorkspaceID }) {
            return
        }

        let rootURL = workspacesContainerURL
            .appendingPathComponent(Self.builtInWorkspaceID, isDirectory: true)
            .appendingPathComponent("current", isDirectory: true)
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try materializeWorkspaceSeed(into: rootURL)

        let record = AgentWorkspaceRecord(
            id: Self.builtInWorkspaceID,
            name: "OllamaKit Mirror",
            kind: .builtInMirror,
            rootPath: rootURL.path,
            sourceDescription: "Bundled mutable workspace mirror seeded from the app snapshot.",
            lastSeedVersion: AgentWorkspaceSeed.version,
            lastSeededAt: .now,
            lastRefreshedAt: nil,
            linkedRepository: AppSettings.shared.agentGitHubRepository.nonEmpty,
            linkedBranch: nil
        )
        workspaces.append(record)
        persistState()
        AgentLogStore.shared.record(
            .workspace,
            title: "Built-In Workspace Seeded",
            message: "Created the mutable OllamaKit mirror inside app storage.",
            metadata: ["workspace": record.name]
        )
    }

    private func ensureDataLayerWorkspace() throws {
        if workspaces.contains(where: { $0.id == Self.dataLayerWorkspaceID }) {
            return
        }

        let rootURL = workspacesContainerURL
            .appendingPathComponent(Self.dataLayerWorkspaceID, isDirectory: true)
            .appendingPathComponent("current", isDirectory: true)
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try materializeFiles([
            "README.md": "# Power Agent Data Layer\n",
            "prompts/system.md": "Store mutable system prompts here.\n",
            "scripts/README.md": "Put Python or JavaScript helper scripts here.\n",
            "configs/README.md": "Mutable agent/runtime configuration files.\n"
        ], into: rootURL)
        workspaces.append(
            AgentWorkspaceRecord(
                id: Self.dataLayerWorkspaceID,
                name: "Internal Data Layer",
                kind: .dataLayer,
                rootPath: rootURL.path,
                sourceDescription: "Writable internal storage for prompts, scripts, configs, and generated artifacts.",
                lastSeedVersion: nil,
                lastSeededAt: .now,
                lastRefreshedAt: nil,
                linkedRepository: nil,
                linkedBranch: nil
            )
        )
        persistState()
    }

    private func ensureDownloadedSiteWorkspace() throws {
        if workspaces.contains(where: { $0.id == Self.downloadedSiteWorkspaceID }) {
            return
        }

        let rootURL = workspacesContainerURL
            .appendingPathComponent(Self.downloadedSiteWorkspaceID, isDirectory: true)
            .appendingPathComponent("current", isDirectory: true)
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try materializeFiles([
            "README.md": "# Downloaded Pages\n",
            "downloads/.keep": ""
        ], into: rootURL)
        workspaces.append(
            AgentWorkspaceRecord(
                id: Self.downloadedSiteWorkspaceID,
                name: "Downloaded Sites",
                kind: .downloadedSite,
                rootPath: rootURL.path,
                sourceDescription: "Browser captures, downloaded pages, screenshots, and saved web assets.",
                lastSeedVersion: nil,
                lastSeededAt: .now,
                lastRefreshedAt: nil,
                linkedRepository: nil,
                linkedBranch: nil
            )
        )
        persistState()
    }

    private func ensureBundleLiveWorkspaceIfAvailable() throws {
        guard AppSettings.shared.buildVariant.allowsLiveBundleWorkspace else {
            workspaces.removeAll { $0.id == Self.liveBundleWorkspaceID }
            checkpointsByWorkspace.removeValue(forKey: Self.liveBundleWorkspaceID)
            persistState()
            return
        }

        let bundleURL = Bundle.main.bundleURL.standardizedFileURL
        let isWritable = fileManager.isWritableFile(atPath: bundleURL.path)
        if isWritable {
            if workspaces.contains(where: { $0.id == Self.liveBundleWorkspaceID }) {
                updateWorkspace(id: Self.liveBundleWorkspaceID) { workspace in
                    workspace.rootPath = bundleURL.path
                    workspace.sourceDescription = "Writable live app bundle detected. Resource edits require restart."
                }
                return
            }
            workspaces.append(
                AgentWorkspaceRecord(
                    id: Self.liveBundleWorkspaceID,
                    name: "Live App Bundle",
                    kind: .bundleLive,
                    rootPath: bundleURL.path,
                    sourceDescription: "Writable live app bundle detected. Resource edits require restart.",
                    lastSeedVersion: nil,
                    lastSeededAt: nil,
                    lastRefreshedAt: nil,
                    linkedRepository: nil,
                    linkedBranch: nil
                )
            )
            persistState()
        } else {
            workspaces.removeAll { $0.id == Self.liveBundleWorkspaceID }
            checkpointsByWorkspace.removeValue(forKey: Self.liveBundleWorkspaceID)
            persistState()
        }
    }

    private func validateMutationAllowed(
        for record: AgentWorkspaceRecord,
        relativePath: String,
        sourceURL: URL,
        operation: String
    ) throws {
        if record.kind == .bundleLive {
            let path = AgentPathHelper.normalizedRelativePath(relativePath)
            let allowedExtensions: Set<String> = ["plist", "json", "txt", "md", "html", "htm", "css", "js", "xml", "yaml", "yml", "strings", "cfg", "prompt", "svg", "png", "jpg", "jpeg", "webp"]
            let ext = sourceURL.pathExtension.lowercased()
            var isDirectory: ObjCBool = false
            let existsAsDirectory = fileManager.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory) && isDirectory.boolValue
            if !AppSettings.shared.agentBundleExpertMode {
                if operation != "mkdir" && !existsAsDirectory && !sourceURL.hasDirectoryPath && !allowedExtensions.contains(ext) {
                    throw AgentWorkspaceError.unsupported("Live bundle edits are limited to resource/text assets unless Expert Bundle Mode is enabled.")
                }
                if path.contains(".framework/") || path.hasSuffix(".dylib") || path.hasSuffix(".so") {
                    throw AgentWorkspaceError.unsupported("Binary framework mutation is not enabled in this build.")
                }
            }

            _ = try BundlePatchStore.shared.recordBackup(
                workspaceID: record.id,
                relativePath: path,
                sourceURL: sourceURL,
                operation: operation
            )
        }
    }

    private func workspaceRootURL(for record: AgentWorkspaceRecord) -> URL {
        URL(fileURLWithPath: record.rootPath, isDirectory: true)
    }

    private func updateWorkspace(id: String, mutate: (inout AgentWorkspaceRecord) -> Void) {
        guard let index = workspaces.firstIndex(where: { $0.id == id }) else { return }
        var record = workspaces[index]
        mutate(&record)
        workspaces[index] = record
        persistState()
    }

    private func makeFileEntry(for url: URL, rootURL: URL) throws -> AgentFileEntry {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey])
        return AgentFileEntry(
            id: AgentPathHelper.relativePath(for: url, rootURL: rootURL),
            path: AgentPathHelper.relativePath(for: url, rootURL: rootURL),
            isDirectory: values.isDirectory ?? false,
            sizeBytes: Int64(values.fileSize ?? 0),
            modifiedAt: values.contentModificationDate
        )
    }

    private func recursiveEntries(in root: URL, rootURL: URL, limit: Int) throws -> [AgentFileEntry] {
        let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )
        var entries: [AgentFileEntry] = []
        while let fileURL = enumerator?.nextObject() as? URL, entries.count < limit {
            entries.append(try makeFileEntry(for: fileURL, rootURL: rootURL))
        }
        return entries.sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
    }

    private func allFileURLs(in rootURL: URL) throws -> [URL] {
        let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        var urls: [URL] = []
        while let fileURL = enumerator?.nextObject() as? URL {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
            if values.isRegularFile == true {
                urls.append(fileURL)
            }
        }
        return urls
    }

    private func copyDirectoryContents(from sourceURL: URL, to destinationURL: URL) throws {
        try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        let enumerator = fileManager.enumerator(
            at: sourceURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        while let fileURL = enumerator?.nextObject() as? URL {
            let relativePath = AgentPathHelper.relativePath(for: fileURL, rootURL: sourceURL)
            let destination = destinationURL.appendingPathComponent(relativePath)
            let values = try fileURL.resourceValues(forKeys: [.isDirectoryKey])
            if values.isDirectory == true {
                try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
            } else {
                try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fileManager.fileExists(atPath: destination.path) {
                    try fileManager.removeItem(at: destination)
                }
                try fileManager.copyItem(at: fileURL, to: destination)
            }
        }
    }

    private func removeDirectoryContents(at directoryURL: URL) throws {
        guard fileManager.fileExists(atPath: directoryURL.path) else { return }
        let children = try fileManager.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil)
        for child in children {
            try fileManager.removeItem(at: child)
        }
    }

    private func fileFingerprintMap(rootURL: URL) throws -> [String: String] {
        let urls = try allFileURLs(in: rootURL)
        var fingerprints: [String: String] = [:]
        for fileURL in urls {
            let data = try Data(contentsOf: fileURL)
            let digest = SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
            fingerprints[AgentPathHelper.relativePath(for: fileURL, rootURL: rootURL)] = digest
        }
        return fingerprints
    }

    private func materializeWorkspaceSeed(into rootURL: URL) throws {
        try materializeFiles(AgentWorkspaceSeed.files, into: rootURL)
    }

    private func materializeFiles(_ files: [String: String], into rootURL: URL) throws {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        for (relativePath, content) in files {
            let fileURL = rootURL.appendingPathComponent(relativePath)
            try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
        }
    }

    private func dependencyLines(from packageURL: URL) -> [String] {
        guard let content = try? String(contentsOf: packageURL, encoding: .utf8) else {
            return []
        }

        return content
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix(".package(") || $0.hasPrefix(".product(") }
    }
}

@MainActor
final class AgentApprovalCenter: ObservableObject {
    static let shared = AgentApprovalCenter()

    @Published private(set) var requests: [AgentApprovalRequest] = []

    private struct PendingHandler {
        let request: AgentApprovalRequest
        let handler: () async -> AgentExecutionResult
    }

    private var pendingHandlers: [UUID: PendingHandler] = [:]

    private init() {}

    func enqueue(
        toolID: String,
        title: String,
        summary: String,
        workspaceID: String?,
        arguments: AgentJSONValue,
        handler: @escaping () async -> AgentExecutionResult
    ) -> AgentApprovalRequest {
        let request = AgentApprovalRequest(
            id: UUID(),
            toolID: toolID,
            title: title,
            summary: summary,
            workspaceID: workspaceID,
            createdAt: .now,
            arguments: arguments,
            status: .pending
        )
        requests.append(request)
        pendingHandlers[request.id] = PendingHandler(request: request, handler: handler)
        AgentLogStore.shared.record(
            .approval,
            level: .warning,
            title: "Approval Required",
            message: summary,
            metadata: [
                "approval_id": request.id.uuidString,
                "tool_id": toolID,
                "workspace_id": workspaceID ?? ""
            ]
        )
        return request
    }

    func approve(id: UUID) async -> AgentExecutionResult {
        guard let pending = pendingHandlers.removeValue(forKey: id) else {
            return .failure(toolID: "approval", message: "The approval request no longer exists.")
        }
        requests.removeAll { $0.id == id }
        AgentLogStore.shared.record(
            .approval,
            title: "Approval Granted",
            message: pending.request.summary,
            metadata: [
                "approval_id": pending.request.id.uuidString,
                "tool_id": pending.request.toolID,
                "workspace_id": pending.request.workspaceID ?? ""
            ]
        )
        return await pending.handler()
    }

    func reject(id: UUID) -> AgentExecutionResult {
        guard let pending = pendingHandlers.removeValue(forKey: id) else {
            return .failure(toolID: "approval", message: "The approval request no longer exists.")
        }
        requests.removeAll { $0.id == id }
        AgentLogStore.shared.record(
            .approval,
            level: .warning,
            title: "Approval Rejected",
            message: pending.request.summary,
            metadata: [
                "approval_id": pending.request.id.uuidString,
                "tool_id": pending.request.toolID,
                "workspace_id": pending.request.workspaceID ?? ""
            ]
        )
        return .failure(toolID: pending.request.toolID, message: "The request was rejected by the user.")
    }
}

enum GitHubServiceError: LocalizedError {
    case invalidRepository
    case missingTokenForWrite
    case missingOAuthClientID
    case missingDeviceCode
    case invalidResponse
    case server(String)

    var errorDescription: String? {
        switch self {
        case .invalidRepository:
            return "GitHub repository values must use the form owner/repo."
        case .missingTokenForWrite:
            return "A GitHub token is required for write operations."
        case .missingOAuthClientID:
            return "A GitHub OAuth client ID is required for device-flow login."
        case .missingDeviceCode:
            return "The GitHub device flow is missing its device code."
        case .invalidResponse:
            return "GitHub returned an invalid response."
        case .server(let message):
            return message
        }
    }
}

@MainActor
final class GitHubService {
    static let shared = GitHubService()

    private struct RepositoryID {
        let owner: String
        let name: String
        var fullName: String { "\(owner)/\(name)" }
    }

    struct WorkspaceRefresh {
        let reference: String
        let files: [String: String]
    }

    struct RepositorySnapshot {
        let repository: String
        let reference: String
        let files: [String: String]
    }

    private init() {}

    func repositorySummary(repository: String) async throws -> AgentJSONValue {
        let repo = try parseRepository(repository)
        let response = try await requestJSON(
            components: ["repos", repo.owner, repo.name],
            queryItems: []
        )
        guard let json = response as? [String: Any] else {
            throw GitHubServiceError.invalidResponse
        }

        let defaultBranch = (json["default_branch"] as? String)?.nonEmpty ?? "main"
        let license = (json["license"] as? [String: Any])?["spdx_id"] as? String

        return .object([
            "repository": .string(repo.fullName),
            "default_branch": .string(defaultBranch),
            "private": .bool(json["private"] as? Bool ?? false),
            "description": .string((json["description"] as? String) ?? ""),
            "stars": .int(json["stargazers_count"] as? Int ?? 0),
            "forks": .int(json["forks_count"] as? Int ?? 0),
            "open_issues": .int(json["open_issues_count"] as? Int ?? 0),
            "html_url": .string((json["html_url"] as? String) ?? ""),
            "license": .string(license ?? "")
        ])
    }

    func startDeviceFlow(clientID: String?) async throws -> AgentJSONValue {
        let resolvedClientID = clientID?.trimmedForLookup.nonEmpty ?? AppSettings.shared.agentGitHubClientID.nonEmpty
        guard let resolvedClientID else {
            throw GitHubServiceError.missingOAuthClientID
        }

        let response = try await requestFormJSON(
            host: "github.com",
            path: "/login/device/code",
            form: [
                "client_id": resolvedClientID,
                "scope": "repo read:user workflow"
            ]
        )
        guard let json = response as? [String: Any] else {
            throw GitHubServiceError.invalidResponse
        }

        let deviceCode = (json["device_code"] as? String) ?? ""
        AppSettings.shared.agentGitHubDeviceCode = deviceCode
        AppSettings.shared.agentGitHubUserCode = (json["user_code"] as? String) ?? ""
        AppSettings.shared.agentGitHubVerificationURL = (json["verification_uri"] as? String) ?? (json["verification_uri_complete"] as? String) ?? ""
        AppSettings.shared.agentGitHubDeviceFlowExpiresAt = Date().addingTimeInterval(Double(json["expires_in"] as? Int ?? 900))

        AgentLogStore.shared.record(.github, title: "GitHub Device Flow Started", message: AppSettings.shared.agentGitHubVerificationURL)

        return AgentJSONValue.fromFoundation(json) ?? .object([:])
    }

    func pollDeviceFlowToken(clientID: String?) async throws -> AgentJSONValue {
        let resolvedClientID = clientID?.trimmedForLookup.nonEmpty ?? AppSettings.shared.agentGitHubClientID.nonEmpty
        guard let resolvedClientID else {
            throw GitHubServiceError.missingOAuthClientID
        }
        let deviceCode = AppSettings.shared.agentGitHubDeviceCode.trimmedForLookup
        guard !deviceCode.isEmpty else {
            throw GitHubServiceError.missingDeviceCode
        }

        let response = try await requestFormJSON(
            host: "github.com",
            path: "/login/oauth/access_token",
            form: [
                "client_id": resolvedClientID,
                "device_code": deviceCode,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code"
            ]
        )
        guard let json = response as? [String: Any] else {
            throw GitHubServiceError.invalidResponse
        }

        if let token = (json["access_token"] as? String)?.nonEmpty {
            AppSettings.shared.agentGitHubToken = token
            AppSettings.shared.agentGitHubDeviceCode = ""
            AppSettings.shared.agentGitHubUserCode = ""
            AppSettings.shared.agentGitHubVerificationURL = ""
            AppSettings.shared.agentGitHubDeviceFlowExpiresAt = nil
            AgentLogStore.shared.record(.github, title: "GitHub Device Flow Succeeded", message: "Stored GitHub access token from device flow.")
        }

        return AgentJSONValue.fromFoundation(json) ?? .object([:])
    }

    func searchRepositories(query: String, limit: Int = 10) async throws -> AgentJSONValue {
        let response = try await requestJSON(
            components: ["search", "repositories"],
            queryItems: [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "per_page", value: String(max(1, min(limit, 20))))
            ]
        )
        guard let json = response as? [String: Any],
              let items = json["items"] as? [[String: Any]]
        else {
            throw GitHubServiceError.invalidResponse
        }
        return .object([
            "items": .array(items.map { item in
                .object([
                    "full_name": .string((item["full_name"] as? String) ?? ""),
                    "description": .string((item["description"] as? String) ?? ""),
                    "default_branch": .string((item["default_branch"] as? String) ?? ""),
                    "html_url": .string((item["html_url"] as? String) ?? ""),
                    "stars": .int(item["stargazers_count"] as? Int ?? 0)
                ])
            })
        ])
    }

    func searchCode(query: String, repository: String?, limit: Int = 10) async throws -> AgentJSONValue {
        let scopedQuery: String
        if let repository = repository?.nonEmpty {
            scopedQuery = "\(query) repo:\(repository)"
        } else {
            scopedQuery = query
        }
        let response = try await requestJSON(
            components: ["search", "code"],
            queryItems: [
                URLQueryItem(name: "q", value: scopedQuery),
                URLQueryItem(name: "per_page", value: String(max(1, min(limit, 20))))
            ]
        )
        guard let json = response as? [String: Any],
              let items = json["items"] as? [[String: Any]]
        else {
            throw GitHubServiceError.invalidResponse
        }
        return .object([
            "items": .array(items.map { item in
                let repoName = ((item["repository"] as? [String: Any])?["full_name"] as? String) ?? ""
                return .object([
                    "name": .string((item["name"] as? String) ?? ""),
                    "path": .string((item["path"] as? String) ?? ""),
                    "repository": .string(repoName),
                    "html_url": .string((item["html_url"] as? String) ?? "")
                ])
            })
        ])
    }

    func getFile(repository: String, path: String, ref: String?) async throws -> AgentJSONValue {
        let repo = try parseRepository(repository)
        let reference = try await resolvedReference(ref, repository: repository)
        let content = try await fetchTextFile(repository: repo, path: path, ref: reference)
        return .object([
            "repository": .string(repo.fullName),
            "path": .string(path),
            "ref": .string(reference),
            "content": .string(content)
        ])
    }

    func listIssues(repository: String, state: String = "open", limit: Int = 20) async throws -> AgentJSONValue {
        let repo = try parseRepository(repository)
        let response = try await requestJSON(
            components: ["repos", repo.owner, repo.name, "issues"],
            queryItems: [
                URLQueryItem(name: "state", value: state),
                URLQueryItem(name: "per_page", value: String(max(1, min(limit, 50))))
            ],
            requiresAuthentication: false
        )
        guard let array = response as? [[String: Any]] else {
            throw GitHubServiceError.invalidResponse
        }
        return .object([
            "repository": .string(repo.fullName),
            "issues": .array(array.compactMap { item in
                if item["pull_request"] != nil { return nil }
                return .object([
                    "number": .int(item["number"] as? Int ?? 0),
                    "title": .string((item["title"] as? String) ?? ""),
                    "state": .string((item["state"] as? String) ?? ""),
                    "html_url": .string((item["html_url"] as? String) ?? "")
                ])
            })
        ])
    }

    func listPullRequests(repository: String, state: String = "open", limit: Int = 20) async throws -> AgentJSONValue {
        let repo = try parseRepository(repository)
        let response = try await requestJSON(
            components: ["repos", repo.owner, repo.name, "pulls"],
            queryItems: [
                URLQueryItem(name: "state", value: state),
                URLQueryItem(name: "per_page", value: String(max(1, min(limit, 50))))
            ]
        )
        guard let array = response as? [[String: Any]] else {
            throw GitHubServiceError.invalidResponse
        }
        return .object([
            "repository": .string(repo.fullName),
            "pulls": .array(array.map { item in
                .object([
                    "number": .int(item["number"] as? Int ?? 0),
                    "title": .string((item["title"] as? String) ?? ""),
                    "state": .string((item["state"] as? String) ?? ""),
                    "head": .string(((item["head"] as? [String: Any])?["ref"] as? String) ?? ""),
                    "base": .string(((item["base"] as? [String: Any])?["ref"] as? String) ?? ""),
                    "html_url": .string((item["html_url"] as? String) ?? "")
                ])
            })
        ])
    }

    func createBranch(repository: String, branch: String, baseBranch: String?) async throws -> AgentJSONValue {
        let repo = try parseRepository(repository)
        let resolvedBase = try await resolvedReference(baseBranch, repository: repository)
        let baseRef = try await branchReference(repository: repo, branch: resolvedBase)
        let baseSHA = baseRef["object"]?.objectValue?["sha"]?.stringValue ?? ""
        _ = try await ensureBranch(repository: repo, branch: branch, fallbackSHA: baseSHA)
        AgentLogStore.shared.record(.git, title: "GitHub Branch Ready", message: "\(repo.fullName): \(branch)")
        return .object([
            "repository": .string(repo.fullName),
            "branch": .string(branch),
            "base_branch": .string(resolvedBase),
            "base_sha": .string(baseSHA)
        ])
    }

    func createPullRequest(repository: String, title: String, body: String, head: String, base: String?) async throws -> AgentJSONValue {
        let repo = try parseRepository(repository)
        let resolvedBase = try await resolvedReference(base, repository: repository)
        let response = try await requestJSON(
            components: ["repos", repo.owner, repo.name, "pulls"],
            queryItems: [],
            method: "POST",
            body: [
                "title": title,
                "body": body,
                "head": head,
                "base": resolvedBase
            ],
            requiresAuthentication: true
        )
        guard let json = response as? [String: Any] else {
            throw GitHubServiceError.invalidResponse
        }
        return .object([
            "number": .int(json["number"] as? Int ?? 0),
            "html_url": .string((json["html_url"] as? String) ?? ""),
            "head": .string(head),
            "base": .string(resolvedBase)
        ])
    }

    func workflowRuns(repository: String, limit: Int = 10) async throws -> AgentJSONValue {
        let repo = try parseRepository(repository)
        let response = try await requestJSON(
            components: ["repos", repo.owner, repo.name, "actions", "runs"],
            queryItems: [URLQueryItem(name: "per_page", value: String(max(1, min(limit, 20))))]
        )
        guard
            let json = response as? [String: Any],
            let runs = json["workflow_runs"] as? [[String: Any]]
        else {
            throw GitHubServiceError.invalidResponse
        }

        let values = runs.map { run in
            AgentJSONValue.object([
                "id": .int(run["id"] as? Int ?? 0),
                "name": .string((run["name"] as? String) ?? ""),
                "status": .string((run["status"] as? String) ?? ""),
                "conclusion": .string((run["conclusion"] as? String) ?? ""),
                "event": .string((run["event"] as? String) ?? ""),
                "head_branch": .string((run["head_branch"] as? String) ?? ""),
                "html_url": .string((run["html_url"] as? String) ?? "")
            ])
        }

        return .object([
            "repository": .string(repo.fullName),
            "workflow_runs": .array(values)
        ])
    }

    func workflowRunLogs(repository: String, runID: Int) async throws -> AgentJSONValue {
        let repo = try parseRepository(repository)
        let response = try await requestRaw(
            host: "api.github.com",
            path: "/repos/\(repo.owner)/\(repo.name)/actions/runs/\(runID)/logs",
            method: "GET",
            requiresAuthentication: true,
            accept: "application/vnd.github+json"
        )
        let location = response.http.value(forHTTPHeaderField: "Location") ?? ""
        return .object([
            "repository": .string(repo.fullName),
            "run_id": .int(runID),
            "status": .int(response.http.statusCode),
            "location": .string(location),
            "resolved_url": .string(response.http.url?.absoluteString ?? "")
        ])
    }

    func workflowArtifacts(repository: String, runID: Int) async throws -> AgentJSONValue {
        let repo = try parseRepository(repository)
        let response = try await requestJSON(
            components: ["repos", repo.owner, repo.name, "actions", "runs", String(runID), "artifacts"],
            queryItems: []
        )
        guard let json = response as? [String: Any],
              let artifacts = json["artifacts"] as? [[String: Any]]
        else {
            throw GitHubServiceError.invalidResponse
        }
        return .object([
            "repository": .string(repo.fullName),
            "artifacts": .array(artifacts.map { artifact in
                .object([
                    "id": .int(artifact["id"] as? Int ?? 0),
                    "name": .string((artifact["name"] as? String) ?? ""),
                    "size_in_bytes": .int(artifact["size_in_bytes"] as? Int ?? 0),
                    "expired": .bool(artifact["expired"] as? Bool ?? false),
                    "archive_download_url": .string((artifact["archive_download_url"] as? String) ?? "")
                ])
            })
        ])
    }

    func rerunWorkflow(repository: String, runID: Int) async throws -> AgentJSONValue {
        let repo = try parseRepository(repository)
        _ = try await requestJSON(
            components: ["repos", repo.owner, repo.name, "actions", "runs", String(runID), "rerun"],
            queryItems: [],
            method: "POST",
            body: [:],
            requiresAuthentication: true
        )
        AgentLogStore.shared.record(.githubActions, title: "GitHub Workflow Rerun Requested", message: "\(repo.fullName) run \(runID)")
        return .object([
            "repository": .string(repo.fullName),
            "run_id": .int(runID),
            "rerun_requested": .bool(true)
        ])
    }

    func fetchWorkspaceFiles(repository: String, ref: String?) async throws -> WorkspaceRefresh {
        let repo = try parseRepository(repository)
        let reference = try await resolvedReference(ref, repository: repository)
        let treeResponse = try await requestJSON(
            components: ["repos", repo.owner, repo.name, "git", "trees", reference],
            queryItems: [URLQueryItem(name: "recursive", value: "1")]
        )
        guard
            let json = treeResponse as? [String: Any],
            let tree = json["tree"] as? [[String: Any]]
        else {
            throw GitHubServiceError.invalidResponse
        }

        let filteredPaths = tree.compactMap { item -> String? in
            guard item["type"] as? String == "blob" else { return nil }
            guard let path = item["path"] as? String else { return nil }
            return shouldMirror(path: path) ? path : nil
        }

        var files: [String: String] = [:]
        for path in filteredPaths.sorted() {
            let content = try await fetchTextFile(repository: repo, path: path, ref: reference)
            files[path] = content
        }

        return WorkspaceRefresh(reference: reference, files: files)
    }

    func fetchRepositorySnapshot(repository: String, ref: String?) async throws -> RepositorySnapshot {
        let repo = try parseRepository(repository)
        let reference = try await resolvedReference(ref, repository: repository)
        let treeResponse = try await requestJSON(
            components: ["repos", repo.owner, repo.name, "git", "trees", reference],
            queryItems: [URLQueryItem(name: "recursive", value: "1")]
        )
        guard let json = treeResponse as? [String: Any],
              let tree = json["tree"] as? [[String: Any]]
        else {
            throw GitHubServiceError.invalidResponse
        }

        var files: [String: String] = [:]
        for item in tree {
            guard item["type"] as? String == "blob",
                  let path = item["path"] as? String,
                  let size = item["size"] as? Int,
                  size <= 512_000
            else {
                continue
            }
            if let content = try? await fetchTextFile(repository: repo, path: path, ref: reference) {
                files[path] = content
            }
        }

        return RepositorySnapshot(repository: repo.fullName, reference: reference, files: files)
    }

    func pushWorkspaceSnapshot(
        repository: String,
        branch: String?,
        message: String,
        workspace: AgentWorkspaceRecord
    ) async throws -> AgentJSONValue {
        let token = AppSettings.shared.agentGitHubToken.trimmedForLookup
        guard !token.isEmpty else {
            throw GitHubServiceError.missingTokenForWrite
        }

        let repo = try parseRepository(repository)
        let repoSummary = try await repositorySummary(repository: repository)
        let repoInfo = repoSummary.objectValue ?? [:]
        let defaultBranch = repoInfo["default_branch"]?.stringValue ?? "main"
        let targetBranch = branch?.nonEmpty
            ?? "agent/\(Date().formatted(.dateTime.year().month().day().hour().minute()))".replacingOccurrences(of: " ", with: "-")

        let baseRef = try await branchReference(repository: repo, branch: defaultBranch)
        let targetRef = try await ensureBranch(
            repository: repo,
            branch: targetBranch,
            fallbackSHA: baseRef["object"]?.objectValue?["sha"]?.stringValue ?? ""
        )
        let baseCommitSHA = targetRef["object"]?.objectValue?["sha"]?.stringValue ?? ""
        let commit = try await requestJSON(
            components: ["repos", repo.owner, repo.name, "git", "commits", baseCommitSHA],
            queryItems: [],
            requiresAuthentication: true
        )
        guard
            let commitObject = commit as? [String: Any],
            let baseTreeSHA = ((commitObject["tree"] as? [String: Any])?["sha"] as? String)?.nonEmpty
        else {
            throw GitHubServiceError.invalidResponse
        }

        let workspaceRoot = URL(fileURLWithPath: workspace.rootPath, isDirectory: true)
        let filePaths = try AgentWorkspaceManager.shared.listFiles(workspaceID: workspace.id, relativePath: "", recursive: true, limit: 10_000)
            .filter { !$0.isDirectory }
            .map(\.path)

        var treeEntries: [[String: Any]] = []
        for relativePath in filePaths.sorted() {
            let fileURL = workspaceRoot.appendingPathComponent(relativePath)
            guard let data = try? Data(contentsOf: fileURL) else {
                continue
            }
            let blob = try await createBlob(repository: repo, data: data)
            treeEntries.append([
                "path": relativePath,
                "mode": "100644",
                "type": "blob",
                "sha": blob
            ])
        }

        let treeResponse = try await requestJSON(
            components: ["repos", repo.owner, repo.name, "git", "trees"],
            queryItems: [],
            method: "POST",
            body: [
                "base_tree": baseTreeSHA,
                "tree": treeEntries
            ],
            requiresAuthentication: true
        )
        guard let treeJSON = treeResponse as? [String: Any],
              let treeSHA = (treeJSON["sha"] as? String)?.nonEmpty
        else {
            throw GitHubServiceError.invalidResponse
        }

        let commitResponse = try await requestJSON(
            components: ["repos", repo.owner, repo.name, "git", "commits"],
            queryItems: [],
            method: "POST",
            body: [
                "message": message,
                "tree": treeSHA,
                "parents": [baseCommitSHA]
            ],
            requiresAuthentication: true
        )
        guard let commitJSON = commitResponse as? [String: Any],
              let newCommitSHA = (commitJSON["sha"] as? String)?.nonEmpty
        else {
            throw GitHubServiceError.invalidResponse
        }

        _ = try await requestJSON(
            components: ["repos", repo.owner, repo.name, "git", "refs", "heads", targetBranch],
            queryItems: [],
            method: "PATCH",
            body: [
                "sha": newCommitSHA,
                "force": false
            ],
            requiresAuthentication: true
        )

        return .object([
            "repository": .string(repo.fullName),
            "branch": .string(targetBranch),
            "commit_sha": .string(newCommitSHA),
            "commit_url": .string("https://github.com/\(repo.fullName)/commit/\(newCommitSHA)"),
            "updated_files": .int(treeEntries.count)
        ])
    }

    private func shouldMirror(path: String) -> Bool {
        AgentWorkspaceManager.shouldMirrorPath(path)
    }

    private func defaultBranch(repository: String) async throws -> String {
        let summary = try await repositorySummary(repository: repository)
        return summary.objectValue?["default_branch"]?.stringValue ?? "main"
    }

    private func resolvedReference(_ candidate: String?, repository: String) async throws -> String {
        if let candidate = candidate?.nonEmpty {
            return candidate
        }
        return try await defaultBranch(repository: repository)
    }

    private func fetchTextFile(repository: RepositoryID, path: String, ref: String) async throws -> String {
        let response = try await requestJSON(
            components: ["repos", repository.owner, repository.name, "contents"] + path.split(separator: "/").map(String.init),
            queryItems: [URLQueryItem(name: "ref", value: ref)]
        )
        guard
            let json = response as? [String: Any],
            let encoded = (json["content"] as? String)?.replacingOccurrences(of: "\n", with: ""),
            let data = Data(base64Encoded: encoded),
            let content = String(data: data, encoding: .utf8)
        else {
            throw GitHubServiceError.invalidResponse
        }
        return content
    }

    private func createBlob(repository: RepositoryID, data: Data) async throws -> String {
        let response = try await requestJSON(
            components: ["repos", repository.owner, repository.name, "git", "blobs"],
            queryItems: [],
            method: "POST",
            body: [
                "content": data.base64EncodedString(),
                "encoding": "base64"
            ],
            requiresAuthentication: true
        )
        guard let json = response as? [String: Any],
              let sha = (json["sha"] as? String)?.nonEmpty
        else {
            throw GitHubServiceError.invalidResponse
        }
        return sha
    }

    private func branchReference(repository: RepositoryID, branch: String) async throws -> [String: AgentJSONValue] {
        let response = try await requestJSON(
            components: ["repos", repository.owner, repository.name, "git", "refs", "heads", branch],
            queryItems: [],
            requiresAuthentication: true
        )
        guard let json = response as? [String: Any],
              let mapped = AgentJSONValue.fromFoundation(json)?.objectValue
        else {
            throw GitHubServiceError.invalidResponse
        }
        return mapped
    }

    private func ensureBranch(repository: RepositoryID, branch: String, fallbackSHA: String) async throws -> [String: AgentJSONValue] {
        do {
            return try await branchReference(repository: repository, branch: branch)
        } catch {
            guard !fallbackSHA.isEmpty else {
                throw error
            }

            _ = try await requestJSON(
                components: ["repos", repository.owner, repository.name, "git", "refs"],
                queryItems: [],
                method: "POST",
                body: [
                    "ref": "refs/heads/\(branch)",
                    "sha": fallbackSHA
                ],
                requiresAuthentication: true
            )

            return try await branchReference(repository: repository, branch: branch)
        }
    }

    private func parseRepository(_ rawValue: String) throws -> RepositoryID {
        let trimmed = rawValue.trimmedForLookup
        let pieces = trimmed.split(separator: "/").map(String.init)
        guard pieces.count == 2, pieces.allSatisfy({ !$0.trimmedForLookup.isEmpty }) else {
            throw GitHubServiceError.invalidRepository
        }
        return RepositoryID(owner: pieces[0], name: pieces[1])
    }

    private func requestJSON(
        components: [String],
        queryItems: [URLQueryItem],
        method: String = "GET",
        body: [String: Any]? = nil,
        requiresAuthentication: Bool = false
    ) async throws -> Any {
        let url = try makeURL(components: components, queryItems: queryItems)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("OllamaKit-PowerAgent", forHTTPHeaderField: "User-Agent")

        let token = AppSettings.shared.agentGitHubToken.trimmedForLookup
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        } else if requiresAuthentication {
            throw GitHubServiceError.missingTokenForWrite
        }

        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GitHubServiceError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw GitHubServiceError.server(message)
        }
        if data.isEmpty {
            return [:]
        }
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    private func requestFormJSON(
        host: String,
        path: String,
        form: [String: String]
    ) async throws -> Any {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = path
        guard let url = components.url else {
            throw GitHubServiceError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("OllamaKit-PowerAgent", forHTTPHeaderField: "User-Agent")
        request.httpBody = form
            .map { key, value in
                let encodedKey = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? key
                let encodedValue = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
                return "\(encodedKey)=\(encodedValue)"
            }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GitHubServiceError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw GitHubServiceError.server(message)
        }
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    private func requestRaw(
        host: String,
        path: String,
        method: String,
        requiresAuthentication: Bool,
        accept: String
    ) async throws -> (data: Data, http: HTTPURLResponse) {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = path
        guard let url = components.url else {
            throw GitHubServiceError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("OllamaKit-PowerAgent", forHTTPHeaderField: "User-Agent")

        let token = AppSettings.shared.agentGitHubToken.trimmedForLookup
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        } else if requiresAuthentication {
            throw GitHubServiceError.missingTokenForWrite
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GitHubServiceError.invalidResponse
        }
        guard (200..<400).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw GitHubServiceError.server(message)
        }
        return (data, http)
    }

    private func makeURL(components pathComponents: [String], queryItems: [URLQueryItem]) throws -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.github.com"
        let encodedPath = pathComponents
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? $0 }
            .joined(separator: "/")
        components.path = "/" + encodedPath
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components.url else {
            throw GitHubServiceError.invalidResponse
        }
        return url
    }
}

enum JavaScriptRuntimeService {
    static var isAvailable: Bool {
#if canImport(JavaScriptCore)
        return true
#else
        return false
#endif
    }

    static var availabilityReason: String? {
        isAvailable ? nil : "Unavailable in current IPA."
    }

    static func run(script: String, input: AgentJSONValue?) throws -> AgentJSONValue {
#if canImport(JavaScriptCore)
        guard let context = JSContext() else {
            throw AgentWorkspaceError.unsupported("JavaScriptCore is unavailable on this build.")
        }

        var consoleLines: [String] = []
        let console = JSValue(newObjectIn: context)

        let logBlock: @convention(block) (JSValue?) -> Void = { value in
            consoleLines.append(value?.toString() ?? "undefined")
        }
        console?.setObject(logBlock, forKeyedSubscript: "log" as NSString)
        context.setObject(console, forKeyedSubscript: "console" as NSString)
        context.exceptionHandler = { _, exception in
            if let exception {
                consoleLines.append("Exception: \(exception)")
            }
        }
        if let input {
            context.setObject(input.foundationObject, forKeyedSubscript: "input" as NSString)
        }

        let result = context.evaluateScript(script)
        if let exception = context.exception?.toString().nonEmpty {
            throw AgentWorkspaceError.unsupported(exception)
        }

        return .object([
            "result": AgentJSONValue.fromFoundation(result?.toObject()) ?? .null,
            "console": .array(consoleLines.map(AgentJSONValue.string))
        ])
#else
        throw AgentWorkspaceError.unsupported("JavaScript execution is unavailable on this build.")
#endif
    }
}

enum EmbeddedRuntimeBridgeSupport {
    typealias RuntimeBridgeFunction = @convention(c) (
        UnsafePointer<CChar>,
        UnsafePointer<CChar>?,
        UnsafePointer<CChar>?
    ) -> UnsafeMutablePointer<CChar>?

    struct BridgeDescriptor {
        let runtimeID: String
        let frameworkName: String
        let binaryName: String
        let symbolName: String
        let title: String
        let unavailableReason: String
    }

    struct BridgeAvailability {
        let bundled: Bool
        let bridgeLoaded: Bool
        let resourceBundlePresent: Bool
        let available: Bool
        let state: RuntimePackageAvailabilityState
        let reason: String?
        let version: String?
        let supportedOperations: [String]
    }

    private struct Resolution {
        let function: RuntimeBridgeFunction?
        let bundled: Bool
        let bridgeLoaded: Bool
        let resourceBundlePresent: Bool
        let reason: String?
        let version: String?
        let supportedOperations: [String]
    }

    private struct CandidateLocation {
        let binaryURL: URL
        let frameworkURL: URL?
    }

    private static func candidateLocations(for descriptor: BridgeDescriptor) -> [CandidateLocation] {
        let fm = FileManager.default
        var locations: [CandidateLocation] = []

        if let privateFrameworks = Bundle.main.privateFrameworksURL {
            let frameworkURL = privateFrameworks.appendingPathComponent("\(descriptor.frameworkName).framework", isDirectory: true)
            locations.append(
                CandidateLocation(
                    binaryURL: frameworkURL.appendingPathComponent(descriptor.binaryName),
                    frameworkURL: frameworkURL
                )
            )
        }

        let frameworks = Bundle.main.bundleURL.appendingPathComponent("Frameworks", isDirectory: true)
        let frameworkURL = frameworks.appendingPathComponent("\(descriptor.frameworkName).framework", isDirectory: true)
        locations.append(
            CandidateLocation(
                binaryURL: frameworkURL.appendingPathComponent(descriptor.binaryName),
                frameworkURL: frameworkURL
            )
        )

        if let supportURL = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) {
            let frameworkRoot = supportURL
                .appendingPathComponent("EmbeddedRuntimes", isDirectory: true)
                .appendingPathComponent("\(descriptor.frameworkName).framework", isDirectory: true)

            locations.append(
                CandidateLocation(
                    binaryURL: frameworkRoot.appendingPathComponent(descriptor.binaryName),
                    frameworkURL: frameworkRoot
                )
            )

            locations.append(
                CandidateLocation(
                    binaryURL: supportURL
                        .appendingPathComponent("EmbeddedRuntimes", isDirectory: true)
                        .appendingPathComponent(descriptor.binaryName),
                    frameworkURL: nil
                )
            )
        }

        return locations
    }

    private static func manifestRecord(for descriptor: BridgeDescriptor, frameworkURL: URL?) -> EmbeddedRuntimeManifestRecord? {
        guard let frameworkURL else { return nil }
        let manifestURL = frameworkURL
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("EmbeddedRuntimeManifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(EmbeddedRuntimeManifest.self, from: data) else {
            return nil
        }
        return manifest.runtimes.first {
            $0.id == descriptor.runtimeID || $0.frameworkName == descriptor.frameworkName
        }
    }

    private static func requiredResourcesPresent(
        record: EmbeddedRuntimeManifestRecord,
        frameworkURL: URL?
    ) -> Bool {
        guard let frameworkURL else { return false }

        let fm = FileManager.default
        let resourcePathsPresent = record.requiredResources.allSatisfy { relativePath in
            fm.fileExists(atPath: frameworkURL.appendingPathComponent(relativePath).path)
        }

        let supportFrameworksPresent = record.supportFrameworks.allSatisfy { name in
            let appFrameworks = Bundle.main.bundleURL.appendingPathComponent("Frameworks", isDirectory: true)
            let mainPath = appFrameworks.appendingPathComponent(name).path
            let privatePath = Bundle.main.privateFrameworksURL?.appendingPathComponent(name).path
            return fm.fileExists(atPath: mainPath) || (privatePath.map { fm.fileExists(atPath: $0) } ?? false)
        }

        return resourcePathsPresent && supportFrameworksPresent && record.resourceBundlePresent
    }

    static func isAvailable(_ descriptor: BridgeDescriptor) -> Bool {
        let resolution = resolveStatus(descriptor)
        return resolution.function != nil && resolution.resourceBundlePresent
    }

    static func availabilityReason(_ descriptor: BridgeDescriptor) -> String? {
        health(descriptor).reason
    }

    static func health(_ descriptor: BridgeDescriptor) -> BridgeAvailability {
        let resolution = resolveStatus(descriptor)
        let state: RuntimePackageAvailabilityState
        if !resolution.bundled {
            state = .unavailableInCurrentIPA
        } else if !resolution.bridgeLoaded || !resolution.resourceBundlePresent {
            state = .bridgeLoadFailed
        } else {
            state = .installed
        }

        return BridgeAvailability(
            bundled: resolution.bundled,
            bridgeLoaded: resolution.bridgeLoaded,
            resourceBundlePresent: resolution.resourceBundlePresent,
            available: resolution.bundled && resolution.bridgeLoaded && resolution.resourceBundlePresent,
            state: state,
            reason: resolution.reason,
            version: resolution.version,
            supportedOperations: resolution.supportedOperations
        )
    }

    private static func resolveFunction(_ descriptor: BridgeDescriptor) -> RuntimeBridgeFunction? {
        resolveStatus(descriptor).function
    }

    private static func resolveStatus(_ descriptor: BridgeDescriptor) -> Resolution {
        var foundBinary = false
        var lastErrorMessage: String?
        var lastVersion: String?
        var lastSupportedOperations: [String] = []
        var resourcesPresent = false

        for candidate in candidateLocations(for: descriptor) {
            let path = candidate.binaryURL.path
            guard FileManager.default.fileExists(atPath: path) else { continue }
            foundBinary = true

            guard let manifestRecord = manifestRecord(for: descriptor, frameworkURL: candidate.frameworkURL) else {
                lastErrorMessage = "Found \(descriptor.title), but the embedded runtime manifest is missing."
                continue
            }

            lastVersion = manifestRecord.version
            lastSupportedOperations = manifestRecord.supportedOperations
            resourcesPresent = requiredResourcesPresent(record: manifestRecord, frameworkURL: candidate.frameworkURL)
            guard resourcesPresent else {
                lastErrorMessage = "Found \(descriptor.title), but required runtime resources are missing."
                continue
            }

            let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL)
            guard let handle else {
                if let errorPointer = dlerror() {
                    lastErrorMessage = String(cString: errorPointer)
                } else {
                    lastErrorMessage = "Found \(descriptor.title), but the runtime bundle could not be opened."
                }
                continue
            }

            guard let symbol = dlsym(handle, descriptor.symbolName) else {
                if let errorPointer = dlerror() {
                    lastErrorMessage = String(cString: errorPointer)
                } else {
                    lastErrorMessage = "Found \(descriptor.title), but the bridge symbol \(descriptor.symbolName) could not be resolved."
                }
                dlclose(handle)
                continue
            }

            return Resolution(
                function: unsafeBitCast(symbol, to: RuntimeBridgeFunction.self),
                bundled: true,
                bridgeLoaded: true,
                resourceBundlePresent: true,
                reason: nil,
                version: manifestRecord.version,
                supportedOperations: manifestRecord.supportedOperations
            )
        }

        guard foundBinary else {
            return Resolution(
                function: nil,
                bundled: false,
                bridgeLoaded: false,
                resourceBundlePresent: false,
                reason: "Unavailable in current IPA.",
                version: nil,
                supportedOperations: []
            )
        }

        let message = lastErrorMessage?.nonEmpty
            ?? "Found \(descriptor.title), but the embedded runtime bridge failed to load."
        return Resolution(
            function: nil,
            bundled: true,
            bridgeLoaded: false,
            resourceBundlePresent: resourcesPresent,
            reason: message,
            version: lastVersion,
            supportedOperations: lastSupportedOperations
        )
    }

    static func run(
        descriptor: BridgeDescriptor,
        script: String,
        input: AgentJSONValue?,
        workspaceRoot: String?
    ) throws -> AgentJSONValue {
        guard let function = resolveFunction(descriptor) else {
            throw AgentWorkspaceError.unsupported(descriptor.unavailableReason)
        }

        let encodedInput = input?.jsonStringRepresentation ?? "null"
        let encodedRoot = workspaceRoot ?? ""

        return try script.withCString { scriptCString in
            try encodedInput.withCString { inputCString in
                try encodedRoot.withCString { rootCString in
                    guard let rawPointer = function(scriptCString, inputCString, rootCString) else {
                        throw AgentWorkspaceError.unsupported("\(descriptor.title) returned no result.")
                    }

                    let ownedPointer = UnsafeMutablePointer<CChar>(rawPointer)
                    defer { free(ownedPointer) }

                    let jsonString = String(cString: ownedPointer)
                    guard let data = jsonString.data(using: .utf8) else {
                        throw AgentWorkspaceError.unsupported("\(descriptor.title) returned invalid UTF-8.")
                    }

                    return (try? JSONDecoder().decode(AgentJSONValue.self, from: data))
                        ?? .object([
                            "runtime": .string(descriptor.title),
                            "raw": .string(jsonString)
                        ])
                }
            }
        }
    }
}

private extension AgentJSONValue {
    var jsonStringRepresentation: String {
        if let data = try? JSONEncoder().encode(self),
           let string = String(data: data, encoding: .utf8) {
            return string
        }
        return "null"
    }
}

enum PythonRuntimeService {
    private static let descriptor = EmbeddedRuntimeBridgeSupport.BridgeDescriptor(
        runtimeID: "python",
        frameworkName: "OllamaKitPythonRuntime",
        binaryName: "OllamaKitPythonRuntime",
        symbolName: "OllamaKitPythonRunJSON",
        title: "Embedded Python",
        unavailableReason: "Unavailable in current IPA."
    )

    static var isAvailable: Bool {
        EmbeddedRuntimeBridgeSupport.isAvailable(descriptor)
    }

    static var availabilityReason: String? {
        EmbeddedRuntimeBridgeSupport.availabilityReason(descriptor)
    }

    static var health: EmbeddedRuntimeBridgeSupport.BridgeAvailability {
        EmbeddedRuntimeBridgeSupport.health(descriptor)
    }

    static func run(script: String, input: AgentJSONValue?, workspaceRoot: String?) throws -> AgentJSONValue {
        try EmbeddedRuntimeBridgeSupport.run(
            descriptor: descriptor,
            script: script,
            input: input,
            workspaceRoot: workspaceRoot
        )
    }
}

enum NodeRuntimeService {
    private static let descriptor = EmbeddedRuntimeBridgeSupport.BridgeDescriptor(
        runtimeID: "node",
        frameworkName: "OllamaKitNodeRuntime",
        binaryName: "OllamaKitNodeRuntime",
        symbolName: "OllamaKitNodeRunJSON",
        title: "Embedded Node.js",
        unavailableReason: "Unavailable in current IPA."
    )

    static var isAvailable: Bool {
        EmbeddedRuntimeBridgeSupport.isAvailable(descriptor)
    }

    static var availabilityReason: String? {
        EmbeddedRuntimeBridgeSupport.availabilityReason(descriptor)
    }

    static var health: EmbeddedRuntimeBridgeSupport.BridgeAvailability {
        EmbeddedRuntimeBridgeSupport.health(descriptor)
    }

    static func run(script: String, input: AgentJSONValue?, workspaceRoot: String?) throws -> AgentJSONValue {
        try EmbeddedRuntimeBridgeSupport.run(
            descriptor: descriptor,
            script: script,
            input: input,
            workspaceRoot: workspaceRoot
        )
    }
}

enum SwiftRuntimeService {
    private static let descriptor = EmbeddedRuntimeBridgeSupport.BridgeDescriptor(
        runtimeID: "swift",
        frameworkName: "OllamaKitSwiftRuntime",
        binaryName: "OllamaKitSwiftRuntime",
        symbolName: "OllamaKitSwiftRunJSON",
        title: "Embedded Swift",
        unavailableReason: "Unavailable in current IPA."
    )

    static var isAvailable: Bool {
        EmbeddedRuntimeBridgeSupport.isAvailable(descriptor)
    }

    static var availabilityReason: String? {
        EmbeddedRuntimeBridgeSupport.availabilityReason(descriptor)
    }

    static var health: EmbeddedRuntimeBridgeSupport.BridgeAvailability {
        EmbeddedRuntimeBridgeSupport.health(descriptor)
    }

    static func run(script: String, input: AgentJSONValue?, workspaceRoot: String?) throws -> AgentJSONValue {
        try EmbeddedRuntimeBridgeSupport.run(
            descriptor: descriptor,
            script: script,
            input: input,
            workspaceRoot: workspaceRoot
        )
    }
}

enum GitService {
    static let engineIdentifier = "github_snapshot_bridge"
    static let engineDescription = "Workspace snapshots and GitHub-backed sync are available now. Full local git metadata still depends on a bundled bridge."

    static func cloneRepositoryWorkspace(repository: String, ref: String?) async throws -> AgentWorkspaceRecord {
        try await AgentWorkspaceManager.shared.cloneRepositoryWorkspace(repository: repository, ref: ref)
    }
}

enum ShellToolService {
    enum ShellError: LocalizedError {
        case invalidCommand
        case unsupportedCommand(String)

        var errorDescription: String? {
            switch self {
            case .invalidCommand:
                return "The shell command could not be parsed."
            case .unsupportedCommand(let command):
                return "The shell-style command \(command) is not supported in the on-device agent."
            }
        }
    }

    static func commandNeedsApproval(_ command: String) -> Bool {
        guard let parsed = try? tokenize(command).first?.lowercased() else { return false }
        return ["mkdir", "mv", "rm"].contains(parsed)
    }

    @MainActor
    static func run(command: String, workspaceManager: AgentWorkspaceManager, workspaceID: String?) throws -> AgentJSONValue {
        let tokens = try tokenize(command)
        guard let verb = tokens.first?.lowercased() else {
            throw ShellError.invalidCommand
        }

        switch verb {
        case "pwd":
            guard let workspace = workspaceManager.workspace(id: workspaceID) else {
                throw AgentWorkspaceError.workspaceNotFound
            }
            return .object([
                "command": .string(command),
                "stdout": .string(workspace.rootPath)
            ])
        case "ls":
            let target = tokens.count > 1 ? tokens[1] : ""
            let entries = try workspaceManager.listFiles(workspaceID: workspaceID, relativePath: target, recursive: false, limit: 500)
            return .object([
                "command": .string(command),
                "stdout": .array(entries.map { entry in
                    .object([
                        "path": .string(entry.path),
                        "directory": .bool(entry.isDirectory),
                        "size_bytes": .int(Int(entry.sizeBytes))
                    ])
                })
            ])
        case "cat":
            guard tokens.count >= 2 else {
                throw AgentWorkspaceError.invalidInput("cat requires a file path.")
            }
            let content = try workspaceManager.readFile(workspaceID: workspaceID, relativePath: tokens[1])
            return .object([
                "command": .string(command),
                "stdout": .string(content)
            ])
        case "find":
            guard tokens.count >= 2 else {
                throw AgentWorkspaceError.invalidInput("find requires search text.")
            }
            let matches = try workspaceManager.search(workspaceID: workspaceID, needle: tokens.dropFirst().joined(separator: " "), limit: 200)
            return .object([
                "command": .string(command),
                "stdout": .array(matches.map { match in
                    .object([
                        "path": .string(match.path),
                        "line": .int(match.line),
                        "preview": .string(match.preview)
                    ])
                })
            ])
        case "mkdir":
            guard tokens.count >= 2 else {
                throw AgentWorkspaceError.invalidInput("mkdir requires a folder path.")
            }
            try workspaceManager.createFolder(workspaceID: workspaceID, relativePath: tokens[1])
            return .object([
                "command": .string(command),
                "stdout": .string("Created \(tokens[1])")
            ])
        case "mv":
            guard tokens.count >= 3 else {
                throw AgentWorkspaceError.invalidInput("mv requires source and destination paths.")
            }
            try workspaceManager.moveItem(workspaceID: workspaceID, from: tokens[1], to: tokens[2])
            return .object([
                "command": .string(command),
                "stdout": .string("Moved \(tokens[1]) -> \(tokens[2])")
            ])
        case "rm":
            guard tokens.count >= 2 else {
                throw AgentWorkspaceError.invalidInput("rm requires a path.")
            }
            try workspaceManager.deleteItem(workspaceID: workspaceID, relativePath: tokens[1])
            return .object([
                "command": .string(command),
                "stdout": .string("Deleted \(tokens[1])")
            ])
        default:
            throw ShellError.unsupportedCommand(verb)
        }
    }

    private static func tokenize(_ command: String) throws -> [String] {
        let pattern = #""([^"]*)"|'([^']*)'|(\S+)"#
        let regex = try NSRegularExpression(pattern: pattern)
        let nsrange = NSRange(command.startIndex..<command.endIndex, in: command)
        let matches = regex.matches(in: command, range: nsrange)
        guard !matches.isEmpty else {
            throw ShellError.invalidCommand
        }

        return matches.compactMap { match in
            for index in 1..<match.numberOfRanges {
                let range = match.range(at: index)
                if range.location != NSNotFound, let swiftRange = Range(range, in: command) {
                    return String(command[swiftRange])
                }
            }
            return nil
        }
    }
}

enum WebPreviewService {
    @MainActor
    static func scaffoldStaticApp(workspaceManager: AgentWorkspaceManager, workspaceID: String?) throws -> AgentJSONValue {
        let html = """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>OllamaKit Preview</title>
          <link rel="stylesheet" href="./style.css">
        </head>
        <body>
          <main class="shell">
            <span class="eyebrow">OllamaKit Power Agent</span>
            <h1>Local Preview Ready</h1>
            <p>Edit this preview under <code>preview/</code> or let the agent rewrite it.</p>
            <button id="ping">Run JS</button>
            <pre id="output">Waiting for interaction…</pre>
          </main>
          <script src="./app.js"></script>
        </body>
        </html>
        """
        let css = """
        :root {
          color-scheme: dark;
          font-family: "SF Pro Display", "Helvetica Neue", sans-serif;
          background:
            radial-gradient(circle at top, rgba(91, 180, 255, 0.28), transparent 32rem),
            linear-gradient(180deg, #071321 0%, #05070f 100%);
        }
        body {
          margin: 0;
          min-height: 100vh;
          display: grid;
          place-items: center;
          background: transparent;
          color: white;
        }
        .shell {
          width: min(42rem, calc(100vw - 2rem));
          padding: 2rem;
          border-radius: 1.5rem;
          backdrop-filter: blur(24px);
          background: rgba(12, 22, 36, 0.72);
          border: 1px solid rgba(255, 255, 255, 0.12);
          box-shadow: 0 24px 64px rgba(0, 0, 0, 0.35);
        }
        .eyebrow {
          display: inline-block;
          margin-bottom: 1rem;
          font-size: 0.8rem;
          letter-spacing: 0.18em;
          text-transform: uppercase;
          color: #7fd1ff;
        }
        h1 {
          margin: 0 0 0.75rem;
          font-size: clamp(2.2rem, 5vw, 3.4rem);
        }
        button {
          margin-top: 1rem;
          padding: 0.9rem 1.2rem;
          border: 0;
          border-radius: 999px;
          background: linear-gradient(135deg, #2dd4bf, #3b82f6);
          color: white;
          font-weight: 700;
        }
        pre {
          margin-top: 1rem;
          padding: 1rem;
          border-radius: 1rem;
          background: rgba(3, 8, 16, 0.8);
          overflow: auto;
        }
        """
        let js = """
        const output = document.getElementById("output");
        document.getElementById("ping").addEventListener("click", () => {
          output.textContent = "Preview JS ran at " + new Date().toLocaleTimeString();
        });
        """

        try workspaceManager.writeFile(workspaceID: workspaceID, relativePath: "preview/index.html", content: html)
        try workspaceManager.writeFile(workspaceID: workspaceID, relativePath: "preview/style.css", content: css)
        try workspaceManager.writeFile(workspaceID: workspaceID, relativePath: "preview/app.js", content: js)
        return .object([
            "created": .array([
                .string("preview/index.html"),
                .string("preview/style.css"),
                .string("preview/app.js")
            ])
        ])
    }
}

@MainActor
final class AgentToolRuntime {
    static let shared = AgentToolRuntime()

    private init() {}

    private func currentRuntimeTier() -> AgentRuntimeTier {
        AppSettings.shared.buildVariant == .jailbreak ? .jailbreak : .stockSideload
    }

    private var browserRuntimeBundled: Bool {
#if canImport(WebKit)
        return true
#else
        return false
#endif
    }

    private var browserRuntimeAvailable: Bool {
        browserRuntimeBundled
    }

    private var browserAvailabilityReason: String? {
        browserRuntimeBundled ? nil : "Unavailable in current IPA."
    }

    private func resolvedAgentModel(arguments: [String: AgentJSONValue] = [:]) -> ModelSnapshot? {
        if let explicitReference = arguments["model_id"]?.stringValue?.nonEmpty
            ?? arguments["model"]?.stringValue?.nonEmpty
            ?? arguments["catalog_id"]?.stringValue?.nonEmpty,
           let snapshot = ModelStorage.shared.snapshot(name: explicitReference) {
            return snapshot
        }

        if let activeCatalogId = ModelRunner.shared.activeCatalogId,
           let snapshot = ModelStorage.shared.snapshot(name: activeCatalogId) {
            return snapshot
        }

        if let defaultReference = AppSettings.shared.defaultModelId.nonEmpty,
           let snapshot = ModelStorage.shared.snapshot(name: defaultReference) {
            return snapshot
        }

        return nil
    }

    private func runtimeCapabilityProfile() -> AgentCapabilityProfile {
        let supportsLiveBundleEditing =
            AppSettings.shared.buildVariant.allowsLiveBundleWorkspace &&
            AgentWorkspaceManager.shared.workspaces.contains(where: { $0.kind == .bundleLive })
        #if canImport(WebKit)
        let supportsEmbeddedBrowser = true
        #else
        let supportsEmbeddedBrowser = false
        #endif
        return AgentCapabilityProfile(
            runtimeTier: currentRuntimeTier(),
            supportsEmbeddedBrowser: supportsEmbeddedBrowser,
            supportsJavaScriptRuntime: JavaScriptRuntimeService.isAvailable,
            supportsPythonRuntime: PythonRuntimeService.isAvailable,
            supportsNodeRuntime: NodeRuntimeService.isAvailable,
            supportsSwiftRuntime: SwiftRuntimeService.isAvailable,
            supportsGitHubActions: true,
            supportsManagedRelay: true,
            supportsLiveBundleEditing: supportsLiveBundleEditing,
            supportsExpertBundleEditing: supportsLiveBundleEditing && AppSettings.shared.agentBundleExpertMode
        )
    }

    private func effectiveAgentCapabilities(for model: ModelSnapshot?) -> ModelAgentCapabilityProfile? {
        guard let model else {
            return nil
        }

        let runtime = runtimeCapabilityProfile()
        var profile = model.effectiveAgentCapabilities

        if !runtime.supportsEmbeddedBrowser {
            profile = profile
                .setting(false, for: .browserRead)
                .setting(false, for: .browserActions)
        }
        if !runtime.supportsJavaScriptRuntime {
            profile = profile.setting(false, for: .jsRuntime)
        }
        if !runtime.supportsPythonRuntime {
            profile = profile.setting(false, for: .pythonRuntime)
        }
        if !runtime.supportsNodeRuntime {
            profile = profile.setting(false, for: .nodeRuntime)
        }
        if !runtime.supportsSwiftRuntime {
            profile = profile.setting(false, for: .swiftRuntime)
        }
        if !runtime.supportsGitHubActions {
            profile = profile.setting(false, for: .remoteCI)
        }
        if !runtime.supportsManagedRelay {
            profile = profile.setting(false, for: .managedRelayAccess)
        }
        if !runtime.supportsLiveBundleEditing {
            profile = profile.setting(false, for: .bundleEdits)
        }

        if model.backendKind != .ggufLlama && model.backendKind != .appleFoundation {
            profile = profile
                .setting(false, for: .browserActions)
                .setting(false, for: .internetWrite)
                .setting(false, for: .gitWrite)
                .setting(false, for: .bundleEdits)
        }

        return profile
    }

    func effectiveCapabilitiesPreview(for model: ModelSnapshot?) -> ModelAgentCapabilityProfile? {
        effectiveAgentCapabilities(for: model)
    }

    func runtimeCapabilityPreview() -> AgentCapabilityProfile {
        runtimeCapabilityProfile()
    }

    func runtimePackagePreview(for model: ModelSnapshot? = nil) -> [RuntimePackageRecord] {
        runtimePackages(for: model)
    }

    private func runtimePackages(for model: ModelSnapshot?) -> [RuntimePackageRecord] {
        let modelCapabilities = effectiveAgentCapabilities(for: model)
        let browserToolExposed = modelCapabilities.map { $0.browserRead || $0.browserActions } ?? true
        let jsToolExposed = modelCapabilities?.jsRuntime ?? true
        let pythonToolExposed = modelCapabilities?.pythonRuntime ?? true
        let nodeToolExposed = modelCapabilities?.nodeRuntime ?? true
        let swiftToolExposed = modelCapabilities?.swiftRuntime ?? true
        let gitToolExposed = modelCapabilities.map { $0.gitRead || $0.gitWrite || $0.githubAccess } ?? true

        return [
            runtimePackageRecord(
                id: "browser",
                title: "Embedded Browser",
                runtime: "browser",
                bundled: browserRuntimeBundled,
                bridgeLoaded: browserRuntimeAvailable,
                resourceBundlePresent: true,
                toolExposed: browserToolExposed,
                unavailableReason: browserAvailabilityReason,
                version: nil,
                supportedOperations: ["automation"]
            ),
            runtimePackageRecord(
                id: "javascriptcore",
                title: "JavaScriptCore",
                runtime: "javascript",
                bundled: JavaScriptRuntimeService.isAvailable,
                bridgeLoaded: JavaScriptRuntimeService.isAvailable,
                resourceBundlePresent: JavaScriptRuntimeService.isAvailable,
                toolExposed: jsToolExposed,
                unavailableReason: JavaScriptRuntimeService.availabilityReason,
                version: nil,
                supportedOperations: ["script"]
            ),
            runtimePackageRecord(
                id: "python",
                title: "Embedded Python",
                runtime: "python",
                bundled: PythonRuntimeService.health.bundled,
                bridgeLoaded: PythonRuntimeService.health.bridgeLoaded,
                resourceBundlePresent: PythonRuntimeService.health.resourceBundlePresent,
                toolExposed: pythonToolExposed,
                unavailableReason: PythonRuntimeService.health.reason,
                version: PythonRuntimeService.health.version,
                supportedOperations: PythonRuntimeService.health.supportedOperations
            ),
            runtimePackageRecord(
                id: "node",
                title: "Embedded Node.js",
                runtime: "node",
                bundled: NodeRuntimeService.health.bundled,
                bridgeLoaded: NodeRuntimeService.health.bridgeLoaded,
                resourceBundlePresent: NodeRuntimeService.health.resourceBundlePresent,
                toolExposed: nodeToolExposed,
                unavailableReason: NodeRuntimeService.health.reason,
                version: NodeRuntimeService.health.version,
                supportedOperations: NodeRuntimeService.health.supportedOperations
            ),
            runtimePackageRecord(
                id: "swift",
                title: "Embedded Swift",
                runtime: "swift",
                bundled: SwiftRuntimeService.health.bundled,
                bridgeLoaded: SwiftRuntimeService.health.bridgeLoaded,
                resourceBundlePresent: SwiftRuntimeService.health.resourceBundlePresent,
                toolExposed: swiftToolExposed,
                unavailableReason: SwiftRuntimeService.health.reason,
                version: SwiftRuntimeService.health.version,
                supportedOperations: SwiftRuntimeService.health.supportedOperations
            ),
            runtimePackageRecord(
                id: "git",
                title: "Repository Sync",
                runtime: "git",
                bundled: true,
                bridgeLoaded: true,
                resourceBundlePresent: true,
                toolExposed: gitToolExposed,
                unavailableReason: nil,
                version: nil,
                supportedOperations: ["snapshot_sync"]
            )
        ]
    }

    private func runtimePackageRecord(
        id: String,
        title: String,
        runtime: String,
        bundled: Bool,
        bridgeLoaded: Bool,
        resourceBundlePresent: Bool,
        toolExposed: Bool,
        unavailableReason: String?,
        version: String?,
        supportedOperations: [String]
    ) -> RuntimePackageRecord {
        let state: RuntimePackageAvailabilityState
        let availabilityReason: String?

        if !bundled {
            state = .unavailableInCurrentIPA
            availabilityReason = unavailableReason?.nonEmpty ?? "Unavailable in current IPA."
        } else if !bridgeLoaded || !resourceBundlePresent {
            state = .bridgeLoadFailed
            availabilityReason = unavailableReason?.nonEmpty
                ?? (resourceBundlePresent ? "The embedded runtime bridge failed to load." : "Required runtime resources are missing.")
        } else if !toolExposed {
            state = .disabledByModelPolicy
            availabilityReason = "Disabled by model policy."
        } else {
            state = .installed
            availabilityReason = nil
        }

        return RuntimePackageRecord(
            id: id,
            title: title,
            runtime: runtime,
            bundled: bundled,
            bridgeLoaded: bridgeLoaded,
            resourceBundlePresent: resourceBundlePresent,
            toolExposed: toolExposed,
            available: bundled && bridgeLoaded && resourceBundlePresent && toolExposed,
            state: state,
            availabilityReason: availabilityReason,
            version: version,
            supportedOperations: supportedOperations
        )
    }

    private func requiredCapabilities(for toolID: String) -> [AgentToolCapabilityKey] {
        switch toolID {
        case "workspace.list_files", "workspace.read_file", "workspace.search", "workspace.diff_latest_checkpoint":
            return [.workspaceRead]
        case "workspace.create_checkpoint", "workspace.restore_checkpoint", "workspace.write_file", "workspace.create_folder", "workspace.move", "workspace.delete", "workspace.reset_seed":
            return [.workspaceWrite]
        case "browser.open_tab", "browser.navigate", "browser.back", "browser.forward", "browser.reload", "browser.read_page", "browser.query_dom", "browser.extract_links", "browser.capture":
            return [.browserRead]
        case "browser.search_web":
            return [.browserRead, .internetRead]
        case "browser.type", "browser.click", "browser.submit_form":
            return [.browserActions]
        case "browser.download":
            return [.browserActions, .workspaceWrite]
        case "browser.save_page_to_workspace":
            return [.browserRead, .workspaceWrite]
        case "bundle.patch_history":
            return [.bundleEdits]
        case "shell.run":
            return [.codeTools]
        case "javascript.run":
            return [.jsRuntime]
        case "web.scaffold_static":
            return [.codeTools, .workspaceWrite]
        case "internet.fetch":
            return [.internetRead]
        case "github.login_device_flow", "github.poll_device_flow", "github.repository", "github.search_repos", "github.search_code", "github.get_file", "github.list_issues", "github.list_prs":
            return [.githubAccess]
        case "github.create_branch", "github.create_pr":
            return [.gitWrite, .internetWrite]
        case "github.workflow_runs", "github.workflow_run_logs", "github.workflow_artifacts":
            return [.remoteCI]
        case "github.rerun_workflow":
            return [.remoteCI, .internetWrite]
        case "github.refresh_builtin_workspace":
            return [.githubAccess, .workspaceWrite]
        case "github.push_workspace_snapshot":
            return [.githubAccess, .gitWrite, .internetWrite]
        case "git.clone_repository":
            return [.gitRead, .workspaceWrite]
        case "git.status":
            return [.gitRead]
        case "python.run":
            return [.pythonRuntime]
        case "node.run":
            return [.nodeRuntime]
        case "swift.run":
            return [.swiftRuntime]
        case "relay.status":
            return [.managedRelayAccess]
        case "relay.reconnect":
            return [.managedRelayAccess, .internetWrite]
        case "remote.ssh":
            return [.remoteCI]
        default:
            return []
        }
    }

    private func capabilityFailureReason(
        for descriptor: AgentToolDescriptor,
        model: ModelSnapshot?,
        missingCapabilities: [AgentToolCapabilityKey]
    ) -> String {
        guard let model else {
            return "Select or load a model with agent permissions before using \(descriptor.title.lowercased())."
        }

        let labels = missingCapabilities
            .prefix(3)
            .map { $0.rawValue.replacingOccurrences(of: "_", with: " ") }
            .joined(separator: ", ")
        return "Disabled by model policy for \(model.displayName): \(labels)."
    }

    private func applyAvailability(to descriptor: AgentToolDescriptor, model: ModelSnapshot?) -> AgentToolDescriptor {
        guard descriptor.available else {
            return descriptor
        }

        guard !descriptor.requiredCapabilities.isEmpty else {
            return descriptor
        }

        guard let capabilities = effectiveAgentCapabilities(for: model) else {
            return AgentToolDescriptor(
                id: descriptor.id,
                title: descriptor.title,
                category: descriptor.category,
                detail: descriptor.detail,
                networkScope: descriptor.networkScope,
                writeScope: descriptor.writeScope,
                needsApproval: descriptor.needsApproval,
                available: false,
                availabilityReason: capabilityFailureReason(for: descriptor, model: nil, missingCapabilities: descriptor.requiredCapabilities),
                timeoutSeconds: descriptor.timeoutSeconds,
                quotaDescription: descriptor.quotaDescription,
                requiredCapabilities: descriptor.requiredCapabilities
            )
        }

        let missing = descriptor.requiredCapabilities.filter { !capabilities.supports($0) }
        guard !missing.isEmpty else {
            return descriptor
        }

        return AgentToolDescriptor(
            id: descriptor.id,
            title: descriptor.title,
            category: descriptor.category,
            detail: descriptor.detail,
            networkScope: descriptor.networkScope,
            writeScope: descriptor.writeScope,
            needsApproval: descriptor.needsApproval,
            available: false,
            availabilityReason: capabilityFailureReason(for: descriptor, model: model, missingCapabilities: missing),
            timeoutSeconds: descriptor.timeoutSeconds,
            quotaDescription: descriptor.quotaDescription,
            requiredCapabilities: descriptor.requiredCapabilities
        )
    }

    func toolDescriptors(for model: ModelSnapshot? = nil) -> [AgentToolDescriptor] {
        let jsAvailable = JavaScriptRuntimeService.isAvailable
        let pythonAvailable = PythonRuntimeService.isAvailable
        let nodeAvailable = NodeRuntimeService.isAvailable
        let swiftAvailable = SwiftRuntimeService.isAvailable
        let browserAvailable = browserRuntimeAvailable
        let activeModel = model ?? resolvedAgentModel()

        return [
            AgentToolDescriptor(id: "workspace.context", title: "Workspace Context", category: .context, detail: "Return app, device, workspace, model, and tool context.", networkScope: .none, writeScope: .none, needsApproval: false, available: true, availabilityReason: nil, timeoutSeconds: 5, quotaDescription: "Read-only"),
            AgentToolDescriptor(id: "workspace.activate", title: "Activate Workspace", category: .workspace, detail: "Switch the active workspace for future tool calls.", networkScope: .none, writeScope: .none, needsApproval: false, available: true, availabilityReason: nil, timeoutSeconds: 5, quotaDescription: "Switch only"),
            AgentToolDescriptor(id: "workspace.list_files", title: "List Files", category: .workspace, detail: "List files inside the active workspace.", networkScope: .none, writeScope: .none, needsApproval: false, available: true, availabilityReason: nil, timeoutSeconds: 5, quotaDescription: "500 items"),
            AgentToolDescriptor(id: "workspace.read_file", title: "Read File", category: .workspace, detail: "Read a UTF-8 file from the active workspace.", networkScope: .none, writeScope: .none, needsApproval: false, available: true, availabilityReason: nil, timeoutSeconds: 5, quotaDescription: "UTF-8 text only"),
            AgentToolDescriptor(id: "workspace.search", title: "Search Workspace", category: .workspace, detail: "Search text across the active workspace.", networkScope: .none, writeScope: .none, needsApproval: false, available: true, availabilityReason: nil, timeoutSeconds: 10, quotaDescription: "100 matches"),
            AgentToolDescriptor(id: "workspace.diff_latest_checkpoint", title: "Diff Latest Checkpoint", category: .workspace, detail: "Show added, removed, and modified files versus the latest checkpoint or bundled seed.", networkScope: .none, writeScope: .none, needsApproval: false, available: true, availabilityReason: nil, timeoutSeconds: 10, quotaDescription: "200 changed files"),
            AgentToolDescriptor(id: "workspace.create_checkpoint", title: "Create Checkpoint", category: .checkpoints, detail: "Create a restore point for the active workspace.", networkScope: .none, writeScope: .workspace, needsApproval: true, available: true, availabilityReason: nil, timeoutSeconds: 15, quotaDescription: "Full snapshot"),
            AgentToolDescriptor(id: "workspace.restore_checkpoint", title: "Restore Checkpoint", category: .checkpoints, detail: "Restore the active workspace to a prior checkpoint.", networkScope: .none, writeScope: .destructive, needsApproval: true, available: true, availabilityReason: nil, timeoutSeconds: 20, quotaDescription: "Full snapshot restore"),
            AgentToolDescriptor(id: "workspace.write_file", title: "Write File", category: .workspace, detail: "Create or replace a UTF-8 text file inside the active workspace.", networkScope: .none, writeScope: .workspace, needsApproval: true, available: true, availabilityReason: nil, timeoutSeconds: 10, quotaDescription: "UTF-8 text only"),
            AgentToolDescriptor(id: "workspace.create_folder", title: "Create Folder", category: .workspace, detail: "Create a folder inside the active workspace.", networkScope: .none, writeScope: .workspace, needsApproval: true, available: true, availabilityReason: nil, timeoutSeconds: 5, quotaDescription: "Workspace scoped"),
            AgentToolDescriptor(id: "workspace.move", title: "Move Item", category: .workspace, detail: "Move or rename a file or folder inside the active workspace.", networkScope: .none, writeScope: .workspace, needsApproval: true, available: true, availabilityReason: nil, timeoutSeconds: 10, quotaDescription: "Workspace scoped"),
            AgentToolDescriptor(id: "workspace.delete", title: "Delete Item", category: .workspace, detail: "Delete a file or folder inside the active workspace.", networkScope: .none, writeScope: .destructive, needsApproval: true, available: true, availabilityReason: nil, timeoutSeconds: 10, quotaDescription: "Workspace scoped"),
            AgentToolDescriptor(id: "workspace.reset_seed", title: "Reset Built-In Workspace", category: .workspace, detail: "Reset the bundled OllamaKit mirror back to the seed snapshot.", networkScope: .none, writeScope: .destructive, needsApproval: true, available: true, availabilityReason: nil, timeoutSeconds: 20, quotaDescription: "Built-in workspace only"),
            AgentToolDescriptor(id: "browser.open_tab", title: "Open Browser Tab", category: .browser, detail: "Open a new embedded browser tab.", networkScope: .readOnly, writeScope: .none, needsApproval: false, available: browserAvailable, availabilityReason: browserAvailabilityReason, timeoutSeconds: 20, quotaDescription: "Creates a tab"),
            AgentToolDescriptor(id: "browser.navigate", title: "Navigate Browser", category: .browser, detail: "Navigate the active browser tab to a URL.", networkScope: .readOnly, writeScope: .none, needsApproval: false, available: browserAvailable, availabilityReason: browserAvailabilityReason, timeoutSeconds: 30, quotaDescription: "Single navigation"),
            AgentToolDescriptor(id: "browser.back", title: "Browser Back", category: .browser, detail: "Navigate backward in the active browser tab.", networkScope: .readOnly, writeScope: .none, needsApproval: false, available: browserAvailable, availabilityReason: browserAvailabilityReason, timeoutSeconds: 15, quotaDescription: "Single step"),
            AgentToolDescriptor(id: "browser.forward", title: "Browser Forward", category: .browser, detail: "Navigate forward in the active browser tab.", networkScope: .readOnly, writeScope: .none, needsApproval: false, available: browserAvailable, availabilityReason: browserAvailabilityReason, timeoutSeconds: 15, quotaDescription: "Single step"),
            AgentToolDescriptor(id: "browser.reload", title: "Reload Browser Tab", category: .browser, detail: "Reload the active browser tab.", networkScope: .readOnly, writeScope: .none, needsApproval: false, available: browserAvailable, availabilityReason: browserAvailabilityReason, timeoutSeconds: 20, quotaDescription: "Single reload"),
            AgentToolDescriptor(id: "browser.search_web", title: "Search The Web", category: .browser, detail: "Open a web search in the embedded browser using the configured search engine.", networkScope: .readOnly, writeScope: .none, needsApproval: false, available: browserAvailable, availabilityReason: browserAvailabilityReason, timeoutSeconds: 30, quotaDescription: "Single search"),
            AgentToolDescriptor(id: "browser.read_page", title: "Read Browser Page", category: .browser, detail: "Extract text, HTML, and links from the active page.", networkScope: .readOnly, writeScope: .none, needsApproval: false, available: browserAvailable, availabilityReason: browserAvailabilityReason, timeoutSeconds: 15, quotaDescription: "120KB HTML"),
            AgentToolDescriptor(id: "browser.query_dom", title: "Query DOM", category: .browser, detail: "Query the active page with a CSS selector.", networkScope: .readOnly, writeScope: .none, needsApproval: false, available: browserAvailable, availabilityReason: browserAvailabilityReason, timeoutSeconds: 15, quotaDescription: "50 nodes"),
            AgentToolDescriptor(id: "browser.extract_links", title: "Extract Links", category: .browser, detail: "Extract links from the active page.", networkScope: .readOnly, writeScope: .none, needsApproval: false, available: browserAvailable, availabilityReason: browserAvailabilityReason, timeoutSeconds: 15, quotaDescription: "200 links"),
            AgentToolDescriptor(id: "browser.type", title: "Type Into Page", category: .browser, detail: "Fill an input or textarea on the active page.", networkScope: .sideEffecting, writeScope: .none, needsApproval: true, available: browserAvailable, availabilityReason: browserAvailabilityReason, timeoutSeconds: 15, quotaDescription: "Single selector"),
            AgentToolDescriptor(id: "browser.click", title: "Click Page Element", category: .browser, detail: "Click an element on the active page.", networkScope: .sideEffecting, writeScope: .none, needsApproval: true, available: browserAvailable, availabilityReason: browserAvailabilityReason, timeoutSeconds: 15, quotaDescription: "Single selector"),
            AgentToolDescriptor(id: "browser.submit_form", title: "Submit Form", category: .browser, detail: "Submit a form on the active page.", networkScope: .sideEffecting, writeScope: .none, needsApproval: true, available: browserAvailable, availabilityReason: browserAvailabilityReason, timeoutSeconds: 15, quotaDescription: "Single selector"),
            AgentToolDescriptor(id: "browser.download", title: "Download Browser Asset", category: .browser, detail: "Download a URL from the active browser session into a workspace.", networkScope: .sideEffecting, writeScope: .workspace, needsApproval: true, available: browserAvailable, availabilityReason: browserAvailabilityReason, timeoutSeconds: 60, quotaDescription: "Single download"),
            AgentToolDescriptor(id: "browser.capture", title: "Capture Browser", category: .browser, detail: "Take a snapshot of the active browser page.", networkScope: .readOnly, writeScope: .workspace, needsApproval: false, available: browserAvailable, availabilityReason: browserAvailabilityReason, timeoutSeconds: 20, quotaDescription: "PNG capture"),
            AgentToolDescriptor(id: "browser.save_page_to_workspace", title: "Save Page To Workspace", category: .browser, detail: "Save the current page HTML into a workspace file.", networkScope: .readOnly, writeScope: .workspace, needsApproval: true, available: browserAvailable, availabilityReason: browserAvailabilityReason, timeoutSeconds: 20, quotaDescription: "Single HTML file"),
            AgentToolDescriptor(id: "diagnostics.recent_server_logs", title: "Recent Server Logs", category: .diagnostics, detail: "Return recent API server logs.", networkScope: .none, writeScope: .none, needsApproval: false, available: true, availabilityReason: nil, timeoutSeconds: 5, quotaDescription: "50 entries"),
            AgentToolDescriptor(id: "diagnostics.agent_logs", title: "Recent Agent Logs", category: .diagnostics, detail: "Return recent power-agent logs.", networkScope: .none, writeScope: .none, needsApproval: false, available: true, availabilityReason: nil, timeoutSeconds: 5, quotaDescription: "50 entries"),
            AgentToolDescriptor(id: "bundle.patch_history", title: "Bundle Patch History", category: .bundle, detail: "List recent live-bundle backup and patch records.", networkScope: .none, writeScope: .none, needsApproval: false, available: true, availabilityReason: nil, timeoutSeconds: 5, quotaDescription: "50 records"),
            AgentToolDescriptor(id: "models.catalog", title: "Model Catalog", category: .diagnostics, detail: "Return the installed model catalog with validation status.", networkScope: .none, writeScope: .none, needsApproval: false, available: true, availabilityReason: nil, timeoutSeconds: 5, quotaDescription: "All installed models"),
            AgentToolDescriptor(id: "shell.run", title: "Shell-Style Commands", category: .shell, detail: "Run a restricted workspace-scoped command such as pwd, ls, cat, find, mkdir, mv, or rm.", networkScope: .none, writeScope: .workspace, needsApproval: true, available: true, availabilityReason: nil, timeoutSeconds: 10, quotaDescription: "Restricted built-ins only"),
            AgentToolDescriptor(id: "javascript.run", title: "Run JavaScript", category: .javascript, detail: "Execute a JavaScript snippet with JavaScriptCore.", networkScope: .none, writeScope: .none, needsApproval: false, available: jsAvailable, availabilityReason: JavaScriptRuntimeService.availabilityReason, timeoutSeconds: 10, quotaDescription: "Inline scripts"),
            AgentToolDescriptor(id: "web.scaffold_static", title: "Scaffold Preview App", category: .webPreview, detail: "Create a simple local web app scaffold under preview/ for WKWebView previewing.", networkScope: .none, writeScope: .workspace, needsApproval: true, available: true, availabilityReason: nil, timeoutSeconds: 10, quotaDescription: "Creates 3 files"),
            AgentToolDescriptor(id: "internet.fetch", title: "Fetch URL", category: .internet, detail: "Fetch a URL with an HTTP GET request.", networkScope: .readOnly, writeScope: .none, needsApproval: false, available: true, availabilityReason: nil, timeoutSeconds: 20, quotaDescription: "GET only"),
            AgentToolDescriptor(id: "github.login_device_flow", title: "GitHub Device Login", category: .github, detail: "Start GitHub OAuth device flow and return the verification code and URL.", networkScope: .credentialedRead, writeScope: .none, needsApproval: false, available: true, availabilityReason: nil, timeoutSeconds: 20, quotaDescription: "Single device flow"),
            AgentToolDescriptor(id: "github.poll_device_flow", title: "Poll GitHub Device Flow", category: .github, detail: "Poll GitHub device flow for an access token.", networkScope: .credentialedRead, writeScope: .none, needsApproval: false, available: true, availabilityReason: nil, timeoutSeconds: 20, quotaDescription: "Single poll"),
            AgentToolDescriptor(id: "github.repository", title: "GitHub Repository", category: .github, detail: "Fetch repository metadata from GitHub.", networkScope: .readOnly, writeScope: .none, needsApproval: false, available: true, availabilityReason: nil, timeoutSeconds: 20, quotaDescription: "Public repos or token-auth"),
            AgentToolDescriptor(id: "github.search_repos", title: "Search Repositories", category: .github, detail: "Search GitHub repositories.", networkScope: .readOnly, writeScope: .none, needsApproval: false, available: true, availabilityReason: nil, timeoutSeconds: 20, quotaDescription: "20 results"),
            AgentToolDescriptor(id: "github.search_code", title: "Search Code", category: .github, detail: "Search GitHub code across one repo or globally.", networkScope: .readOnly, writeScope: .none, needsApproval: false, available: true, availabilityReason: nil, timeoutSeconds: 20, quotaDescription: "20 results"),
            AgentToolDescriptor(id: "github.get_file", title: "Get GitHub File", category: .github, detail: "Fetch a text file from GitHub.", networkScope: .readOnly, writeScope: .none, needsApproval: false, available: true, availabilityReason: nil, timeoutSeconds: 20, quotaDescription: "Text file only"),
            AgentToolDescriptor(id: "github.list_issues", title: "List Issues", category: .github, detail: "List GitHub issues for a repository.", networkScope: .readOnly, writeScope: .none, needsApproval: false, available: true, availabilityReason: nil, timeoutSeconds: 20, quotaDescription: "50 issues"),
            AgentToolDescriptor(id: "github.list_prs", title: "List Pull Requests", category: .github, detail: "List GitHub pull requests for a repository.", networkScope: .readOnly, writeScope: .none, needsApproval: false, available: true, availabilityReason: nil, timeoutSeconds: 20, quotaDescription: "50 PRs"),
            AgentToolDescriptor(id: "github.create_branch", title: "Create Branch", category: .git, detail: "Create or confirm a branch on GitHub for the active repository.", networkScope: .sideEffecting, writeScope: .none, needsApproval: true, available: true, availabilityReason: nil, timeoutSeconds: 30, quotaDescription: "Single branch"),
            AgentToolDescriptor(id: "github.create_pr", title: "Create Pull Request", category: .github, detail: "Create a pull request on GitHub.", networkScope: .sideEffecting, writeScope: .none, needsApproval: true, available: true, availabilityReason: nil, timeoutSeconds: 30, quotaDescription: "Single PR"),
            AgentToolDescriptor(id: "github.workflow_runs", title: "GitHub Workflow Runs", category: .githubActions, detail: "List recent GitHub Actions workflow runs.", networkScope: .readOnly, writeScope: .none, needsApproval: false, available: true, availabilityReason: nil, timeoutSeconds: 20, quotaDescription: "10 runs"),
            AgentToolDescriptor(id: "github.workflow_run_logs", title: "Workflow Run Logs", category: .githubActions, detail: "Resolve or download GitHub Actions run logs.", networkScope: .credentialedRead, writeScope: .none, needsApproval: false, available: true, availabilityReason: nil, timeoutSeconds: 20, quotaDescription: "Single run"),
            AgentToolDescriptor(id: "github.workflow_artifacts", title: "Workflow Artifacts", category: .githubActions, detail: "List artifacts produced by a GitHub Actions run.", networkScope: .credentialedRead, writeScope: .none, needsApproval: false, available: true, availabilityReason: nil, timeoutSeconds: 20, quotaDescription: "50 artifacts"),
            AgentToolDescriptor(id: "github.rerun_workflow", title: "Rerun Workflow", category: .githubActions, detail: "Request a rerun of a GitHub Actions workflow run.", networkScope: .sideEffecting, writeScope: .none, needsApproval: true, available: true, availabilityReason: nil, timeoutSeconds: 20, quotaDescription: "Single rerun"),
            AgentToolDescriptor(id: "github.refresh_builtin_workspace", title: "Refresh Built-In Workspace", category: .github, detail: "Refresh the built-in OllamaKit mirror from GitHub text files.", networkScope: .credentialedRead, writeScope: .workspace, needsApproval: true, available: true, availabilityReason: nil, timeoutSeconds: 120, quotaDescription: "Selected repo snapshot"),
            AgentToolDescriptor(id: "github.push_workspace_snapshot", title: "Push Workspace Snapshot", category: .github, detail: "Push the current workspace files to a GitHub branch using the Git Data API.", networkScope: .sideEffecting, writeScope: .none, needsApproval: true, available: true, availabilityReason: nil, timeoutSeconds: 180, quotaDescription: "Requires repo write access"),
            AgentToolDescriptor(id: "git.clone_repository", title: "Clone Repository Workspace", category: .git, detail: "Create a local workspace from a repository snapshot. Full local git metadata still depends on a bundled git bridge.", networkScope: .readOnly, writeScope: .workspace, needsApproval: true, available: true, availabilityReason: nil, timeoutSeconds: 180, quotaDescription: "Snapshot clone"),
            AgentToolDescriptor(id: "git.status", title: "Repository Status", category: .git, detail: "Show linked repository, branch, and local workspace diff state.", networkScope: .none, writeScope: .none, needsApproval: false, available: true, availabilityReason: nil, timeoutSeconds: 10, quotaDescription: "Workspace diff only"),
            AgentToolDescriptor(id: "python.run", title: "Run Python", category: .python, detail: "Execute a Python script through the embedded runtime bridge with bundled stdlib support and workspace-local pure-Python imports.", networkScope: .none, writeScope: .workspace, needsApproval: false, available: pythonAvailable, availabilityReason: PythonRuntimeService.availabilityReason, timeoutSeconds: pythonAvailable ? 60 : 0, quotaDescription: pythonAvailable ? "Workspace-scoped bridge" : "Unavailable"),
            AgentToolDescriptor(id: "node.run", title: "Run Node/JS Toolchain", category: .node, detail: "Execute a Node.js script through the embedded runtime bridge with workspace-local pure-JS packages. Process spawning and arbitrary native addons stay blocked.", networkScope: .none, writeScope: .workspace, needsApproval: false, available: nodeAvailable, availabilityReason: NodeRuntimeService.availabilityReason, timeoutSeconds: nodeAvailable ? 60 : 0, quotaDescription: nodeAvailable ? "Workspace-scoped bridge" : "Unavailable"),
            AgentToolDescriptor(id: "swift.run", title: "Run Swift / SwiftPM", category: .swift, detail: "Run bounded Swift workspace operations such as scaffolding, inspection, template rewrites, and manifest diagnostics. Full compile-and-run stays out of scope on device.", networkScope: .none, writeScope: .workspace, needsApproval: false, available: swiftAvailable, availabilityReason: SwiftRuntimeService.availabilityReason, timeoutSeconds: swiftAvailable ? 120 : 0, quotaDescription: swiftAvailable ? "Workspace assistant" : "Unavailable"),
            AgentToolDescriptor(id: "relay.status", title: "Managed Relay Status", category: .relay, detail: "Inspect the managed public relay session and assigned public URL.", networkScope: .readOnly, writeScope: .none, needsApproval: false, available: true, availabilityReason: nil, timeoutSeconds: 10, quotaDescription: "Relay session state"),
            AgentToolDescriptor(id: "relay.reconnect", title: "Reconnect Managed Relay", category: .relay, detail: "Reconnect the managed public relay session for Public Managed mode.", networkScope: .sideEffecting, writeScope: .none, needsApproval: true, available: true, availabilityReason: nil, timeoutSeconds: 30, quotaDescription: "Single reconnect"),
            AgentToolDescriptor(id: "remote.ssh", title: "SSH Remote Runner", category: .remote, detail: "Remote execution is intentionally out of scope in this GitHub-only build.", networkScope: .sideEffecting, writeScope: .none, needsApproval: true, available: false, availabilityReason: "PC, Mac, and SSH runners are disabled in this build.", timeoutSeconds: 0, quotaDescription: "Unavailable")
        ]
        .map { descriptor in
            let enriched = AgentToolDescriptor(
                id: descriptor.id,
                title: descriptor.title,
                category: descriptor.category,
                detail: descriptor.detail,
                networkScope: descriptor.networkScope,
                writeScope: descriptor.writeScope,
                needsApproval: descriptor.needsApproval,
                available: descriptor.available,
                availabilityReason: descriptor.availabilityReason,
                timeoutSeconds: descriptor.timeoutSeconds,
                quotaDescription: descriptor.quotaDescription,
                requiredCapabilities: requiredCapabilities(for: descriptor.id)
            )
            return applyAvailability(to: enriched, model: activeModel)
        }
    }

    private func truncatedLogBody(_ value: String?, limit: Int = 320) -> String? {
        guard let value = value?.trimmedForLookup.nonEmpty else { return nil }
        if value.count <= limit {
            return value
        }
        return String(value.prefix(limit)) + "..."
    }

    private func encodedArgumentBody(_ arguments: [String: AgentJSONValue]) -> String? {
        guard !arguments.isEmpty else { return nil }
        return truncatedLogBody(AgentJSONValue.object(arguments).jsonStringRepresentation, limit: 480)
    }

    private func toolLogMetadata(
        toolID: String,
        arguments: [String: AgentJSONValue],
        model: ModelSnapshot?,
        descriptor: AgentToolDescriptor? = nil,
        additional: [String: String] = [:]
    ) -> [String: String] {
        var metadata: [String: String] = [
            "tool_id": toolID,
            "category": descriptor?.category.rawValue ?? "unknown"
        ]

        if let workspaceID = arguments["workspace_id"]?.stringValue?.nonEmpty {
            metadata["workspace_id"] = workspaceID
        }
        if let modelID = model?.catalogId.nonEmpty {
            metadata["model_id"] = modelID
        }
#if canImport(WebKit)
        if let sessionID = BrowserSessionManager.shared.activeSession()?.id.uuidString.nonEmpty {
            metadata["session_id"] = sessionID
        }
#endif
        if let url = arguments["url"]?.stringValue?.nonEmpty {
            metadata["url"] = url
        }
        if let path = arguments["path"]?.stringValue?.nonEmpty {
            metadata["path"] = path
        }
        if let repository = arguments["repository"]?.stringValue?.nonEmpty {
            metadata["repository"] = repository
        }
        if let command = arguments["command"]?.stringValue?.nonEmpty {
            metadata["command"] = truncatedLogBody(command, limit: 120) ?? command
        }

        for (key, value) in additional {
            metadata[key] = value
        }
        return metadata
    }

    private func runtimeInvocationLog(
        runtime: String,
        toolID: String,
        script: String,
        workspaceRoot: String?,
        model: ModelSnapshot?,
        arguments: [String: AgentJSONValue]
    ) {
        var metadata = toolLogMetadata(
            toolID: toolID,
            arguments: arguments,
            model: model,
            additional: ["runtime": runtime]
        )
        if let workspaceRoot = workspaceRoot?.nonEmpty {
            metadata["workspace_root"] = workspaceRoot
        }
        AgentLogStore.shared.record(
            .runtime,
            title: "Runtime Invocation Started",
            message: "\(runtime.capitalized) bridge requested.",
            metadata: metadata,
            body: truncatedLogBody(script, limit: 420)
        )
    }

    private func payloadSizeBytes(_ result: AgentJSONValue) -> Int {
        result.jsonStringRepresentation.lengthOfBytes(using: .utf8)
    }

    func execute(toolID: String, arguments: AgentJSONValue) async -> AgentExecutionResult {
        AgentWorkspaceManager.shared.bootstrapIfNeeded()
        let args = arguments.objectValue ?? [:]
        let model = resolvedAgentModel(arguments: args)
        guard let descriptor = toolDescriptors(for: model).first(where: { $0.id == toolID }) else {
            AgentLogStore.shared.record(
                .tool,
                level: .error,
                title: "Tool Request Rejected",
                message: "Unknown tool requested.",
                metadata: toolLogMetadata(toolID: toolID, arguments: args, model: model)
            )
            return .failure(toolID: toolID, message: "Unknown tool.")
        }

        AgentLogStore.shared.record(
            .tool,
            title: "Tool Requested",
            message: descriptor.title,
            metadata: toolLogMetadata(toolID: toolID, arguments: args, model: model, descriptor: descriptor),
            body: encodedArgumentBody(args)
        )

        guard descriptor.available else {
            AgentLogStore.shared.record(
                .tool,
                level: .warning,
                title: "Tool Blocked",
                message: descriptor.availabilityReason ?? "This tool is unavailable.",
                metadata: toolLogMetadata(toolID: toolID, arguments: args, model: model, descriptor: descriptor)
            )
            return .failure(toolID: toolID, message: descriptor.availabilityReason ?? "This tool is unavailable.")
        }

        if requiresApproval(toolID: toolID, arguments: args) {
            let summary = approvalSummary(toolID: toolID, arguments: args)
            AgentLogStore.shared.record(
                .tool,
                level: .warning,
                title: "Tool Queued For Approval",
                message: summary,
                metadata: toolLogMetadata(toolID: toolID, arguments: args, model: model, descriptor: descriptor)
            )
            let request = AgentApprovalCenter.shared.enqueue(
                toolID: toolID,
                title: descriptor.title,
                summary: summary,
                workspaceID: args["workspace_id"]?.stringValue,
                arguments: arguments
            ) { [weak self] in
                guard let self else {
                    return .failure(toolID: toolID, message: "The pending approval no longer has an executor.")
                }
                return await self.executeApproved(toolID: toolID, arguments: args)
            }
            return .pending(toolID: toolID, message: "Approval required before \(descriptor.title.lowercased()) can run.", request: request)
        }

        return await executeApproved(toolID: toolID, arguments: args)
    }

    func approve(requestID: UUID) async -> AgentExecutionResult {
        await AgentApprovalCenter.shared.approve(id: requestID)
    }

    func reject(requestID: UUID) -> AgentExecutionResult {
        AgentApprovalCenter.shared.reject(id: requestID)
    }

    private func executeApproved(toolID: String, arguments: [String: AgentJSONValue]) async -> AgentExecutionResult {
        let startedAt = Date()
        let model = resolvedAgentModel(arguments: arguments)
        let descriptor = toolDescriptors(for: model).first(where: { $0.id == toolID })

        AgentLogStore.shared.record(
            .tool,
            title: "Tool Execution Started",
            message: descriptor?.title ?? toolID,
            metadata: toolLogMetadata(toolID: toolID, arguments: arguments, model: model, descriptor: descriptor)
        )

        do {
            let result: AgentJSONValue
            switch toolID {
            case "workspace.context":
                result = try await runtimeContextJSON(arguments: arguments)
            case "workspace.activate":
                guard let workspaceID = arguments["workspace_id"]?.stringValue?.nonEmpty else {
                    throw AgentWorkspaceError.invalidInput("workspace_id is required.")
                }
                AgentWorkspaceManager.shared.setActiveWorkspace(id: workspaceID)
                result = .object([
                    "active_workspace_id": .string(AgentWorkspaceManager.shared.activeWorkspaceID)
                ])
            case "workspace.list_files":
                let entries = try AgentWorkspaceManager.shared.listFiles(
                    workspaceID: arguments["workspace_id"]?.stringValue,
                    relativePath: arguments["path"]?.stringValue ?? "",
                    recursive: arguments["recursive"]?.boolValue ?? false,
                    limit: arguments["limit"]?.intValue ?? 200
                )
                result = .array(entries.map { entry in
                    .object([
                        "path": .string(entry.path),
                        "directory": .bool(entry.isDirectory),
                        "size_bytes": .int(Int(entry.sizeBytes)),
                        "modified_at": .string(entry.modifiedAt.map { ISO8601DateFormatter().string(from: $0) } ?? "")
                    ])
                })
            case "workspace.read_file":
                let path = arguments["path"]?.stringValue ?? ""
                let content = try AgentWorkspaceManager.shared.readFile(
                    workspaceID: arguments["workspace_id"]?.stringValue,
                    relativePath: path
                )
                result = .object([
                    "path": .string(path),
                    "content": .string(content)
                ])
            case "workspace.search":
                let matches = try AgentWorkspaceManager.shared.search(
                    workspaceID: arguments["workspace_id"]?.stringValue,
                    needle: arguments["needle"]?.stringValue ?? "",
                    limit: arguments["limit"]?.intValue ?? 100
                )
                result = .array(matches.map { match in
                    .object([
                        "path": .string(match.path),
                        "line": .int(match.line),
                        "preview": .string(match.preview)
                    ])
                })
            case "workspace.diff_latest_checkpoint":
                result = try AgentWorkspaceManager.shared.diffFromLatestCheckpoint(
                    workspaceID: arguments["workspace_id"]?.stringValue,
                    limit: arguments["limit"]?.intValue ?? 200
                )
            case "workspace.create_checkpoint":
                let checkpoint = try AgentWorkspaceManager.shared.createCheckpoint(
                    workspaceID: arguments["workspace_id"]?.stringValue,
                    name: arguments["name"]?.stringValue,
                    reason: arguments["reason"]?.stringValue
                )
                result = checkpointJSON(checkpoint)
            case "workspace.restore_checkpoint":
                guard let idString = arguments["checkpoint_id"]?.stringValue,
                      let checkpointID = UUID(uuidString: idString)
                else {
                    throw AgentWorkspaceError.invalidInput("checkpoint_id must be a UUID string.")
                }
                let checkpoint = try AgentWorkspaceManager.shared.restoreCheckpoint(
                    workspaceID: arguments["workspace_id"]?.stringValue,
                    checkpointID: checkpointID
                )
                result = checkpointJSON(checkpoint)
            case "workspace.write_file":
                let workspaceID = arguments["workspace_id"]?.stringValue
                let path = arguments["path"]?.stringValue ?? ""
                let checkpoint = try AgentWorkspaceManager.shared.createCheckpoint(
                    workspaceID: workspaceID,
                    name: "Auto Before Write",
                    reason: "Automatic backup before writing \(path)."
                )
                try AgentWorkspaceManager.shared.writeFile(
                    workspaceID: workspaceID,
                    relativePath: path,
                    content: arguments["content"]?.stringValue ?? ""
                )
                result = .object([
                    "path": .string(path),
                    "checkpoint": checkpointJSON(checkpoint)
                ])
            case "workspace.create_folder":
                let path = arguments["path"]?.stringValue ?? ""
                _ = try AgentWorkspaceManager.shared.createCheckpoint(
                    workspaceID: arguments["workspace_id"]?.stringValue,
                    name: "Auto Before Folder Create",
                    reason: "Automatic backup before creating \(path)."
                )
                try AgentWorkspaceManager.shared.createFolder(
                    workspaceID: arguments["workspace_id"]?.stringValue,
                    relativePath: path
                )
                result = .object(["path": .string(path)])
            case "workspace.move":
                let source = arguments["source"]?.stringValue ?? ""
                let destination = arguments["destination"]?.stringValue ?? ""
                _ = try AgentWorkspaceManager.shared.createCheckpoint(
                    workspaceID: arguments["workspace_id"]?.stringValue,
                    name: "Auto Before Move",
                    reason: "Automatic backup before moving \(source)."
                )
                try AgentWorkspaceManager.shared.moveItem(
                    workspaceID: arguments["workspace_id"]?.stringValue,
                    from: source,
                    to: destination
                )
                result = .object([
                    "source": .string(source),
                    "destination": .string(destination)
                ])
            case "workspace.delete":
                let path = arguments["path"]?.stringValue ?? ""
                _ = try AgentWorkspaceManager.shared.createCheckpoint(
                    workspaceID: arguments["workspace_id"]?.stringValue,
                    name: "Auto Before Delete",
                    reason: "Automatic backup before deleting \(path)."
                )
                try AgentWorkspaceManager.shared.deleteItem(
                    workspaceID: arguments["workspace_id"]?.stringValue,
                    relativePath: path
                )
                result = .object(["path": .string(path)])
            case "workspace.reset_seed":
                let checkpoint = try AgentWorkspaceManager.shared.resetBuiltInWorkspaceToSeed()
                result = checkpointJSON(checkpoint)
            case "browser.open_tab":
#if canImport(WebKit)
                let record = await BrowserSessionManager.shared.openTab(urlString: arguments["url"]?.stringValue)
                result = browserSessionJSON(record)
#else
                throw AgentWorkspaceError.unsupported("Embedded browser support is unavailable on this build.")
#endif
            case "browser.navigate":
#if canImport(WebKit)
                let record = try await BrowserSessionManager.shared.navigate(
                    sessionID: UUID(uuidString: arguments["session_id"]?.stringValue ?? ""),
                    urlString: arguments["url"]?.stringValue ?? ""
                )
                result = browserSessionJSON(record)
#else
                throw AgentWorkspaceError.unsupported("Embedded browser support is unavailable on this build.")
#endif
            case "browser.back":
#if canImport(WebKit)
                let record = try await BrowserSessionManager.shared.back(
                    sessionID: UUID(uuidString: arguments["session_id"]?.stringValue ?? "")
                )
                result = browserSessionJSON(record)
#else
                throw AgentWorkspaceError.unsupported("Embedded browser support is unavailable on this build.")
#endif
            case "browser.forward":
#if canImport(WebKit)
                let record = try await BrowserSessionManager.shared.forward(
                    sessionID: UUID(uuidString: arguments["session_id"]?.stringValue ?? "")
                )
                result = browserSessionJSON(record)
#else
                throw AgentWorkspaceError.unsupported("Embedded browser support is unavailable on this build.")
#endif
            case "browser.reload":
#if canImport(WebKit)
                let record = try await BrowserSessionManager.shared.reload(
                    sessionID: UUID(uuidString: arguments["session_id"]?.stringValue ?? "")
                )
                result = browserSessionJSON(record)
#else
                throw AgentWorkspaceError.unsupported("Embedded browser support is unavailable on this build.")
#endif
            case "browser.search_web":
#if canImport(WebKit)
                let query = arguments["query"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !query.isEmpty else {
                    throw AgentWorkspaceError.invalidInput("query is required.")
                }
                let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
                let searchURL = "https://duckduckgo.com/?q=\(encodedQuery)"
                let record = await BrowserSessionManager.shared.openTab(urlString: searchURL)
                result = browserSessionJSON(record)
#else
                throw AgentWorkspaceError.unsupported("Embedded browser support is unavailable on this build.")
#endif
            case "browser.read_page":
#if canImport(WebKit)
                result = try await BrowserSessionManager.shared.readPage(
                    sessionID: UUID(uuidString: arguments["session_id"]?.stringValue ?? "")
                )
#else
                throw AgentWorkspaceError.unsupported("Embedded browser support is unavailable on this build.")
#endif
            case "browser.query_dom":
#if canImport(WebKit)
                result = try await BrowserSessionManager.shared.queryDOM(
                    sessionID: UUID(uuidString: arguments["session_id"]?.stringValue ?? ""),
                    selector: arguments["selector"]?.stringValue ?? "",
                    limit: arguments["limit"]?.intValue ?? 20
                )
#else
                throw AgentWorkspaceError.unsupported("Embedded browser support is unavailable on this build.")
#endif
            case "browser.extract_links":
#if canImport(WebKit)
                result = try await BrowserSessionManager.shared.extractLinks(
                    sessionID: UUID(uuidString: arguments["session_id"]?.stringValue ?? "")
                )
#else
                throw AgentWorkspaceError.unsupported("Embedded browser support is unavailable on this build.")
#endif
            case "browser.type":
#if canImport(WebKit)
                result = try await BrowserSessionManager.shared.type(
                    sessionID: UUID(uuidString: arguments["session_id"]?.stringValue ?? ""),
                    selector: arguments["selector"]?.stringValue ?? "",
                    text: arguments["text"]?.stringValue ?? ""
                )
#else
                throw AgentWorkspaceError.unsupported("Embedded browser support is unavailable on this build.")
#endif
            case "browser.click":
#if canImport(WebKit)
                result = try await BrowserSessionManager.shared.click(
                    sessionID: UUID(uuidString: arguments["session_id"]?.stringValue ?? ""),
                    selector: arguments["selector"]?.stringValue ?? ""
                )
#else
                throw AgentWorkspaceError.unsupported("Embedded browser support is unavailable on this build.")
#endif
            case "browser.submit_form":
#if canImport(WebKit)
                result = try await BrowserSessionManager.shared.submitForm(
                    sessionID: UUID(uuidString: arguments["session_id"]?.stringValue ?? ""),
                    selector: arguments["selector"]?.stringValue ?? ""
                )
#else
                throw AgentWorkspaceError.unsupported("Embedded browser support is unavailable on this build.")
#endif
            case "browser.download":
#if canImport(WebKit)
                result = try await BrowserSessionManager.shared.download(
                    sessionID: UUID(uuidString: arguments["session_id"]?.stringValue ?? ""),
                    urlString: arguments["url"]?.stringValue,
                    workspaceID: arguments["workspace_id"]?.stringValue ?? AgentWorkspaceManager.dataLayerWorkspaceID,
                    relativePath: arguments["path"]?.stringValue
                )
#else
                throw AgentWorkspaceError.unsupported("Embedded browser support is unavailable on this build.")
#endif
            case "browser.capture":
#if canImport(WebKit)
                result = try await BrowserSessionManager.shared.capture(
                    sessionID: UUID(uuidString: arguments["session_id"]?.stringValue ?? ""),
                    workspaceID: arguments["workspace_id"]?.stringValue ?? AgentWorkspaceManager.downloadedSiteWorkspaceID,
                    relativePath: arguments["path"]?.stringValue
                )
#else
                throw AgentWorkspaceError.unsupported("Embedded browser support is unavailable on this build.")
#endif
            case "browser.save_page_to_workspace":
#if canImport(WebKit)
                result = try await BrowserSessionManager.shared.savePageToWorkspace(
                    sessionID: UUID(uuidString: arguments["session_id"]?.stringValue ?? ""),
                    workspaceID: arguments["workspace_id"]?.stringValue ?? AgentWorkspaceManager.downloadedSiteWorkspaceID,
                    relativePath: arguments["path"]?.stringValue
                )
#else
                throw AgentWorkspaceError.unsupported("Embedded browser support is unavailable on this build.")
#endif
            case "diagnostics.recent_server_logs":
                let limit = arguments["limit"]?.intValue ?? 50
                let entries = Array(ServerLogStore.shared.entries.suffix(limit))
                result = .array(entries.map { entry in
                    .object([
                        "timestamp": .string(ISO8601DateFormatter().string(from: entry.timestamp)),
                        "level": .string(entry.level.rawValue),
                        "category": .string(entry.category.rawValue),
                        "title": .string(entry.title),
                        "message": .string(entry.message),
                        "request_id": .string(entry.requestID ?? ""),
                        "body": .string(entry.body ?? "")
                    ])
                })
            case "diagnostics.agent_logs":
                let limit = arguments["limit"]?.intValue ?? 50
                let entries = Array(AgentLogStore.shared.entries.suffix(limit))
                result = .array(entries.map { entry in
                    .object([
                        "timestamp": .string(ISO8601DateFormatter().string(from: entry.timestamp)),
                        "level": .string(entry.level.rawValue),
                        "category": .string(entry.category.rawValue),
                        "title": .string(entry.title),
                        "message": .string(entry.message),
                        "body": .string(entry.body ?? "")
                    ])
                })
            case "bundle.patch_history":
                let workspaceID = arguments["workspace_id"]?.stringValue
                let limit = arguments["limit"]?.intValue ?? 50
                let records = BundlePatchStore.shared.records
                    .filter { workspaceID == nil || $0.workspaceID == workspaceID }
                    .prefix(max(1, min(limit, 200)))
                result = .array(records.map { record in
                    .object([
                        "id": .string(record.id.uuidString),
                        "workspace_id": .string(record.workspaceID),
                        "relative_path": .string(record.relativePath),
                        "backup_path": .string(record.backupPath ?? ""),
                        "operation": .string(record.operation),
                        "created_at": .string(ISO8601DateFormatter().string(from: record.createdAt)),
                        "requires_restart": .bool(record.requiresRestart)
                    ])
                })
            case "models.catalog":
                result = modelCatalogJSON()
            case "shell.run":
                let command = arguments["command"]?.stringValue ?? ""
                AgentLogStore.shared.record(
                    .shell,
                    title: "Shell Command Started",
                    message: command,
                    metadata: toolLogMetadata(toolID: toolID, arguments: arguments, model: model, descriptor: descriptor)
                )
                result = try ShellToolService.run(
                    command: command,
                    workspaceManager: AgentWorkspaceManager.shared,
                    workspaceID: arguments["workspace_id"]?.stringValue
                )
            case "javascript.run":
                runtimeInvocationLog(
                    runtime: "javascript",
                    toolID: toolID,
                    script: arguments["script"]?.stringValue ?? "",
                    workspaceRoot: nil,
                    model: model,
                    arguments: arguments
                )
                result = try JavaScriptRuntimeService.run(
                    script: arguments["script"]?.stringValue ?? "",
                    input: arguments["input"]
                )
            case "web.scaffold_static":
                _ = try AgentWorkspaceManager.shared.createCheckpoint(
                    workspaceID: arguments["workspace_id"]?.stringValue,
                    name: "Auto Before Web Scaffold",
                    reason: "Automatic backup before creating a preview app."
                )
                result = try WebPreviewService.scaffoldStaticApp(
                    workspaceManager: AgentWorkspaceManager.shared,
                    workspaceID: arguments["workspace_id"]?.stringValue
                )
            case "internet.fetch":
                result = try await fetchURL(arguments: arguments)
            case "github.login_device_flow":
                result = try await GitHubService.shared.startDeviceFlow(clientID: arguments["client_id"]?.stringValue)
            case "github.poll_device_flow":
                result = try await GitHubService.shared.pollDeviceFlowToken(clientID: arguments["client_id"]?.stringValue)
            case "github.repository":
                let repository = arguments["repository"]?.stringValue ?? AppSettings.shared.agentGitHubRepository
                result = try await GitHubService.shared.repositorySummary(repository: repository)
            case "github.search_repos":
                result = try await GitHubService.shared.searchRepositories(
                    query: arguments["query"]?.stringValue ?? "",
                    limit: arguments["limit"]?.intValue ?? 10
                )
            case "github.search_code":
                result = try await GitHubService.shared.searchCode(
                    query: arguments["query"]?.stringValue ?? "",
                    repository: arguments["repository"]?.stringValue,
                    limit: arguments["limit"]?.intValue ?? 10
                )
            case "github.get_file":
                let repository = arguments["repository"]?.stringValue ?? AppSettings.shared.agentGitHubRepository
                result = try await GitHubService.shared.getFile(
                    repository: repository,
                    path: arguments["path"]?.stringValue ?? "",
                    ref: arguments["ref"]?.stringValue
                )
            case "github.list_issues":
                let repository = arguments["repository"]?.stringValue ?? AppSettings.shared.agentGitHubRepository
                result = try await GitHubService.shared.listIssues(
                    repository: repository,
                    state: arguments["state"]?.stringValue ?? "open",
                    limit: arguments["limit"]?.intValue ?? 20
                )
            case "github.list_prs":
                let repository = arguments["repository"]?.stringValue ?? AppSettings.shared.agentGitHubRepository
                result = try await GitHubService.shared.listPullRequests(
                    repository: repository,
                    state: arguments["state"]?.stringValue ?? "open",
                    limit: arguments["limit"]?.intValue ?? 20
                )
            case "github.create_branch":
                let repository = arguments["repository"]?.stringValue ?? AppSettings.shared.agentGitHubRepository
                result = try await GitHubService.shared.createBranch(
                    repository: repository,
                    branch: arguments["branch"]?.stringValue ?? "",
                    baseBranch: arguments["base"]?.stringValue
                )
            case "github.create_pr":
                let repository = arguments["repository"]?.stringValue ?? AppSettings.shared.agentGitHubRepository
                result = try await GitHubService.shared.createPullRequest(
                    repository: repository,
                    title: arguments["title"]?.stringValue ?? "Power Agent Update",
                    body: arguments["body"]?.stringValue ?? "",
                    head: arguments["head"]?.stringValue ?? "",
                    base: arguments["base"]?.stringValue
                )
            case "github.workflow_runs":
                let repository = arguments["repository"]?.stringValue ?? AppSettings.shared.agentGitHubRepository
                result = try await GitHubService.shared.workflowRuns(
                    repository: repository,
                    limit: arguments["limit"]?.intValue ?? 10
                )
            case "github.workflow_run_logs":
                let repository = arguments["repository"]?.stringValue ?? AppSettings.shared.agentGitHubRepository
                guard let runID = arguments["run_id"]?.intValue else {
                    throw AgentWorkspaceError.invalidInput("run_id is required.")
                }
                result = try await GitHubService.shared.workflowRunLogs(repository: repository, runID: runID)
            case "github.workflow_artifacts":
                let repository = arguments["repository"]?.stringValue ?? AppSettings.shared.agentGitHubRepository
                guard let runID = arguments["run_id"]?.intValue else {
                    throw AgentWorkspaceError.invalidInput("run_id is required.")
                }
                result = try await GitHubService.shared.workflowArtifacts(repository: repository, runID: runID)
            case "github.rerun_workflow":
                let repository = arguments["repository"]?.stringValue ?? AppSettings.shared.agentGitHubRepository
                guard let runID = arguments["run_id"]?.intValue else {
                    throw AgentWorkspaceError.invalidInput("run_id is required.")
                }
                result = try await GitHubService.shared.rerunWorkflow(repository: repository, runID: runID)
            case "github.refresh_builtin_workspace":
                let repository = arguments["repository"]?.stringValue ?? AppSettings.shared.agentGitHubRepository
                result = try await AgentWorkspaceManager.shared.refreshBuiltInWorkspaceFromGitHub(
                    repository: repository,
                    ref: arguments["ref"]?.stringValue
                )
            case "github.push_workspace_snapshot":
                let repository = arguments["repository"]?.stringValue ?? AppSettings.shared.agentGitHubRepository
                let workspace = try requiredWorkspace(arguments["workspace_id"]?.stringValue)
                result = try await GitHubService.shared.pushWorkspaceSnapshot(
                    repository: repository,
                    branch: arguments["branch"]?.stringValue,
                    message: arguments["message"]?.stringValue ?? "Power Agent workspace sync",
                    workspace: workspace
                )
            case "git.clone_repository":
                let repository = arguments["repository"]?.stringValue ?? AppSettings.shared.agentGitHubRepository
                let workspace = try await GitService.cloneRepositoryWorkspace(
                    repository: repository,
                    ref: arguments["ref"]?.stringValue
                )
                result = .object([
                    "workspace_id": .string(workspace.id),
                    "repository": .string(workspace.linkedRepository ?? repository),
                    "ref": .string(workspace.linkedBranch ?? "")
                ])
            case "git.status":
                result = try gitStatusJSON(arguments: arguments)
            case "python.run":
                let workspaceRoot = try requiredWorkspace(arguments["workspace_id"]?.stringValue).rootPath
                runtimeInvocationLog(
                    runtime: "python",
                    toolID: toolID,
                    script: arguments["script"]?.stringValue ?? "",
                    workspaceRoot: workspaceRoot,
                    model: model,
                    arguments: arguments
                )
                result = try PythonRuntimeService.run(
                    script: arguments["script"]?.stringValue ?? "",
                    input: arguments["input"],
                    workspaceRoot: workspaceRoot
                )
            case "node.run":
                let workspaceRoot = try requiredWorkspace(arguments["workspace_id"]?.stringValue).rootPath
                runtimeInvocationLog(
                    runtime: "node",
                    toolID: toolID,
                    script: arguments["script"]?.stringValue ?? "",
                    workspaceRoot: workspaceRoot,
                    model: model,
                    arguments: arguments
                )
                result = try NodeRuntimeService.run(
                    script: arguments["script"]?.stringValue ?? "",
                    input: arguments["input"],
                    workspaceRoot: workspaceRoot
                )
            case "swift.run":
                let workspaceRoot = try requiredWorkspace(arguments["workspace_id"]?.stringValue).rootPath
                runtimeInvocationLog(
                    runtime: "swift",
                    toolID: toolID,
                    script: arguments["script"]?.stringValue ?? "",
                    workspaceRoot: workspaceRoot,
                    model: model,
                    arguments: arguments
                )
                result = try SwiftRuntimeService.run(
                    script: arguments["script"]?.stringValue ?? "",
                    input: arguments["input"],
                    workspaceRoot: workspaceRoot
                )
            case "relay.status":
                result = ManagedRelayService.shared.agentStatusJSON()
            case "relay.reconnect":
                await ManagedRelayService.shared.reconnect()
                result = ManagedRelayService.shared.agentStatusJSON()
            default:
                return .failure(toolID: toolID, message: "The tool \(toolID) is not implemented in this build.")
            }

            AgentLogStore.shared.record(
                .tool,
                title: "Tool Execution Finished",
                message: descriptor?.title ?? toolID,
                metadata: toolLogMetadata(
                    toolID: toolID,
                    arguments: arguments,
                    model: model,
                    descriptor: descriptor,
                    additional: [
                        "duration_ms": String(Int(Date().timeIntervalSince(startedAt) * 1000)),
                        "payload_bytes": String(payloadSizeBytes(result))
                    ]
                ),
                body: truncatedLogBody(result.jsonStringRepresentation, limit: 480)
            )
            return .success(toolID: toolID, message: "Tool executed successfully.", data: result)
        } catch {
            AgentLogStore.shared.record(
                .tool,
                level: .error,
                title: "Tool Execution Failed",
                message: error.localizedDescription,
                metadata: toolLogMetadata(
                    toolID: toolID,
                    arguments: arguments,
                    model: model,
                    descriptor: descriptor,
                    additional: ["duration_ms": String(Int(Date().timeIntervalSince(startedAt) * 1000))]
                ),
                body: encodedArgumentBody(arguments)
            )
            return .failure(toolID: toolID, message: error.localizedDescription)
        }
    }

    private func requiredWorkspace(_ id: String?) throws -> AgentWorkspaceRecord {
        guard let workspace = AgentWorkspaceManager.shared.workspace(id: id) else {
            throw AgentWorkspaceError.workspaceNotFound
        }
        return workspace
    }

    private func runtimeContextJSON(arguments: [String: AgentJSONValue]) async throws -> AgentJSONValue {
        let runtimeProfile = await DeviceCapabilityService.shared.currentRuntimeProfile()
        let workspaceSummary = try AgentWorkspaceManager.shared.projectSummaryJSON(workspaceID: arguments["workspace_id"]?.stringValue)
        let activeModel = resolvedAgentModel(arguments: arguments)
        let availableTools = toolDescriptors(for: activeModel).filter(\.available)
        let unavailableTools = toolDescriptors(for: activeModel).filter { !$0.available }
        let snapshots = ModelStorage.shared.allSnapshots()
        let failedModels = snapshots
            .filter { $0.effectiveValidationStatus == .failed }
            .map { "\($0.displayName): \($0.validationSummary ?? "Validation failed.")" }

        #if canImport(WebKit)
        BrowserSessionManager.shared.bootstrapIfNeeded()
        let activeBrowser = BrowserSessionManager.shared.activeSession()
#else
        let activeBrowser: BrowserSessionRecord? = nil
#endif

        let capabilityProfile = runtimeCapabilityProfile()
        let modelCapabilities = effectiveAgentCapabilities(for: activeModel)
        let relayStatus = ManagedRelayService.shared.agentStatusJSON()

        let runtimePackages = runtimePackages(for: activeModel)

        return .object([
            "app": .object([
                "name": .string(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "OllamaKit"),
                "version": .string(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"),
                "build": .string(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"),
                "build_variant": .string(AppSettings.shared.buildVariant.rawValue)
            ]),
            "device": .object([
                "system_version": .string(runtimeProfile.systemVersion),
                "machine_identifier": .string(runtimeProfile.machineIdentifier),
                "chip_family": .string(runtimeProfile.chipFamily),
                "interface_kind": .string(runtimeProfile.interfaceKind.rawValue),
                "physical_memory_bytes": .int(Int(runtimeProfile.physicalMemoryBytes)),
                "recommended_gguf_budget_bytes": .int(Int(runtimeProfile.recommendedGGUFBudgetBytes)),
                "supported_gguf_budget_bytes": .int(Int(runtimeProfile.supportedGGUFBudgetBytes)),
                "has_metal_device": .bool(runtimeProfile.hasMetalDevice),
                "metal_device_name": .string(runtimeProfile.metalDeviceName ?? "")
            ]),
            "server": .object([
                "enabled": .bool(AppSettings.shared.serverEnabled),
                "exposure_mode": .string(AppSettings.shared.serverExposureMode.rawValue),
                "canonical_url": .string(AppSettings.shared.serverURL),
                "requires_api_key": .bool(AppSettings.shared.isAPIKeyRequiredForCurrentExposure),
                "managed_relay": relayStatus
            ]),
            "agent": .object([
                "enabled": .bool(AppSettings.shared.powerAgentEnabled),
                "require_write_approval": .bool(true),
                "approval_policy": .string("reads_auto_writes_confirm"),
                "github_repository": .string(AppSettings.shared.agentGitHubRepository),
                "github_client_id_present": .bool(AppSettings.shared.agentGitHubClientID.nonEmpty != nil),
                "active_workspace_id": .string(AgentWorkspaceManager.shared.activeWorkspaceID),
                "build_variant": .string(AppSettings.shared.buildVariant.rawValue),
                "runtime_tier": .string(capabilityProfile.runtimeTier.rawValue),
                "active_model_id": .string(activeModel?.catalogId ?? ""),
                "active_model_name": .string(activeModel?.displayName ?? ""),
                "browser_surface": .string("agent_only_hidden"),
                "available_tool_count": .int(availableTools.count),
                "unavailable_tool_count": .int(unavailableTools.count),
                "pending_approvals": .int(AgentApprovalCenter.shared.requests.count),
                "bundle_patch_count": .int(BundlePatchStore.shared.records.count)
            ]),
            "workspace_summary": workspaceSummary,
            "active_browser": activeBrowser.map(browserSessionJSON) ?? .null,
            "workspaces": .array(AgentWorkspaceManager.shared.workspaces.map { workspace in
                .object([
                    "id": .string(workspace.id),
                    "name": .string(workspace.name),
                    "kind": .string(workspace.kind.rawValue),
                    "root_path": .string(workspace.rootPath),
                    "source_description": .string(workspace.sourceDescription),
                    "linked_repository": .string(workspace.linkedRepository ?? ""),
                    "linked_branch": .string(workspace.linkedBranch ?? "")
                ])
            }),
            "models": .object([
                "installed_count": .int(snapshots.count),
                "validated_runnable_count": .int(snapshots.filter(\.isValidatedRunnable).count),
                "failed_validation_count": .int(failedModels.count),
                "recent_validation_errors": .array(failedModels.prefix(10).map(AgentJSONValue.string))
            ]),
            "capabilities": .object([
                "build_variant": .string(AppSettings.shared.buildVariant.rawValue),
                "runtime_tier": .string(capabilityProfile.runtimeTier.rawValue),
                "embedded_browser": .bool(capabilityProfile.supportsEmbeddedBrowser),
                "javascript_runtime": .bool(capabilityProfile.supportsJavaScriptRuntime),
                "python_runtime": .bool(capabilityProfile.supportsPythonRuntime),
                "node_runtime": .bool(capabilityProfile.supportsNodeRuntime),
                "swift_runtime": .bool(capabilityProfile.supportsSwiftRuntime),
                "github_actions": .bool(capabilityProfile.supportsGitHubActions),
                "managed_relay": .bool(capabilityProfile.supportsManagedRelay),
                "live_bundle_editing": .bool(capabilityProfile.supportsLiveBundleEditing),
                "expert_bundle_editing": .bool(capabilityProfile.supportsExpertBundleEditing)
            ]),
            "active_model": activeModel.map { model in
                .object([
                    "catalog_id": .string(model.catalogId),
                    "display_name": .string(model.displayName),
                    "backend_kind": .string(model.backendKind.rawValue),
                    "validation_status": .string(model.effectiveValidationStatus.rawValue),
                    "has_manual_override": .bool(model.hasAgentCapabilityOverride)
                ])
            } ?? .null,
            "agent_model_capabilities": modelCapabilities.map(agentCapabilityJSON) ?? .null,
            "runtime_packages": .array(runtimePackages.map { package in
                .object([
                    "id": .string(package.id),
                    "title": .string(package.title),
                    "runtime": .string(package.runtime),
                    "bundled": .bool(package.bundled),
                    "bridge_loaded": .bool(package.bridgeLoaded),
                    "resource_bundle_present": .bool(package.resourceBundlePresent),
                    "tool_exposed": .bool(package.toolExposed),
                    "available": .bool(package.available),
                    "status": .string(package.state.rawValue),
                    "availability_reason": .string(package.availabilityReason ?? ""),
                    "version": .string(package.version ?? ""),
                    "supported_operations": .array(package.supportedOperations.map(AgentJSONValue.string))
                ])
            }),
            "log_storage": .object([
                "server": .object([
                    "persistent": .bool(true),
                    "entry_count": .int(ServerLogStore.shared.entries.count),
                    "retention_limit": .int(ServerLogStore.shared.retentionLimit),
                    "path": .string(ServerLogStore.shared.storagePath)
                ]),
                "agent": .object([
                    "persistent": .bool(true),
                    "entry_count": .int(AgentLogStore.shared.entries.count),
                    "retention_limit": .int(AgentLogStore.shared.retentionLimit),
                    "path": .string(AgentLogStore.shared.storagePath)
                ])
            ]),
            "recent_server_logs": .array(Array(ServerLogStore.shared.entries.suffix(10)).map { entry in
                .object([
                    "title": .string(entry.title),
                    "message": .string(entry.message),
                    "category": .string(entry.category.rawValue),
                    "level": .string(entry.level.rawValue),
                    "metadata": .object(entry.metadata.mapValues(AgentJSONValue.string))
                ])
            }),
            "recent_agent_logs": .array(Array(AgentLogStore.shared.entries.suffix(10)).map { entry in
                .object([
                    "title": .string(entry.title),
                    "message": .string(entry.message),
                    "category": .string(entry.category.rawValue),
                    "level": .string(entry.level.rawValue),
                    "metadata": .object(entry.metadata.mapValues(AgentJSONValue.string))
                ])
            }),
            "bundle_patches": .array(BundlePatchStore.shared.records.prefix(10).map { patch in
                .object([
                    "path": .string(patch.relativePath),
                    "operation": .string(patch.operation),
                    "created_at": .string(ISO8601DateFormatter().string(from: patch.createdAt))
                ])
            }),
            "tools": .object([
                "available": .array(availableTools.map(toolDescriptorJSON)),
                "unavailable": .array(unavailableTools.map(toolDescriptorJSON))
            ])
        ])
    }

    private func modelCatalogJSON() -> AgentJSONValue {
        let snapshots = ModelStorage.shared.allSnapshots()
        return .array(snapshots.map { snapshot in
            let agentCapabilities = effectiveAgentCapabilities(for: snapshot) ?? snapshot.effectiveAgentCapabilities
            return .object([
                "catalog_id": .string(snapshot.catalogId),
                "display_name": .string(snapshot.displayName),
                "server_identifier": .string(snapshot.serverIdentifier),
                "backend_kind": .string(snapshot.backendKind.rawValue),
                "size_bytes": .int(Int(snapshot.size)),
                "validation_status": .string(snapshot.effectiveValidationStatus.rawValue),
                "validation_message": .string(snapshot.validationSummary ?? ""),
                "server_runnable": .bool(snapshot.isServerRunnable),
                "supported_routes": .array(snapshot.effectiveServerCapabilities.supportedRoutes.map { .string($0.rawValue) }),
                "agent_capabilities": agentCapabilityJSON(agentCapabilities),
                "has_agent_override": .bool(snapshot.hasAgentCapabilityOverride)
            ])
        })
    }

    private func agentCapabilityJSON(_ profile: ModelAgentCapabilityProfile) -> AgentJSONValue {
        .object([
            "browser_read": .bool(profile.browserRead),
            "browser_actions": .bool(profile.browserActions),
            "internet_read": .bool(profile.internetRead),
            "internet_write": .bool(profile.internetWrite),
            "workspace_read": .bool(profile.workspaceRead),
            "workspace_write": .bool(profile.workspaceWrite),
            "code_tools": .bool(profile.codeTools),
            "js_runtime": .bool(profile.jsRuntime),
            "python_runtime": .bool(profile.pythonRuntime),
            "node_runtime": .bool(profile.nodeRuntime),
            "swift_runtime": .bool(profile.swiftRuntime),
            "git_read": .bool(profile.gitRead),
            "git_write": .bool(profile.gitWrite),
            "github_access": .bool(profile.githubAccess),
            "remote_ci": .bool(profile.remoteCI),
            "managed_relay_access": .bool(profile.managedRelayAccess),
            "bundle_edits": .bool(profile.bundleEdits)
        ])
    }

    private func gitStatusJSON(arguments: [String: AgentJSONValue]) throws -> AgentJSONValue {
        let workspace = try requiredWorkspace(arguments["workspace_id"]?.stringValue)
        let diff = try AgentWorkspaceManager.shared.diffFromLatestCheckpoint(workspaceID: workspace.id, limit: 500)
        return .object([
            "workspace_id": .string(workspace.id),
            "workspace_name": .string(workspace.name),
            "linked_repository": .string(workspace.linkedRepository ?? AppSettings.shared.agentGitHubRepository),
            "branch": .string(workspace.linkedBranch ?? "unknown"),
            "diff": diff
        ])
    }

    private func fetchURL(arguments: [String: AgentJSONValue]) async throws -> AgentJSONValue {
        guard let urlString = arguments["url"]?.stringValue,
              let url = URL(string: urlString)
        else {
            throw AgentWorkspaceError.invalidInput("A valid url is required.")
        }

        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse else {
            throw AgentWorkspaceError.unsupported("The HTTP request did not return a valid response.")
        }

        let text = String(data: data.prefix(200_000), encoding: .utf8) ?? ""
        return .object([
            "url": .string(url.absoluteString),
            "status": .int(http.statusCode),
            "content_type": .string(http.value(forHTTPHeaderField: "Content-Type") ?? ""),
            "body": .string(text)
        ])
    }

    private func checkpointJSON(_ checkpoint: AgentCheckpointRecord) -> AgentJSONValue {
        .object([
            "id": .string(checkpoint.id.uuidString),
            "workspace_id": .string(checkpoint.workspaceID),
            "name": .string(checkpoint.name),
            "reason": .string(checkpoint.reason ?? ""),
            "created_at": .string(ISO8601DateFormatter().string(from: checkpoint.createdAt))
        ])
    }

    private func browserSessionJSON(_ record: BrowserSessionRecord) -> AgentJSONValue {
        .object([
            "id": .string(record.id.uuidString),
            "title": .string(record.title),
            "url": .string(record.currentURL),
            "can_go_back": .bool(record.canGoBack),
            "can_go_forward": .bool(record.canGoForward),
            "page_summary": .string(record.pageSummary ?? ""),
            "last_error": .string(record.lastError ?? "")
        ])
    }

    private func toolDescriptorJSON(_ descriptor: AgentToolDescriptor) -> AgentJSONValue {
        .object([
            "id": .string(descriptor.id),
            "title": .string(descriptor.title),
            "category": .string(descriptor.category.rawValue),
            "detail": .string(descriptor.detail),
            "network_scope": .string(descriptor.networkScope.rawValue),
            "write_scope": .string(descriptor.writeScope.rawValue),
            "needs_approval": .bool(descriptor.needsApproval),
            "available": .bool(descriptor.available),
            "availability_reason": .string(descriptor.availabilityReason ?? ""),
            "timeout_seconds": .int(descriptor.timeoutSeconds),
            "quota": .string(descriptor.quotaDescription),
            "required_capabilities": .array(descriptor.requiredCapabilities.map { .string($0.rawValue) })
        ])
    }

    private func requiresApproval(toolID: String, arguments: [String: AgentJSONValue]) -> Bool {
        if toolDescriptors().first(where: { $0.id == toolID })?.needsApproval == true {
            return true
        }
        switch toolID {
        case "shell.run":
            return ShellToolService.commandNeedsApproval(arguments["command"]?.stringValue ?? "")
        default:
            return false
        }
    }

    private func approvalSummary(toolID: String, arguments: [String: AgentJSONValue]) -> String {
        switch toolID {
        case "git.clone_repository":
            return "Create a new local workspace from \(arguments["repository"]?.stringValue ?? AppSettings.shared.agentGitHubRepository)."
        case "workspace.write_file":
            return "Write \(arguments["path"]?.stringValue ?? "a file") in the active workspace."
        case "workspace.create_folder":
            return "Create \(arguments["path"]?.stringValue ?? "a folder") in the active workspace."
        case "workspace.move":
            return "Move \(arguments["source"]?.stringValue ?? "an item") to \(arguments["destination"]?.stringValue ?? "a new path")."
        case "workspace.delete":
            return "Delete \(arguments["path"]?.stringValue ?? "an item") from the active workspace."
        case "workspace.restore_checkpoint":
            return "Restore checkpoint \(arguments["checkpoint_id"]?.stringValue ?? "")."
        case "workspace.create_checkpoint":
            return "Create a checkpoint for the active workspace."
        case "workspace.reset_seed":
            return "Reset the built-in OllamaKit workspace to the bundled seed."
        case "web.scaffold_static":
            return "Create a preview web app scaffold in the active workspace."
        case "browser.type":
            return "Type into \(arguments["selector"]?.stringValue ?? "the selected field") on the current page."
        case "browser.click":
            return "Click \(arguments["selector"]?.stringValue ?? "the selected element") on the current page."
        case "browser.submit_form":
            return "Submit \(arguments["selector"]?.stringValue ?? "the selected form") on the current page."
        case "browser.download":
            return "Download \(arguments["url"]?.stringValue ?? "the current page") into the workspace."
        case "browser.save_page_to_workspace":
            return "Save the current browser page into \(arguments["path"]?.stringValue ?? "the workspace")."
        case "github.create_branch":
            return "Create or confirm the branch \(arguments["branch"]?.stringValue ?? "")."
        case "github.create_pr":
            return "Create a pull request from \(arguments["head"]?.stringValue ?? "") to \(arguments["base"]?.stringValue ?? "the default branch")."
        case "github.rerun_workflow":
            return "Rerun GitHub Actions run \(arguments["run_id"]?.stringValue ?? arguments["run_id"]?.intValue.map(String.init) ?? "")."
        case "github.refresh_builtin_workspace":
            return "Refresh the built-in workspace from \(arguments["repository"]?.stringValue ?? AppSettings.shared.agentGitHubRepository)."
        case "github.push_workspace_snapshot":
            return "Push the current workspace snapshot to \(arguments["repository"]?.stringValue ?? AppSettings.shared.agentGitHubRepository)."
        case "relay.reconnect":
            return "Reconnect the managed public relay session."
        case "shell.run":
            return "Run the shell-style command: \(arguments["command"]?.stringValue ?? "")"
        default:
            return "Run \(toolID)."
        }
    }
}
