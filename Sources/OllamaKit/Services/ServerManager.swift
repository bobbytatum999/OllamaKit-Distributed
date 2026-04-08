import Foundation
import Network
import OllamaCore

private struct ServerRequestContext: Sendable {
    let connectionId: UUID
    let remoteAddress: String?
    let startTime: Date
    
    init(connectionId: UUID = UUID(), remoteAddress: String? = nil, startTime: Date = Date()) {
        self.connectionId = connectionId
        self.remoteAddress = remoteAddress
        self.startTime = startTime
    }
}

final class ServerManager {
    static let shared = ServerManager()
    private static let iso8601Formatter = ISO8601DateFormatter()
    private static let iso8601FormatterLock = NSLock()

    private let queue = DispatchQueue(label: "com.ollamakit.server", qos: .userInitiated)
    private let stateLock = NSLock()
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private(set) var isRunning = false
    
    var isServerRunning: Bool { isRunning }
    private var isStarting = false
    private var startupContinuation: CheckedContinuation<Void, Never>?

    private init() {}

    private func log(
        _ category: ServerLogCategory,
        level: ServerLogLevel = .info,
        title: String,
        message: String,
        requestID: String? = nil,
        metadata: [String: String]? = nil
    ) {
        let timestamp = Self.iso8601FormatterLock.withLock {
            Self.iso8601Formatter.string(from: Date())
        }
        
        var logLine = "[\(timestamp)] [Server:\(category.rawValue)] [\(level.rawValue.uppercased())] \(title): \(message)"
        if let requestID = requestID {
            logLine += " (Request: \(requestID))"
        }
        if let metadata = metadata, !metadata.isEmpty {
            logLine += " \(metadata)"
        }
        print(logLine)
    }

    private func logResponse(
        status: Int,
        message: String,
        on connection: NWConnection,
        requestID: String? = nil
    ) {
        log(.response, 
            level: status >= 400 ? .error : .info,
            title: "HTTP \(status)", 
            message: message,
            requestID: requestID,
            metadata: ["remote": remoteAddress(for: connection)]
        )
    }

    fileprivate static func redactedLogText(_ value: String) -> String {
        if value.count <= 8 { return "********" }
        let head = value.prefix(4)
        let tail = value.suffix(4)
        return "\(head)...\(tail)"
    }

    func startServerIfEnabled() async {
        // Implementation would go here
    }

    func startServer() async {
        stateLock.lock()
        guard !isRunning && !isStarting else {
            stateLock.unlock()
            return
        }
        isStarting = true
        stateLock.unlock()

        log(.connection, title: "Starting Server", message: "Initializing network listener...")

        let gate = ContinuationGate()
        
        do {
            let port = NWEndpoint.Port(rawValue: 11434)!
            let listener = try NWListener(using: .tcp, on: port)
            
            listener.stateUpdateHandler = { [weak self] state in
                self?.handleListenerState(state, port: port)
                if case .ready = state {
                    gate.resumeIfNeeded(self?.startupContinuation)
                }
            }
            
            listener.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }
            
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                stateLock.lock()
                self.startupContinuation = continuation
                self.listener = listener
                stateLock.unlock()
                
                listener.start(queue: queue)
            }
            
            stateLock.lock()
            isRunning = true
            isStarting = false
            startupContinuation = nil
            stateLock.unlock()
            
            log(.connection, title: "Server Ready", message: "Listening on port \(port.rawValue)")
            
        } catch {
            stateLock.lock()
            isStarting = false
            startupContinuation = nil
            stateLock.unlock()
            log(.connection, level: .error, title: "Startup Failed", message: error.localizedDescription)
        }
    }

    func stopServer() async {
        stateLock.lock()
        guard isRunning else {
            stateLock.unlock()
            return
        }
        let listener = self.listener
        let connections = self.connections
        self.listener = nil
        self.connections = [:]
        self.isRunning = false
        stateLock.unlock()

        listener?.cancel()
        for connection in connections.values {
            connection.cancel()
        }
        
        log(.connection, title: "Server Stopped", message: "All connections closed.")
    }

    func restartServerIfRunning() async {
        stateLock.lock()
        let wasRunning = isRunning
        stateLock.unlock()
        
        if wasRunning {
            await stopServer()
            await startServer()
        }
    }

    private func handleListenerState(_ state: NWListener.State, port: NWEndpoint.Port) {
        switch state {
        case .ready:
            break
        case .failed(let error):
            log(.connection, level: .error, title: "Listener Failed", message: error.localizedDescription)
            Task { await stopServer() }
        case .cancelled:
            log(.connection, title: "Listener Cancelled", message: "Server shutdown complete.")
        default:
            break
        }
    }

    private func handleConnection(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        
        stateLock.lock()
        connections[id] = connection
        stateLock.unlock()
        
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.receiveHTTPRequest(on: connection)
            case .failed(let error):
                self?.log(.connection, level: .error, title: "Connection Failed", message: error.localizedDescription)
                self?.cleanupConnection(id)
            case .cancelled:
                self?.cleanupConnection(id)
            default:
                break
            }
        }
        
        connection.start(queue: queue)
    }

    private func cleanupConnection(_ id: ObjectIdentifier) {
        stateLock.lock()
        connections.removeValue(forKey: id)
        stateLock.unlock()
    }

    private func allowsConnection(_ connection: NWConnection) -> Bool {
        // Simplified security check
        return true
    }

    private func isLoopback(_ host: NWEndpoint.Host) -> Bool {
        switch host {
        case .ipv4(let address):
            return address == .loopback
        case .ipv6(let address):
            return address == .loopback
        default:
            return false
        }
    }

    private func receiveHTTPRequest(on connection: NWConnection) {
        receiveHTTPRequest(on: connection, buffer: Data())
    }

    private func receiveHTTPRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, context, isComplete, error in
            guard let self = self else { return }
            
            if let error = error {
                self.log(.connection, level: .error, title: "Receive Error", message: error.localizedDescription)
                connection.cancel()
                return
            }

            var accumulated = buffer
            if let data = data {
                accumulated.append(data)
            }

            if let request = String(data: accumulated, encoding: .utf8), request.contains("\r\n\r\n") {
                self.handleHTTPRequest(request, on: connection)
                return
            }

            if isComplete {
                self.log(.request, level: .warning, title: "Incomplete Request", message: "Connection closed before the request completed.", metadata: ["remote": self.remoteAddress(for: connection)])
                self.sendErrorResponse(status: 400, message: "Bad Request", on: connection)
                return
            }

            self.receiveHTTPRequest(on: connection, buffer: accumulated)
        }
    }

    private func handleHTTPRequest(_ request: String, on connection: NWConnection) {
        let lines = request.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            sendErrorResponse(status: 400, message: "Bad Request", on: connection)
            return
        }

        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2 else {
            sendErrorResponse(status: 400, message: "Bad Request", on: connection)
            return
        }

        let method = parts[0]
        let path = parts[1]
        let requestID = UUID().uuidString.prefix(8).lowercased()
        
        let context = ServerRequestContext(
            connectionId: UUID(),
            remoteAddress: remoteAddress(for: connection),
            startTime: Date()
        )

        log(.request, title: "\(method) \(path)", message: "Processing request...", requestID: String(requestID), metadata: ["remote": context.remoteAddress ?? "unknown"])

        // Routing logic
        if path == "/api/tags" || path == "/v1/models" {
            if path.hasPrefix("/v1") {
                handleOpenAIListModels(on: connection, context: context)
            } else {
                handleLegacyListModels(on: connection, context: context)
            }
        } else if path == "/api/show" {
            handleLegacyShow(request: request, on: connection, context: context)
        } else if path == "/api/generate" {
            handleLegacyGenerate(request: request, on: connection, context: context)
        } else if path == "/api/chat" {
            handleLegacyChat(request: request, on: connection, context: context)
        } else if path == "/v1/completions" {
            handleOpenAICompletion(request: request, on: connection, context: context)
        } else if path == "/v1/chat/completions" {
            handleOpenAIChatCompletion(request: request, on: connection, context: context)
        } else if path == "/api/embeddings" {
            handleLegacyEmbeddings(request: request, on: connection, context: context)
        } else if path == "/v1/embeddings" {
            handleOpenAIEmbeddings(request: request, on: connection, context: context)
        } else if path == "/api/pull" {
            handlePull(request: request, on: connection, context: context)
        } else if path == "/api/delete" {
            handleDelete(request: request, on: connection, context: context)
        } else if path == "/api/ps" {
            handleRunningModels(on: connection, context: context)
        } else {
            log(.request, level: .warning, title: "Not Found", message: "No route for \(path)", requestID: String(requestID))
            sendErrorResponse(status: 404, message: "Not Found", on: connection, requestID: String(requestID))
        }
    }

    func handleLegacyListModels(on connection: NWConnection, context: ServerRequestContext) {
        // Implementation
    }

    func handleOpenAIListModels(on connection: NWConnection, context: ServerRequestContext) {
        // Implementation
    }

    func handleLegacyShow(request: String, on connection: NWConnection, context: ServerRequestContext) {
        // Implementation
    }

    func handleLegacyGenerate(request: String, on connection: NWConnection, context: ServerRequestContext) {
        // Implementation
    }

    func handleLegacyChat(request: String, on connection: NWConnection, context: ServerRequestContext) {
        // Implementation
    }

    func handleOpenAICompletion(request: String, on connection: NWConnection, context: ServerRequestContext) {
        // Implementation
    }

    func handleOpenAIChatCompletion(request: String, on connection: NWConnection, context: ServerRequestContext) {
        // Implementation
    }

    func handleLegacyEmbeddings(request: String, on connection: NWConnection, context: ServerRequestContext) {
        // Implementation
    }

    func handleOpenAIEmbeddings(request: String, on connection: NWConnection, context: ServerRequestContext) {
        // Implementation
    }

    func handleOpenAIResponses(request: String, on connection: NWConnection, context: ServerRequestContext) {
        // Implementation
    }

    func handlePull(request: String, on connection: NWConnection, context: ServerRequestContext) {
        // Implementation
    }

    func handleDelete(request: String, on connection: NWConnection, context: ServerRequestContext) {
        // Implementation
    }

    func handleRunningModels(on connection: NWConnection, context: ServerRequestContext) {
        // Implementation
    }

    func prepareModel(
        named name: String,
        context: ServerRequestContext
    ) async throws -> ModelSnapshot {
        // Implementation
        throw NSError(domain: "OllamaKit", code: 500, userInfo: [NSLocalizedDescriptionKey: "Not implemented"])
    }

    func serverModels() async -> [ModelSnapshot] {
        return []
    }

    func remoteAddress(for connection: NWConnection) -> String {
        if case .hostPort(let host, let port) = connection.endpoint {
            return "\(host):\(port)"
        }
        return "unknown"
    }

    func sendErrorResponse(
        status: Int,
        message: String,
        on connection: NWConnection,
        requestID: String? = nil
    ) {
        let response = """
        HTTP/1.1 \(status) \(message)\r
        Content-Type: application/json\r
        Connection: close\r
        \r
        {"error": "\(message)"}
        """
        
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { [weak self] _ in
            self?.logResponse(status: status, message: message, on: connection, requestID: requestID)
            connection.cancel()
        })
    }

    func httpStatus(for error: Error) -> Int {
        let nsError = error as NSError
        switch nsError.code {
        case 400, 401, 403, 404, 501:
            return nsError.code
        default:
            return 500
        }
    }

    func openAIErrorType(for status: Int) -> String {
        switch status {
        case 401:
            return "authentication_error"
        case 400, 403, 404:
            return "invalid_request_error"
        case 501:
            return "not_implemented_error"
        default:
            return "server_error"
        }
    }
}

private final class ContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false

    func resumeIfNeeded(_ continuation: CheckedContinuation<Void, Never>?) {
        guard let continuation = continuation else { return }
        let shouldResume = lock.withLock { () -> Bool in
            guard !didResume else { return false }
            didResume = true
            return true
        }

        guard shouldResume else { return }
        continuation.resume()
    }
}
