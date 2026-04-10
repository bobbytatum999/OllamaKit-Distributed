import Foundation
import Network
import OllamaCore

// MARK: - Request Context

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

// MARK: - Server Manager

final class ServerManager: @unchecked Sendable {
    static let shared = ServerManager()

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        return f
    }()

    private let queue = DispatchQueue(label: "com.ollamakit.server", qos: .userInitiated)
    private let stateLock = NSLock()
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private(set) var isRunning = false
    private var isStarting = false

    private init() {}

    // MARK: - Public API

    var isServerRunning: Bool { isRunning }

    func startServer() async {
        stateLock.lock()
        guard !isRunning && !isStarting else {
            stateLock.unlock()
            return
        }
        isStarting = true
        stateLock.unlock()

        log(category: .app, level: .info, title: "Starting Server", message: "Initializing network listener on port 11434...")

        do {
            let port = NWEndpoint.Port(rawValue: 11434)!
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true

            let listener = try NWListener(using: parameters, on: port)

            var pendingContinuation: CheckedContinuation<Void, Never>?

            listener.stateUpdateHandler = { [weak self] state in
                guard let self = self else { return }
                switch state {
                case .ready:
                    self.stateLock.lock()
                    self.isRunning = true
                    self.isStarting = false
                    self.stateLock.unlock()
                    // FIX: Resume on a different queue to avoid deadlock.
                    // NWListener.stateUpdateHandler fires on the listener's queue (our serial `queue`).
                    // If we resume the continuation on the same serial queue while start() is blocking
                    // on that queue, we deadlock. Dispatch to a concurrent queue to break the cycle.
                    DispatchQueue.global(qos: .userInitiated).async {
                        pendingContinuation?.resume()
                        pendingContinuation = nil
                    }
                    self.log(category: .app, level: .info, title: "Server Ready", message: "Listening on port \(port.rawValue)")

                case .failed(let error):
                    self.stateLock.lock()
                    self.isStarting = false
                    self.stateLock.unlock()
                    self.log(category: .app, level: .error, title: "Listener Failed", message: error.localizedDescription)
                    DispatchQueue.global(qos: .userInitiated).async {
                        pendingContinuation?.resume()
                        pendingContinuation = nil
                    }
                    Task { await self.stopServer() }

                case .cancelled:
                    self.log(category: .app, level: .info, title: "Listener Cancelled", message: "Server shutdown complete.")

                default:
                    break
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                self?.handleNewConnection(connection)
            }

            self.listener = listener

            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                pendingContinuation = continuation
                // FIX: Start the listener asynchronously so the continuation can be registered
                // before the handler fires. Without async, start() can block on the serial queue
                // if NWListener fires .ready synchronously, causing a deadlock.
                queue.async {
                    listener.start(queue: self.queue)
                }
            }

        } catch {
            stateLock.lock()
            isStarting = false
            stateLock.unlock()
            log(category: .app, level: .error, title: "Startup Failed", message: error.localizedDescription)
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

        log(category: .app, level: .info, title: "Server Stopped", message: "All connections closed.")
    }

    func startServerIfEnabled() async {
        let serverEnabled = await MainActor.run { AppSettings.shared.serverEnabled }
        guard serverEnabled else { return }
        await startServer()
    }

    func restartServerIfRunning() async {
        stateLock.lock()
        let wasRunning = isRunning
        stateLock.unlock()

        if wasRunning {
            await stopServer()
            try? await Task.sleep(nanoseconds: 500_000_000)
            await startServer()
        }
    }

    func serverModels() async -> [ModelSnapshot] {
        await ModelStorage.shared.installedSnapshots
    }

    // MARK: - Connection Handling

    private func handleNewConnection(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)

        guard allowsConnection(connection) else {
            log(category: .app, level: .warning, title: "Connection Rejected", message: "Blocked by security policy", metadata: ["remote": remoteAddress(for: connection)])
            connection.cancel()
            return
        }

        stateLock.lock()
        connections[id] = connection
        stateLock.unlock()

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed(let error):
                self?.log(category: .app, level: .error, title: "Connection Failed", message: error.localizedDescription, metadata: ["remote": self?.remoteAddress(for: connection) ?? "unknown"])
                self?.cleanupConnection(id)
            case .cancelled:
                self?.cleanupConnection(id)
            default:
                break
            }
        }

        connection.start(queue: queue)
        receiveRequest(on: connection)
    }

    private func cleanupConnection(_ id: ObjectIdentifier) {
        stateLock.lock()
        connections.removeValue(forKey: id)
        stateLock.unlock()
    }

    private func allowsConnection(_ connection: NWConnection) -> Bool {
        let isLocalOnly = ServerManager.readServerExposureModeRaw() == "localOnly"
        guard !isLocalOnly else {
            guard let endpoint = connection.currentPath?.remoteEndpoint else { return false }
            return isLoopbackHost(endpoint)
        }
        return true
    }

    private func isLoopbackHost(_ endpoint: NWEndpoint) -> Bool {
        if case .hostPort(let host, _) = endpoint {
            switch host {
            case .ipv4(let addr): return addr == .loopback
            case .ipv6(let addr): return addr == .loopback
            default: return false
            }
        }
        return false
    }

    // MARK: - HTTP Request Loop

    private func receiveRequest(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }

            if let error = error {
                self.log(category: .app, level: .error, title: "Receive Error", message: error.localizedDescription)
                connection.cancel()
                return
            }

            guard var accumulated = data else {
                if isComplete {
                    self.sendErrorResponse(status: 400, message: "Bad Request", on: connection)
                }
                return
            }

            if let requestText = String(data: accumulated, encoding: .utf8), requestText.contains("\r\n\r\n") {
                self.handleHTTPRequest(requestText, on: connection)
            } else if !isComplete {
                self.receiveMore(on: connection, accumulated: accumulated)
            } else {
                self.sendErrorResponse(status: 400, message: "Bad Request", on: connection)
            }
        }
    }

    private func receiveMore(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }

            if error != nil {
                connection.cancel()
                return
            }

            var buffer = accumulated
            if let newData = data {
                buffer.append(newData)
            }

            if let requestText = String(data: buffer, encoding: .utf8), requestText.contains("\r\n\r\n") {
                self.handleHTTPRequest(requestText, on: connection)
            } else if !isComplete && buffer.count < 65536 {
                self.receiveMore(on: connection, accumulated: buffer)
            } else {
                self.sendErrorResponse(status: 400, message: "Bad Request", on: connection)
            }
        }
    }

    // MARK: - HTTP Routing

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
        let requestID = String(UUID().uuidString.prefix(8).lowercased())

        var headers: [String: String] = [:]
        var bodyStartIndex = 0
        for (i, line) in lines.enumerated() {
            if line.isEmpty {
                bodyStartIndex = i
                break
            }
            let headerParts = line.split(separator: ":", maxSplits: 1)
            if headerParts.count == 2 {
                headers[headerParts[0].trimmingCharacters(in: .whitespaces).lowercased()] =
                    String(headerParts[1]).trimmingCharacters(in: .whitespaces)
            }
        }

        var body = ""
        if bodyStartIndex > 0 && bodyStartIndex < lines.count - 1 {
            body = lines[(bodyStartIndex + 1)...].joined(separator: "\r\n")
        }

        let context = ServerRequestContext(
            connectionId: UUID(),
            remoteAddress: remoteAddress(for: connection),
            startTime: Date()
        )

        log(category: .app, level: .info, title: "\(method) \(path)", message: "Processing request...", metadata: ["remote": context.remoteAddress ?? "unknown", "request_id": requestID])

        let exposureModeRaw = ServerManager.readServerExposureModeRaw()
        let isPublicMode = (exposureModeRaw == "publicManaged" || exposureModeRaw == "publicCustom")
        let requireApiKeyEnabled = UserDefaults.standard.bool(forKey: "requireApiKey")
        let storedApiKey = UserDefaults.standard.string(forKey: "apiKey") ?? ""

        if isPublicMode || requireApiKeyEnabled {
            let providedKey = headers["authorization"]?.replacingOccurrences(of: "Bearer ", with: "").trimmingCharacters(in: .whitespaces)
            if providedKey != storedApiKey {
                sendOpenAIErrorResponse(status: 401, message: "Invalid API key.", on: connection, requestID: requestID)
                return
            }
        }

        switch (method, path) {
        case ("GET", "/"), ("GET", "/v1/models"):
            handleOpenAIListModels(on: connection, context: context, requestID: requestID)

        case ("POST", "/v1/chat/completions"):
            handleOpenAIChatCompletion(request: body, on: connection, context: context, requestID: requestID)

        case ("POST", "/v1/completions"):
            handleOpenAICompletion(request: body, on: connection, context: context, requestID: requestID)

        case ("POST", "/v1/embeddings"):
            handleOpenAIEmbeddings(request: body, on: connection, context: context, requestID: requestID)

        case ("GET", "/api/tags"):
            handleLegacyListModels(on: connection, context: context, requestID: requestID)

        case ("POST", "/api/generate"):
            handleLegacyGenerate(request: body, on: connection, context: context, requestID: requestID)

        case ("POST", "/api/chat"):
            handleLegacyChat(request: body, on: connection, context: context, requestID: requestID)

        case ("POST", "/api/show"):
            handleLegacyShow(request: body, on: connection, context: context, requestID: requestID)

        case ("POST", "/api/embeddings"):
            handleLegacyEmbeddings(request: body, on: connection, context: context, requestID: requestID)

        case ("GET", "/api/ps"):
            handleRunningModels(on: connection, context: context, requestID: requestID)

        case (_, _) where path.hasPrefix("/v1/models/"):
            handleOpenAIModelInfo(path: path, on: connection, context: context, requestID: requestID)

        default:
            log(category: .app, level: .warning, title: "Not Found", message: "No route for \(method) \(path)", metadata: ["request_id": requestID])
            sendErrorResponse(status: 404, message: "Not Found", on: connection, requestID: requestID)
        }
    }

    // MARK: - OpenAI-Compatible Endpoints

    private func handleOpenAIListModels(on connection: NWConnection, context: ServerRequestContext, requestID: String) {
        Task {
            let models = await serverModels()
            let openAIModels = models.map { model -> [String: Any] in
                [
                    "id": model.catalogId,
                    "object": "model",
                    "created": Int(model.downloadDate.timeIntervalSince1970),
                    "owned_by": "ollamakit",
                    "permission": [],
                    "root": model.catalogId
                ]
            }

            let response: [String: Any] = [
                "object": "list",
                "data": openAIModels
            ]

            await sendJSONResponse(response, status: 200, on: connection, requestID: requestID)
        }
    }

    private func handleOpenAIModelInfo(path: String, on connection: NWConnection, context: ServerRequestContext, requestID: String) {
        let modelId = String(path.dropFirst("/v1/models/".count))
        Task {
            let models = await serverModels()
            guard let model = models.first(where: { $0.catalogId == modelId }) else {
                await sendErrorResponse(status: 404, message: "Model not found", on: connection, requestID: requestID)
                return
            }

            let response: [String: Any] = [
                "id": model.catalogId,
                "object": "model",
                "created": Int(model.downloadDate.timeIntervalSince1970),
                "owned_by": "ollamakit",
                "permission": [],
                "root": model.catalogId
            ]

            await sendJSONResponse(response, status: 200, on: connection, requestID: requestID)
        }
    }

    private func handleOpenAIChatCompletion(request body: String, on connection: NWConnection, context: ServerRequestContext, requestID: String) {
        guard let bodyData = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] else {
            sendOpenAIErrorResponse(status: 400, message: "Invalid JSON body.", on: connection, requestID: requestID)
            return
        }

        let modelId = json["model"] as? String ?? ""
        let messages = json["messages"] as? [[String: Any]] ?? []
        let stream = json["stream"] as? Bool ?? false
        let temperature = json["temperature"] as? Double ?? 0.7
        let maxTokens = json["max_tokens"] as? Int ?? 1024
        let topP = json["top_p"] as? Double ?? 0.9
        let stop = json["stop"] as? [String]

        guard !modelId.isEmpty else {
            sendOpenAIErrorResponse(status: 400, message: "model is required.", on: connection, requestID: requestID)
            return
        }

        var systemPrompt: String?
        var conversationTurns: [ConversationTurn] = []

        for msg in messages {
            guard let role = msg["role"] as? String, let content = msg["content"] as? String else { continue }
            switch role {
            case "system":
                systemPrompt = (systemPrompt ?? "") + "\n" + content
            case "user":
                conversationTurns.append(ConversationTurn(role: "user", content: content))
            case "assistant":
                conversationTurns.append(ConversationTurn(role: "assistant", content: content))
            default:
                break
            }
        }

        let params = SamplingParameters(
            temperature: temperature,
            topP: topP,
            topK: 40,
            repeatPenalty: 1.1,
            repeatLastN: 64,
            maxTokens: maxTokens,
            stopSequences: stop ?? []
        )

        if stream {
            handleStreamingChat(modelId: modelId, systemPrompt: systemPrompt, turns: conversationTurns, parameters: params, on: connection, context: context, requestID: requestID)
        } else {
            handleBlockingChat(modelId: modelId, systemPrompt: systemPrompt, turns: conversationTurns, parameters: params, on: connection, context: context, requestID: requestID)
        }
    }

    private func handleBlockingChat(modelId: String, systemPrompt: String?, turns: [ConversationTurn], parameters: SamplingParameters, on connection: NWConnection, context: ServerRequestContext, requestID: String) {
        Task {
            do {
                var fullText = ""
                let result = try await ModelRunner.shared.generate(
                    prompt: "",
                    systemPrompt: systemPrompt,
                    conversationTurns: turns,
                    parameters: SamplingParameters(
                        temperature: parameters.temperature,
                        topP: parameters.topP,
                        topK: parameters.topK,
                        repeatPenalty: parameters.repeatPenalty,
                        repeatLastN: parameters.repeatLastN,
                        maxTokens: parameters.maxTokens,
                        stopSequences: parameters.stopSequences
                    ),
                    onToken: { token in
                        fullText += token
                    }
                )

                let response: [String: Any] = [
                    "id": "chatcmpl-\(UUID().uuidString.prefix(8))",
                    "object": "chat.completion",
                    "created": Int(Date().timeIntervalSince1970),
                    "model": modelId,
                    "choices": [
                        [
                            "index": 0,
                            "message": [
                                "role": "assistant",
                                "content": fullText
                            ],
                            "finish_reason": result.wasCancelled ? "stop" : "stop"
                        ] as [String: Any]
                    ],
                    "usage": [
                        "prompt_tokens": result.promptTokens,
                        "completion_tokens": result.tokensGenerated,
                        "total_tokens": result.promptTokens + result.tokensGenerated
                    ]
                ]

                await sendJSONResponse(response, status: 200, on: connection, requestID: requestID)
            } catch {
                await sendOpenAIErrorResponse(status: 500, message: error.localizedDescription, on: connection, requestID: requestID)
            }
        }
    }

    private func handleStreamingChat(modelId: String, systemPrompt: String?, turns: [ConversationTurn], parameters: SamplingParameters, on connection: NWConnection, context: ServerRequestContext, requestID: String) {
        let completionId = "chatcmpl-\(UUID().uuidString.prefix(8))"
        let created = Int(Date().timeIntervalSince1970)

        func sendSSEEvent(_ data: [String: Any]) {
            guard let jsonData = try? JSONSerialization.data(withJSONObject: data),
                  let jsonString = String(data: jsonData, encoding: .utf8) else { return }
            let sse = "data: \(jsonString)\n\n"
            connection.send(content: sse.data(using: .utf8), completion: .idempotent)
        }

        let headers = [
            "HTTP/1.1 200 OK",
            "Content-Type: text/event-stream",
            "Cache-Control: no-cache",
            "Connection: keep-alive",
            "Access-Control-Allow-Origin: *",
            "\r\n"
        ].joined(separator: "\r\n")

        connection.send(content: headers.data(using: .utf8), completion: .contentProcessed { _ in })

        Task {
            do {
                _ = try await ModelRunner.shared.generate(
                    prompt: "",
                    systemPrompt: systemPrompt,
                    conversationTurns: turns,
                    parameters: parameters,
                    onToken: { token in
                        let delta: [String: Any] = [
                            "id": completionId,
                            "object": "chat.completion.chunk",
                            "created": created,
                            "model": modelId,
                            "choices": [
                                [
                                    "index": 0,
                                    "delta": ["content": token],
                                    "finish_reason": NSNull()
                                ]
                            ]
                        ]
                        sendSSEEvent(delta)
                    }
                )

                let finalChunk: [String: Any] = [
                    "id": completionId,
                    "object": "chat.completion.chunk",
                    "created": created,
                    "model": modelId,
                    "choices": [["index": 0, "delta": [:], "finish_reason": "stop"]]
                ]
                sendSSEEvent(finalChunk)
                connection.send(content: "data: [DONE]\n\n".data(using: .utf8), completion: .contentProcessed { [weak self] _ in
                    self?.logResponse(status: 200, message: "Stream completed", on: connection, requestID: requestID)
                    connection.cancel()
                })
            } catch {
                sendSSEEvent(["error": ["message": error.localizedDescription, "type": "server_error"]])
                // FIX: Always send [DONE] even on error so clients don't hang waiting for it
                connection.send(content: "data: [DONE]\n\n".data(using: .utf8), completion: .idempotent)
                connection.cancel()
            }
        }
    }

    private func handleOpenAICompletion(request body: String, on connection: NWConnection, context: ServerRequestContext, requestID: String) {
        guard let bodyData = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] else {
            sendOpenAIErrorResponse(status: 400, message: "Invalid JSON body.", on: connection, requestID: requestID)
            return
        }

        let model = json["model"] as? String ?? ""
        let prompt = (json["prompt"] as? String) ?? ""
        let stream = json["stream"] as? Bool ?? false
        let temperature = json["temperature"] as? Double ?? 0.7
        let maxTokens = json["max_tokens"] as? Int ?? 256

        if stream {
            handleStreamingCompletion(prompt: prompt, modelId: model, temperature: temperature, maxTokens: maxTokens, on: connection, context: context, requestID: requestID)
        } else {
            handleBlockingCompletion(prompt: prompt, modelId: model, temperature: temperature, maxTokens: maxTokens, on: connection, context: context, requestID: requestID)
        }
    }

    private func handleBlockingCompletion(prompt: String, modelId: String, temperature: Double, maxTokens: Int, on connection: NWConnection, context: ServerRequestContext, requestID: String) {
        Task {
            do {
                var fullText = ""
                _ = try await ModelRunner.shared.generate(
                    prompt: prompt,
                    parameters: SamplingParameters(temperature: temperature, topP: 0.9, topK: 40, repeatPenalty: 1.1, repeatLastN: 64, maxTokens: maxTokens, stopSequences: []),
                    onToken: { token in
                        fullText += token
                    }
                )

                let response: [String: Any] = [
                    "id": "cmpl-\(UUID().uuidString.prefix(8))",
                    "object": "text_completion",
                    "created": Int(Date().timeIntervalSince1970),
                    "model": modelId,
                    "choices": [["text": fullText, "index": 0, "finish_reason": "stop"]],
                    "usage": ["prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0]
                ]

                await sendJSONResponse(response, status: 200, on: connection, requestID: requestID)
            } catch {
                await sendOpenAIErrorResponse(status: 500, message: error.localizedDescription, on: connection, requestID: requestID)
            }
        }
    }

    private func handleStreamingCompletion(prompt: String, modelId: String, temperature: Double, maxTokens: Int, on connection: NWConnection, context: ServerRequestContext, requestID: String) {
        let headers = [
            "HTTP/1.1 200 OK",
            "Content-Type: text/event-stream",
            "Cache-Control: no-cache",
            "Connection: keep-alive",
            "Access-Control-Allow-Origin: *",
            "\r\n"
        ].joined(separator: "\r\n")

        connection.send(content: headers.data(using: .utf8), completion: .contentProcessed { _ in })

        func sendSSE(_ text: String) {
            let chunk: [String: Any] = [
                "id": "cmpl-\(UUID().uuidString.prefix(8))",
                "object": "text_completion",
                "created": Int(Date().timeIntervalSince1970),
                "model": modelId,
                "choices": [["text": text, "index": 0, "finish_reason": NSNull()]]
            ]
            if let jsonData = try? JSONSerialization.data(withJSONObject: chunk),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                connection.send(content: "data: \(jsonString)\n\n".data(using: .utf8), completion: .idempotent)
            }
        }

        Task {
            do {
                _ = try await ModelRunner.shared.generate(
                    prompt: prompt,
                    parameters: SamplingParameters(temperature: temperature, topP: 0.9, topK: 40, repeatPenalty: 1.1, repeatLastN: 64, maxTokens: maxTokens, stopSequences: []),
                    onToken: { token in
                        sendSSE(token)
                    }
                )
                connection.send(content: "data: [DONE]\n\n".data(using: .utf8), completion: .contentProcessed { [weak self] _ in
                    self?.logResponse(status: 200, message: "Stream completed", on: connection, requestID: requestID)
                    connection.cancel()
                })
            } catch {
                // FIX: Always send [DONE] so SSE clients don't hang
                connection.send(content: "data: [DONE]\n\n".data(using: .utf8), completion: .idempotent)
                connection.cancel()
            }
        }
    }

    private func handleOpenAIEmbeddings(request body: String, on connection: NWConnection, context: ServerRequestContext, requestID: String) {
        let response: [String: Any] = [
            "object": "list",
            "data": [],
            "model": "unknown",
            "usage": ["prompt_tokens": 0, "total_tokens": 0]
        ]
        Task {
            await sendJSONResponse(response, status: 200, on: connection, requestID: requestID)
        }
    }

    // MARK: - Legacy Ollama Endpoints

    private func handleLegacyListModels(on connection: NWConnection, context: ServerRequestContext, requestID: String) {
        Task {
            let models = await serverModels()
            let modelsList = models.map { model -> [String: Any] in
                [
                    "name": model.catalogId,
                    "model": model.catalogId,
                    "size": model.size,
                    "digest": "sha256:\(model.catalogId.hashValue)",
                    "details": [
                        "parent_model": "",
                        "format": "gguf",
                        "family": "llama",
                        "families": ["llama"],
                        "parameter_size": model.quantization,
                        "quantization_level": model.quantization
                    ]
                ]
            }

            let response: [String: Any] = ["models": modelsList]
            await sendJSONResponse(response, status: 200, on: connection, requestID: requestID)
        }
    }

    private func handleLegacyShow(request body: String, on connection: NWConnection, context: ServerRequestContext, requestID: String) {
        guard let bodyData = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
              let name = json["name"] as? String else {
            sendErrorResponse(status: 400, message: "name is required", on: connection, requestID: requestID)
            return
        }

        Task {
            let models = await serverModels()
            let modelDisplayNames = await MainActor.run { models.map { $0.displayName } }
            guard let modelIndex = models.indices.first(where: { models[$0].catalogId == name || modelDisplayNames[$0] == name }) else {
                await sendErrorResponse(status: 404, message: "model not found", on: connection, requestID: requestID)
                return
            }
            let model = models[modelIndex]

            let response: [String: Any] = [
                "name": model.catalogId,
                "model": model.catalogId,
                "size": model.size,
                "digest": "sha256:\(model.catalogId.hashValue)",
                "details": [
                    "parent_model": "",
                    "format": "gguf",
                    "family": "llama",
                    "families": ["llama"],
                    "parameter_size": model.quantization,
                    "quantization_level": model.quantization
                ]
            ]

            await sendJSONResponse(response, status: 200, on: connection, requestID: requestID)
        }
    }

    private func handleLegacyGenerate(request body: String, on connection: NWConnection, context: ServerRequestContext, requestID: String) {
        guard let bodyData = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
              let modelName = json["model"] as? String ?? json["name"] as? String,
              let prompt = json["prompt"] as? String else {
            sendErrorResponse(status: 400, message: "model and prompt are required", on: connection, requestID: requestID)
            return
        }

        let stream = json["stream"] as? Bool ?? false
        let systemPrompt = json["system"] as? String
        let temperature = json["temperature"] as? Double ?? 0.7
        let options = json["options"] as? [String: Any] ?? [:]
        let maxTokens = options["num_predict"] as? Int ?? options["max_tokens"] as? Int ?? 1024

        if stream {
            handleLegacyStreamingGenerate(modelId: modelName, prompt: prompt, systemPrompt: systemPrompt, temperature: temperature, maxTokens: maxTokens, on: connection, context: context, requestID: requestID)
        } else {
            handleLegacyBlockingGenerate(modelId: modelName, prompt: prompt, systemPrompt: systemPrompt, temperature: temperature, maxTokens: maxTokens, on: connection, context: context, requestID: requestID)
        }
    }

    private func handleLegacyBlockingGenerate(modelId: String, prompt: String, systemPrompt: String?, temperature: Double, maxTokens: Int, on connection: NWConnection, context: ServerRequestContext, requestID: String) {
        Task {
            do {
                var fullText = ""
                let result = try await ModelRunner.shared.generate(
                    prompt: prompt,
                    systemPrompt: systemPrompt,
                    parameters: SamplingParameters(temperature: temperature, topP: 0.9, topK: 40, repeatPenalty: 1.1, repeatLastN: 64, maxTokens: maxTokens, stopSequences: []),
                    onToken: { token in
                        fullText += token
                    }
                )

                let response: [String: Any] = [
                    "model": modelId,
                    "response": fullText,
                    "done": true,
                    "context": NSNull(),
                    "total_duration": Int(result.generationTime * 1_000_000_000),
                    "load_duration": 0,
                    "prompt_eval_count": result.promptTokens,
                    "eval_count": result.tokensGenerated,
                    "eval_duration": Int(result.generationTime * 1_000_000_000)
                ]

                await sendJSONResponse(response, status: 200, on: connection, requestID: requestID)
            } catch {
                await sendErrorResponse(status: 500, message: error.localizedDescription, on: connection, requestID: requestID)
            }
        }
    }

    private func handleLegacyStreamingGenerate(modelId: String, prompt: String, systemPrompt: String?, temperature: Double, maxTokens: Int, on connection: NWConnection, context: ServerRequestContext, requestID: String) {
        let headers = [
            "HTTP/1.1 200 OK",
            "Content-Type: text/event-stream",
            "Cache-Control: no-cache",
            "Connection: keep-alive",
            "\r\n"
        ].joined(separator: "\r\n")

        connection.send(content: headers.data(using: .utf8), completion: .contentProcessed { _ in })

        func sendSSE(_ data: [String: Any]) {
            if let jsonData = try? JSONSerialization.data(withJSONObject: data),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                connection.send(content: "data: \(jsonString)\n\n".data(using: .utf8), completion: .idempotent)
            }
        }

        Task {
            do {
                _ = try await ModelRunner.shared.generate(
                    prompt: prompt,
                    systemPrompt: systemPrompt,
                    parameters: SamplingParameters(temperature: temperature, topP: 0.9, topK: 40, repeatPenalty: 1.1, repeatLastN: 64, maxTokens: maxTokens, stopSequences: []),
                    onToken: { token in
                        let chunk: [String: Any] = [
                            "model": modelId,
                            "response": token,
                            "done": false
                        ]
                        sendSSE(chunk)
                    }
                )

                let final: [String: Any] = [
                    "model": modelId,
                    "response": "",
                    "done": true,
                    "context": NSNull()
                ]
                sendSSE(final)
                connection.send(content: "data: [DONE]\n\n".data(using: .utf8), completion: .contentProcessed { [weak self] _ in
                    self?.logResponse(status: 200, message: "Legacy stream completed", on: connection, requestID: requestID)
                    connection.cancel()
                })
            } catch {
                // FIX: Always send [DONE] so SSE clients don't hang
                connection.send(content: "data: [DONE]\n\n".data(using: .utf8), completion: .idempotent)
                connection.cancel()
            }
        }
    }

    private func handleLegacyChat(request body: String, on connection: NWConnection, context: ServerRequestContext, requestID: String) {
        guard let bodyData = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
              let modelName = json["model"] as? String,
              let messages = json["messages"] as? [[String: Any]] else {
            sendErrorResponse(status: 400, message: "model and messages are required", on: connection, requestID: requestID)
            return
        }

        let stream = json["stream"] as? Bool ?? false
        var systemPrompt: String?
        var turns: [ConversationTurn] = []

        for msg in messages {
            guard let role = msg["role"] as? String, let content = msg["content"] as? String else { continue }
            if role == "system" {
                systemPrompt = (systemPrompt ?? "") + "\n" + content
            } else {
                turns.append(ConversationTurn(role: role, content: content))
            }
        }

        let params = SamplingParameters(temperature: 0.7, topP: 0.9, topK: 40, repeatPenalty: 1.1, repeatLastN: 64, maxTokens: 1024, stopSequences: [])

        if stream {
            handleStreamingChat(modelId: modelName, systemPrompt: systemPrompt, turns: turns, parameters: params, on: connection, context: context, requestID: requestID)
        } else {
            handleBlockingChat(modelId: modelName, systemPrompt: systemPrompt, turns: turns, parameters: params, on: connection, context: context, requestID: requestID)
        }
    }

    private func handleLegacyEmbeddings(request body: String, on connection: NWConnection, context: ServerRequestContext, requestID: String) {
        let response: [String: Any] = [
            "model": "unknown",
            "embeddings": []
        ]
        Task {
            await sendJSONResponse(response, status: 200, on: connection, requestID: requestID)
        }
    }

    private func handleRunningModels(on connection: NWConnection, context: ServerRequestContext, requestID: String) {
        Task {
            let loadedId = ModelRunner.shared.activeCatalogId
            let models = await serverModels()
            let runningModels = models.filter { loadedId == $0.catalogId }.map { model -> [String: Any] in
                [
                    "name": model.catalogId,
                    "model": model.catalogId,
                    "size": model.size,
                    "digest": "sha256:\(model.catalogId.hashValue)",
                    "duration": NSNull()
                ]
            }

            let response: [String: Any] = ["models": runningModels]
            await sendJSONResponse(response, status: 200, on: connection, requestID: requestID)
        }
    }

    // MARK: - Response Helpers

    private func sendJSONResponse(_ json: [String: Any], status: Int, on connection: NWConnection, requestID: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: json) else {
            sendErrorResponse(status: 500, message: "Failed to encode response", on: connection, requestID: requestID)
            return
        }

        let body = String(data: data, encoding: .utf8) ?? ""
        let response = """
        HTTP/1.1 \(status) OK\r
        Content-Type: application/json\r
        Content-Length: \(data.count)\r
        Connection: close\r
        \r
        \(body)
        """

        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { [weak self] _ in
            self?.logResponse(status: status, message: "Response sent", on: connection, requestID: requestID)
            connection.cancel()
        })
    }

    private func sendErrorResponse(status: Int, message: String, on connection: NWConnection, requestID: String? = nil) {
        // FIX: Strip newlines from message to prevent HTTP header injection.
        // User-controlled data (e.g. error.localizedDescription) could otherwise
        // inject arbitrary headers via CRLF in the HTTP status line.
        let safeMessage = message
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: " ")
        let body = "{\"error\": \"\(safeMessage)\"}"
        let response = """
        HTTP/1.1 \(status) \(safeMessage)\r
        Content-Type: application/json\r
        Content-Length: \(body.utf8.count)\r
        Connection: close\r
        \r
        \(body)
        """

        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { [weak self] _ in
            self?.logResponse(status: status, message: message, on: connection, requestID: requestID)
            connection.cancel()
        })
    }

    private func sendOpenAIErrorResponse(status: Int, message: String, on connection: NWConnection, requestID: String) {
        // FIX: Strip newlines from message to prevent HTTP header injection.
        let safeMessage = message
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: " ")
        let errorType = openAIErrorType(for: status)
        let body: [String: Any] = [
            "error": [
                "message": safeMessage,
                "type": errorType,
                "code": "\(status)"
            ]
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: body) else {
            connection.cancel()
            return
        }

        let httpResponse = """
        HTTP/1.1 \(status) \(safeMessage)\r
        Content-Type: application/json\r
        Content-Length: \(data.count)\r
        Connection: close\r
        \r
        """

        var fullResponse = httpResponse.data(using: .utf8)!
        fullResponse.append(data)

        connection.send(content: fullResponse, completion: .contentProcessed { [weak self] _ in
            self?.logResponse(status: status, message: message, on: connection, requestID: requestID)
            connection.cancel()
        })
    }

    private func remoteAddress(for connection: NWConnection) -> String {
        if case .hostPort(let host, let port) = connection.endpoint {
            return "\(host):\(port)"
        }
        return "unknown"
    }

    private func logResponse(status: Int, message: String, on connection: NWConnection, requestID: String?) {
        log(category: .app, level: status >= 400 ? .error : .info, title: "HTTP \(status)", message: message, metadata: ["remote": remoteAddress(for: connection), "request_id": requestID ?? ""])
    }

    private func log(category: AppLogCategory, level: AppLogLevel = .info, title: String, message: String, requestID: String? = nil, metadata: [String: String] = [:]) {
        let timestamp = Self.iso8601Formatter.string(from: Date())
        var logLine = "[\(timestamp)] [Server] [\(level.rawValue.uppercased())] \(title): \(message)"
        if let requestID = requestID {
            logLine += " (Request: \(requestID))"
        }
        if !metadata.isEmpty {
            logLine += " \(metadata)"
        }
        print(logLine)

        Task { @MainActor in
            AppLogStore.shared.record(category, level: level, title: title, message: message, metadata: metadata)
        }
    }

    private func openAIErrorType(for status: Int) -> String {
        switch status {
        case 401: return "authentication_error"
        case 400, 403, 404: return "invalid_request_error"
        case 501: return "not_implemented_error"
        default: return "server_error"
        }
    }

    /// Reads the server exposure mode directly from UserDefaults to avoid @MainActor isolation.
    /// This is safe because the value is a simple string stored in UserDefaults.
    private static func readServerExposureModeRaw() -> String {
        UserDefaults.standard.string(forKey: "server_exposure_mode") ?? "localOnly"
    }
}
