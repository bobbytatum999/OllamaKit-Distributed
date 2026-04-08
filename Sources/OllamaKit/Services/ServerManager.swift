import Foundation
import Network
import OllamaCore

final class ServerManager {
    static let shared = ServerManager()
    private static let iso8601Formatter = ISO8601DateFormatter()
    private static let iso8601FormatterLock = NSLock()

    private let queue = DispatchQueue(label: "com.ollamakit.server", qos: .userInitiated)
    private let stateLock = NSLock()
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var isRunning = false
    private var isStarting = false
    private var startupContinuation: CheckedContinuation<Void, Never>?

    private init() {}

    private func log(
        _ category: ServerLogCategory,
        level: ServerLogLevel = .info,
        title: String,
        message: String,
        requestID: String? = nil,
        body: String? = nil,
        metadata: [String: String] = [:]
    ) {
        let entry = ServerLogEntry(
            level: level,
            category: category,
            title: title,
            message: message,
            requestID: requestID,
            body: body.map { Self.redactedLogText($0) },
            metadata: metadata
        )

        Task { @MainActor in
            ServerLogStore.shared.record(entry)
        }
    }

    private func logResponse(
        status: Int,
        body: String?,
        context: ServerRequestContext?,
        responseKind: String
    ) {
        var metadata = context.map { [
            "method": $0.method,
            "path": $0.path,
            "remote": $0.remoteAddress,
            "latency_ms": String($0.durationMilliseconds),
            "response_kind": responseKind
        ] } ?? [:]
        metadata["status"] = String(status)
        if let body {
            metadata["body_bytes"] = String(body.lengthOfBytes(using: .utf8))
        }

        log(
            .response,
            level: status >= 400 ? .error : .info,
            title: "HTTP \(status)",
            message: "Responded with \(HTTPStatusText(status)).",
            requestID: context?.requestID,
            body: body,
            metadata: metadata
        )
    }

    fileprivate static func redactedLogText(_ value: String) -> String {
        var redacted = value
        redacted = redacted.replacingOccurrences(
            of: #"(?im)^(Authorization:\s*Bearer)\s+.+$"#,
            with: "$1 [REDACTED]",
            options: .regularExpression
        )
        redacted = redacted.replacingOccurrences(
            of: #"(?i)"(api[_-]?key|authorization)"\s*:\s*"[^"]+""#,
            with: #""$1":"[REDACTED]""#,
            options: .regularExpression
        )

        let currentAPIKey = AppSettings.shared.apiKey.trimmedForLookup
        if !currentAPIKey.isEmpty {
            redacted = redacted.replacingOccurrences(of: currentAPIKey, with: "[REDACTED]")
        }

        return redacted
    }

    func startServerIfEnabled() async {
        guard AppSettings.shared.serverEnabled else { return }
        await startServer()
    }

    func startServer() async {
        let canStart = stateLock.withLock { () -> Bool in
            let canStart = !isRunning && !isStarting && listener == nil
            if canStart {
                isStarting = true
            }
            return canStart
        }
        guard canStart else { return }

        let configuredPort = AppSettings.shared.serverPort
        guard (1024...Int(UInt16.max)).contains(configuredPort),
              let port = NWEndpoint.Port(rawValue: UInt16(configuredPort))
        else {
            stateLock.withLock {
                isStarting = false
            }
            log(.listener, level: .error, title: "Server Startup Failed", message: "Invalid port: \(configuredPort)")
            return
        }

        switch AppSettings.shared.serverExposureMode {
        case .publicCustom where AppSettings.shared.normalizedPublicBaseURL == nil:
            stateLock.withLock {
                isStarting = false
            }
            log(.listener, level: .error, title: "Server Startup Failed", message: "Custom Public URL mode requires a valid external HTTP or HTTPS URL.")
            return
        case .publicManaged where AppSettings.shared.normalizedManagedRelayBaseURL == nil:
            stateLock.withLock {
                isStarting = false
            }
            log(.listener, level: .error, title: "Server Startup Failed", message: "Managed Public URL mode requires a valid relay service URL.")
            return
        default:
            break
        }

        log(
            .listener,
            level: .info,
            title: "Server Startup Initiated",
            message: "Starting API listener.",
            metadata: [
                "port": String(configuredPort),
                "exposure": AppSettings.shared.serverExposureMode.rawValue
            ]
        )

        do {
            let newListener = try NWListener(using: .tcp, on: port)
            let startupGate = ContinuationGate()

            newListener.stateUpdateHandler = { [weak self] state in
                self?.handleListenerState(state, port: port)

                switch state {
                case .ready, .failed, .cancelled:
                    guard let self else { return }
                    let continuation = self.stateLock.withLock { () -> CheckedContinuation<Void, Never>? in
                        let continuation = self.startupContinuation
                        self.startupContinuation = nil
                        return continuation
                    }
                    if let continuation {
                        startupGate.resumeIfNeeded(continuation)
                    }
                default:
                    break
                }
            }
            newListener.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }

            stateLock.withLock {
                listener = newListener
            }
            await withCheckedContinuation { continuation in
                stateLock.withLock {
                    startupContinuation = continuation
                }
                newListener.start(queue: queue)
            }
        } catch {
            stateLock.withLock {
                isStarting = false
            }
            log(.listener, level: .error, title: "Server Startup Failed", message: error.localizedDescription)
        }
    }

    func stopServer() async {
        let state = stateLock.withLock { () -> (NWListener?, [NWConnection], CheckedContinuation<Void, Never>?) in
            let currentListener = listener
            listener = nil
            let activeConnections = Array(connections.values)
            connections.removeAll()
            isRunning = false
            isStarting = false
            let continuation = startupContinuation
            startupContinuation = nil
            return (currentListener, activeConnections, continuation)
        }

        state.0?.cancel()

        for connection in state.1 {
            connection.cancel()
        }

        state.2?.resume()
        log(.listener, level: .info, title: "Server Stopped", message: "The API listener was stopped.")
    }

    func restartServerIfRunning() async {
        guard isServerRunning else { return }
        await stopServer()
        await startServer()
    }

    var serverURL: String {
        AppSettings.shared.serverURL
    }

    var isServerRunning: Bool {
        stateLock.withLock { isRunning }
    }

    private func handleListenerState(_ state: NWListener.State, port: NWEndpoint.Port) {
        switch state {
        case .ready:
            stateLock.withLock {
                isRunning = true
                isStarting = false
            }
            log(                .listener,
                level: .info,
                title: "Server Started",
                message: "Server listening on port \(port.rawValue).",
                metadata: [
                    "port": String(port.rawValue),
                    "exposure": AppSettings.shared.serverExposureMode.rawValue,
                    "url": AppSettings.shared.serverURL
                ]
            )
        case .failed(let error):
            stateLock.withLock {
                isRunning = false
                isStarting = false
                listener = nil
            }
            log(.listener, level: .error, title: "Server Startup Failed", message: error.localizedDescription)
        case .cancelled:
            stateLock.withLock {
                isRunning = false
                isStarting = false
                listener = nil
            }
            log(.listener, title: "Listener Cancelled", message: "The server listener was cancelled.")
        default:
            break
        }
    }

    private func handleConnection(_ connection: NWConnection) {
        let remoteAddress = remoteAddress(for: connection)

        stateLock.withLock {
            connections[ObjectIdentifier(connection)] = connection
        }

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .cancelled:
                self.stateLock.withLock {
                    _ = self.connections.removeValue(forKey: ObjectIdentifier(connection))
                }
                self.log(.connection, level: .info, title: "Client Disconnected", message: "Connection closed.", metadata: ["remote": remoteAddress])
            case .failed(let error):
                self.stateLock.withLock {
                    _ = self.connections.removeValue(forKey: ObjectIdentifier(connection))
                }
                self.log(.connection, level: .error, title: "Connection Error", message: error.localizedDescription, metadata: ["remote": remoteAddress, "error": error.localizedDescription])
            default:
                break
            }
        }

        connection.start(queue: queue)

        log(.connection, level: .info, title: "Client Connected", message: "Accepted inbound connection.", metadata: ["remote": remoteAddress])

        guard allowsConnection(connection) else {
            sendErrorResponse(
                status: 403,
                message: AppSettings.shared.serverExposureMode == .localOnly
                    ? "This server is in Local Only mode. Switch to Local Network, Managed Public URL, or Custom Public URL mode to accept non-local requests."
                    : "This connection is not allowed for the current server exposure mode.",
                on: connection
            )
            log(
                .connection,
                level: .warning,
                title: "Connection Rejected",
                message: "Rejected connection due to exposure mode policy.",
                metadata: [
                    "remote": remoteAddress,
                    "exposure_mode": AppSettings.shared.serverExposureMode.rawValue
                ]
            )
            return
        }

        receiveHTTPRequest(on: connection)
    }

    private func allowsConnection(_ connection: NWConnection) -> Bool {
        switch AppSettings.shared.serverExposureMode {
        case .localOnly:
            break
        case .localNetwork, .publicManaged, .publicCustom:
            return true
        }

        let endpoint = connection.currentPath?.remoteEndpoint ?? connection.endpoint

        switch endpoint {
        case .hostPort(let host, _):
            return isLoopback(host)
        case .service(name: _, type: _, domain: _, interface: _), .unix(path: _), .url(_), .opaque(_):
            return false
        @unknown default:
            return false
        }
    }

    private func isLoopback(_ host: NWEndpoint.Host) -> Bool {
        switch host {
        case .ipv4(let address):
            return address.debugDescription == "127.0.0.1"
        case .ipv6(let address):
            let rendered = address.debugDescription.lowercased()
            return rendered == "::1" || rendered == "0:0:0:0:0:0:0:1"
        case .name(let name, _):
            let lowered = name.lowercased()
            return lowered == "localhost" || lowered == "127.0.0.1"
        @unknown default:
            return false
        }
    }

    private func receiveHTTPRequest(on connection: NWConnection) {
        receiveHTTPRequest(on: connection, buffer: Data())
    }

    private func receiveHTTPRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }

            if let error {
                self.log(.connection, level: .warning, title: "Receive Failed", message: error.localizedDescription, metadata: ["remote": self.remoteAddress(for: connection)])
                connection.cancel()
                return
            }

            var accumulated = buffer
            if let data, !data.isEmpty {
                accumulated.append(data)
            }

            if let requestLength = self.requestLengthIfComplete(in: accumulated) {
                let requestData = accumulated.prefix(requestLength)

                guard let request = String(data: requestData, encoding: .utf8) else {
                    self.sendErrorResponse(status: 400, message: "Bad Request", on: connection)
                    return
                }

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
        let rawPath = parts[1]
        let path = rawPath.components(separatedBy: "?").first ?? rawPath
        let headers = parseHeaders(from: lines)
        let context = ServerRequestContext(
            requestID: UUID().uuidString.lowercased(),
            method: method,
            path: path,
            rawPath: rawPath,
            remoteAddress: remoteAddress(for: connection),
            headers: headers,
            rawRequest: request,
            startedAt: .now
        )

        log(
            .request,
            title: "Incoming Request",
            message: "\(method) \(path)",
            requestID: context.requestID,
            body: context.redactedRequestBody,
            metadata: [
                "remote": context.remoteAddress,
                "path": path
            ]
        )

        if method == "OPTIONS" {
            sendCORSPreflightResponse(on: connection, context: context)
            return
        }

        if AppSettings.shared.isAPIKeyRequiredForCurrentExposure {
            let authHeader = headers.first { $0.key.caseInsensitiveCompare("Authorization") == .orderedSame }?.value
            guard authHeader == "Bearer \(AppSettings.shared.apiKey)" else {
                log(
                    .auth,
                    level: .warning,
                    title: "Authentication Failed",
                    message: "Rejected request without a valid API key.",
                    requestID: context.requestID,
                    metadata: [
                        "path": path,
                        "remote": context.remoteAddress
                    ]
                )
                if path.hasPrefix("/v1/") {
                    sendOpenAIErrorResponse(status: 401, message: "Unauthorized", type: "authentication_error", on: connection, context: context)
                } else {
                    sendErrorResponse(status: 401, message: "Unauthorized", on: connection, context: context)
                }
                return
            }

            log(
                .auth,
                title: "Authentication Succeeded",
                message: "Accepted authenticated request.",
                requestID: context.requestID,
                metadata: [
                    "path": path,
                    "remote": context.remoteAddress
                ]
            )
        }

        log(
            .routing,
            title: "Dispatching Route",
            message: "\(method) \(path)",
            requestID: context.requestID,
            metadata: [
                "remote": context.remoteAddress,
                "route": path,
                "method": method
            ]
        )

        switch (method, path) {
        case ("GET", "/api/tags"):
            handleLegacyListModels(on: connection, context: context)
        case ("POST", "/api/show"):
            handleLegacyShow(request: request, on: connection, context: context)
        case ("POST", "/api/generate"):
            handleLegacyGenerate(request: request, on: connection, context: context)
        case ("POST", "/api/chat"):
            handleLegacyChat(request: request, on: connection, context: context)
        case ("POST", "/api/pull"):
            handlePull(request: request, on: connection, context: context)
        case ("DELETE", "/api/delete"):
            handleDelete(request: request, on: connection, context: context)
        case ("POST", "/api/embed"):
            handleLegacyEmbeddings(request: request, on: connection, context: context)
        case ("GET", "/api/ps"):
            handleRunningModels(on: connection, context: context)
        case ("GET", "/v1/models"):
            handleOpenAIListModels(on: connection, context: context)
        case ("POST", "/v1/completions"):
            handleOpenAICompletion(request: request, on: connection, context: context)
        case ("POST", "/v1/chat/completions"):
            handleOpenAIChatCompletion(request: request, on: connection, context: context)
        case ("POST", "/v1/embeddings"):
            handleOpenAIEmbeddings(request: request, on: connection, context: context)
        case ("POST", "/v1/responses"):
            handleOpenAIResponses(request: request, on: connection, context: context)
        case ("GET", "/"):
            sendJSONResponse(
                status: 200,
                body: [
                    "status": "OllamaKit Server Running",
                    "ollama_compatible": true,
                    "openai_compatible_routes": ["/v1/models", "/v1/completions", "/v1/chat/completions", "/v1/responses"],
                    "canonical_url": AppSettings.shared.serverURL,
                    "exposure_mode": AppSettings.shared.serverExposureMode.rawValue,
                    "build_variant": AppSettings.shared.buildVariant.rawValue
                ],
                on: connection,
                context: context
            )
        default:
            if path.hasPrefix("/v1/") {
                sendOpenAIErrorResponse(status: 404, message: "Not Found", type: "invalid_request_error", on: connection, context: context)
            } else {
                sendErrorResponse(status: 404, message: "Not Found", on: connection, context: context)
            }
        }

    func handleLegacyListModels(on connection: NWConnection, context: ServerRequestContext) {
        Task {
            let models = await serverModels()
            let body: [String: Any] = [
                "models": models.map { legacyModelMetadata(for: $0) }
            ]

            sendJSONResponse(status: 200, body: body, on: connection, context: context)
        }
    }

    func handleOpenAIListModels(on connection: NWConnection, context: ServerRequestContext) {
        Task {
            let models = await serverModels()
            let createdAt = Int(Date().timeIntervalSince1970)
            let body: [String: Any] = [
                "object": "list",
                "data": models.map { openAIModelMetadata(for: $0, createdAt: createdAt) }
            ]

            sendJSONResponse(status: 200, body: body, on: connection, context: context)
        }
    }

    func handleLegacyShow(request: String, on connection: NWConnection, context: ServerRequestContext) {
        guard
            let json = decodeJSONObject(from: request),
            let modelName = (json["name"] as? String)?.trimmedForLookup.nonEmpty
        else {
            sendErrorResponse(status: 400, message: "Invalid request", on: connection, context: context)
            return
        }

        Task {
            guard let snapshot = await resolvedServerModel(named: modelName) else {
                sendErrorResponse(status: 404, message: "Model not found", on: connection, context: context)
                return
            }

            let body: [String: Any] = [
                "name": legacyModelName(for: snapshot),
                "model": legacyModelName(for: snapshot),
                "backend": snapshot.backendKind.rawValue,
                "size": snapshot.size,
                "modified_at": iso8601String(from: snapshot.downloadDate),
                "validation": validationPayload(for: snapshot),
                "capabilities": capabilityPayload(for: snapshot),
                "supported_routes": snapshot.effectiveServerCapabilities.supportedRoutes.map(\.rawValue),
                "details": [
                    "parameter_size": snapshot.parameters,
                    "quantization_level": snapshot.quantization,
                    "context_length": snapshot.contextLength
                ]
            ]

            sendJSONResponse(status: 200, body: body, on: connection, context: context)
        }
    }

    func handleLegacyGenerate(request: String, on connection: NWConnection, context: ServerRequestContext) {
        guard
            let json = decodeJSONObject(from: request),
            let modelName = json["model"] as? String
        else {
            sendErrorResponse(status: 400, message: "Invalid request", on: connection, context: context)
            return
        }

        let payload = ParsedInferencePayload(
            prompt: extractStringContent(from: json["prompt"]) ?? "",
            systemPrompt: extractStringContent(from: json["system"]),
            conversationTurns: [],
            tools: parseTools(from: json),
            reasoning: parseReasoning(from: json),
            stream: json["stream"] as? Bool ?? true
        )

        Task {
            do {
                let model = try await prepareModel(
                    named: modelName,
                    requiredRoute: .apiGenerate,
                    payload: payload,
                    context: context
                )
                let parameters = modelParameters(from: json, apiStyle: .ollama)

                if payload.stream {
                    await streamLegacyGenerate(
                        prompt: payload.prompt,
                        systemPrompt: payload.systemPrompt,
                        model: legacyModelName(for: model),
                        parameters: parameters,
                        on: connection,
                        context: context
                    )
                } else {
                    await completeLegacyGenerate(
                        prompt: payload.prompt,
                        systemPrompt: payload.systemPrompt,
                        model: legacyModelName(for: model),
                        parameters: parameters,
                        on: connection,
                        context: context
                    )
                }
            } catch {
                sendErrorResponse(status: httpStatus(for: error), message: error.localizedDescription, on: connection, context: context)
            }
        }
    }

    func handleLegacyChat(request: String, on connection: NWConnection, context: ServerRequestContext) {
        guard
            let json = decodeJSONObject(from: request),
            let messages = json["messages"] as? [[String: Any]],
            let modelName = json["model"] as? String
        else {
            sendErrorResponse(status: 400, message: "Invalid request", on: connection, context: context)
            return
        }

        let payload = parseChatPayload(messages: messages, json: json, defaultStream: true)

        Task {
            do {
                let model = try await prepareModel(
                    named: modelName,
                    requiredRoute: .apiChat,
                    payload: payload,
                    context: context
                )
                let parameters = modelParameters(from: json, apiStyle: .ollama)

                if payload.stream {
                    await streamLegacyChat(
                        conversationTurns: payload.conversationTurns,
                        systemPrompt: payload.systemPrompt,
                        model: legacyModelName(for: model),
                        parameters: parameters,
                        on: connection,
                        context: context
                    )
                } else {
                    await completeLegacyChat(
                        conversationTurns: payload.conversationTurns,
                        systemPrompt: payload.systemPrompt,
                        model: legacyModelName(for: model),
                        parameters: parameters,
                        on: connection,
                        context: context
                    )
                }
            } catch {
                sendErrorResponse(status: httpStatus(for: error), message: error.localizedDescription, on: connection, context: context)
            }
        }
    }

    func handleOpenAICompletion(request: String, on connection: NWConnection, context: ServerRequestContext) {
        guard
            let json = decodeJSONObject(from: request),
            let modelName = json["model"] as? String
        else {
            sendOpenAIErrorResponse(status: 400, message: "Invalid request", on: connection, context: context)
            return
        }

        let prompt: String
        if let promptString = extractStringContent(from: json["prompt"]) {
            prompt = promptString
        } else if let prompts = json["prompt"] as? [String] {
            prompt = prompts.joined(separator: "\n\n")
        } else {
            prompt = ""
        }

        let payload = ParsedInferencePayload(
            prompt: prompt,
            systemPrompt: extractStringContent(from: json["system"]),
            conversationTurns: [],
            tools: parseTools(from: json),
            reasoning: parseReasoning(from: json),
            stream: json["stream"] as? Bool ?? false
        )

        Task {
            do {
                let model = try await prepareModel(
                    named: modelName,
                    requiredRoute: .v1Completions,
                    payload: payload,
                    context: context
                )
                let parameters = modelParameters(from: json, apiStyle: .openAI)
                let requestId = "cmpl-\(UUID().uuidString.lowercased())"
                let createdAt = Int(Date().timeIntervalSince1970)
                let responseModel = openAIModelIdentifier(for: model)

                if payload.stream {
                    await streamOpenAICompletion(
                        requestId: requestId,
                        createdAt: createdAt,
                        model: responseModel,
                        prompt: payload.prompt,
                        parameters: parameters,
                        on: connection,
                        context: context
                    )
                } else {
                    await completeOpenAICompletion(
                        requestId: requestId,
                        createdAt: createdAt,
                        model: responseModel,
                        prompt: payload.prompt,
                        parameters: parameters,
                        on: connection,
                        context: context
                    )
                }
            } catch {
                let status = httpStatus(for: error)
                sendOpenAIErrorResponse(status: status, message: error.localizedDescription, type: openAIErrorType(for: status), on: connection, context: context)
            }
        }
    }

    func handleOpenAIChatCompletion(request: String, on connection: NWConnection, context: ServerRequestContext) {
        guard
            let json = decodeJSONObject(from: request),
            let messages = json["messages"] as? [[String: Any]],
            let modelName = json["model"] as? String
        else {
            sendOpenAIErrorResponse(status: 400, message: "Invalid request", on: connection, context: context)
            return
        }

        let payload = parseChatPayload(messages: messages, json: json, defaultStream: false)

        Task {
            do {
                let model = try await prepareModel(
                    named: modelName,
                    requiredRoute: .v1ChatCompletions,
                    payload: payload,
                    context: context
                )
                let parameters = modelParameters(from: json, apiStyle: .openAI)
                let requestId = "chatcmpl-\(UUID().uuidString.lowercased())"
                let createdAt = Int(Date().timeIntervalSince1970)
                let responseModel = openAIModelIdentifier(for: model)

                if payload.stream {
                    await streamOpenAIChatCompletion(
                        requestId: requestId,
                        createdAt: createdAt,
                        model: responseModel,
                        conversationTurns: payload.conversationTurns,
                        systemPrompt: payload.systemPrompt,
                        parameters: parameters,
                        on: connection,
                        context: context
                    )
                } else {
                    await completeOpenAIChatCompletion(
                        requestId: requestId,
                        createdAt: createdAt,
                        model: responseModel,
                        conversationTurns: payload.conversationTurns,
                        systemPrompt: payload.systemPrompt,
                        parameters: parameters,
                        on: connection,
                        context: context
                    )
                }
            } catch {
                let status = httpStatus(for: error)
                sendOpenAIErrorResponse(status: status, message: error.localizedDescription, type: openAIErrorType(for: status), on: connection, context: context)
            }
        }
    }

    func handleLegacyEmbeddings(request: String, on connection: NWConnection, context: ServerRequestContext) {
        guard
            let json = decodeJSONObject(from: request),
            let modelName = json["model"] as? String
        else {
            sendErrorResponse(status: 400, message: "Invalid request", on: connection, context: context)
            return
        }

        Task {
            do {
                let payload = ParsedInferencePayload(
                    prompt: "",
                    systemPrompt: nil,
                    conversationTurns: [],
                    tools: [],
                    reasoning: nil,
                    stream: false
                )
                _ = try await prepareModel(
                    named: modelName,
                    requiredRoute: .apiEmbed,
                    payload: payload,
                    context: context
                )
                sendErrorResponse(
                    status: 501,
                    message: "Embeddings are not implemented in this build for this model yet.",
                    on: connection,
                    context: context
                )
            } catch {
                sendErrorResponse(status: httpStatus(for: error), message: error.localizedDescription, on: connection, context: context)
            }
        }
    }

    func handleOpenAIEmbeddings(request: String, on connection: NWConnection, context: ServerRequestContext) {
        guard
            let json = decodeJSONObject(from: request),
            let modelName = json["model"] as? String
        else {
            sendOpenAIErrorResponse(status: 400, message: "Invalid request", on: connection, context: context)
            return
        }

        Task {
            do {
                let payload = ParsedInferencePayload(
                    prompt: "",
                    systemPrompt: nil,
                    conversationTurns: [],
                    tools: [],
                    reasoning: nil,
                    stream: false
                )
                _ = try await prepareModel(
                    named: modelName,
                    requiredRoute: .v1Embeddings,
                    payload: payload,
                    context: context
                )
                sendOpenAIErrorResponse(
                    status: 501,
                    message: "Embeddings are not implemented in this build for this model yet.",
                    type: "not_implemented_error",
                    on: connection,
                    context: context
                )
            } catch {
                let status = httpStatus(for: error)
                sendOpenAIErrorResponse(status: status, message: error.localizedDescription, type: openAIErrorType(for: status), on: connection, context: context)
            }
        }
    }

    func handleOpenAIResponses(request: String, on connection: NWConnection, context: ServerRequestContext) {
        guard
            let json = decodeJSONObject(from: request),
            let modelName = json["model"] as? String
        else {
            sendOpenAIErrorResponse(status: 400, message: "Invalid request", on: connection, context: context)
            return
        }

        let payload = parseResponsesPayload(from: json)

        Task {
            do {
                let model = try await prepareModel(
                    named: modelName,
                    requiredRoute: .v1Responses,
                    payload: payload,
                    context: context
                )
                let parameters = modelParameters(from: json, apiStyle: .openAI)
                let requestId = "resp-\(UUID().uuidString.lowercased())"
                let createdAt = Int(Date().timeIntervalSince1970)
                let responseModel = openAIModelIdentifier(for: model)

                if payload.stream {
                    await streamOpenAIResponses(
                        requestId: requestId,
                        createdAt: createdAt,
                        model: responseModel,
                        payload: payload,
                        parameters: parameters,
                        on: connection,
                        context: context
                    )
                } else {
                    await completeOpenAIResponses(
                        requestId: requestId,
                        createdAt: createdAt,
                        model: responseModel,
                        payload: payload,
                        parameters: parameters,
                        on: connection,
                        context: context
                    )
                }
            } catch {
                let status = httpStatus(for: error)
                sendOpenAIErrorResponse(status: status, message: error.localizedDescription, type: openAIErrorType(for: status), on: connection, context: context)
            }
        }
    }

    func handlePull(request: String, on connection: NWConnection, context: ServerRequestContext) {
        guard let json = decodeJSONObject(from: request) else {
            sendErrorResponse(status: 400, message: "Invalid request", on: connection, context: context)
            return
        }

        let requestedName = (json["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let requestedFilename = (json["file"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? (json["filename"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let stream = json["stream"] as? Bool ?? true

        guard !requestedName.isEmpty else {
            sendPullError(stream: stream, status: 400, message: "Missing model name", on: connection, context: context)
            return
        }

        Task {
            log(
                .model,
                title: "Pull Requested",
                message: "Starting model pull request.",
                requestID: context.requestID,
                metadata: [
                    "requested_model": requestedName,
                    "requested_file": requestedFilename ?? "",
                    "stream": String(stream)
                ]
            )

            if stream {
                sendStreamHeaders(contentType: "application/x-ndjson", on: connection, context: context)
                sendNDJSONChunk(
                    data: [
                        "status": "pulling",
                        "model": requestedName,
                        "done": false
                    ],
                    on: connection,
                    closeAfterSend: false,
                    context: context
                )
            }

            do {
                let runtimeProfile = await DeviceCapabilityService.shared.currentRuntimeProfile()
                let candidate = try await HuggingFaceService.shared.resolvePullCandidate(
                    requestedName: requestedName,
                    requestedFilename: requestedFilename,
                    runtimeProfile: runtimeProfile
                )
                let modelId = candidate.model.modelId
                let file = candidate.file

                log(
                    .model,
                    title: "Pull Candidate Resolved",
                    message: "Resolved a downloadable model candidate.",
                    requestID: context.requestID,
                    metadata: [
                        "model_id": modelId,
                        "file": file.filename,
                        "url": file.url.absoluteString
                    ]
                )

                let downloadedModel = try await HuggingFaceService.shared.downloadModel(
                    from: file.url,
                    filename: file.filename,
                    modelId: modelId
                ) { progress in
                    guard progress.downloadedBytes > 0 || progress.totalBytes > 0 else { return }

                    if stream {
                        self.sendNDJSONChunk(
                            data: [
                                "status": "downloading",
                                "model": requestedName,
                                "completed": progress.downloadedBytes,
                                "total": progress.totalBytes,
                                "progress": progress.progress,
                                "done": false
                            ],
                            on: connection,
                            closeAfterSend: false,
                            context: context
                        )
                    }
                }

                await ModelStorage.shared.upsertDownloadedModel(
                    DownloadedModelSeed(
                        modelId: downloadedModel.registrySeed.modelId,
                        name: downloadedModel.registrySeed.name,
                        localPath: downloadedModel.registrySeed.localPath,
                        size: downloadedModel.registrySeed.size,
                        quantization: downloadedModel.registrySeed.quantization,
                        parameters: downloadedModel.registrySeed.parameters,
                        contextLength: downloadedModel.registrySeed.contextLength,
                        serverCapabilities: ServerModelCapabilities.conservativeDefaults(
                            backendKind: .ggufLlama,
                            sourceModelID: modelId,
                            displayName: downloadedModel.registrySeed.name,
                            capabilitySummary: ModelCapabilitySummary(
                                sizeBytes: downloadedModel.registrySeed.size,
                                quantization: downloadedModel.registrySeed.quantization,
                                parameterCountLabel: downloadedModel.registrySeed.parameters,
                                contextLength: downloadedModel.registrySeed.contextLength,
                                supportsStreaming: true,
                                notes: [
                                    candidate.model.pipelineTag,
                                    candidate.model.description,
                                    candidate.model.tags?.joined(separator: " ")
                                ]
                                .compactMap { note in
                                    guard let note = note?.trimmedForLookup.nonEmpty else { return nil }
                                    return note
                                }
                                .joined(separator: " ")
                                .nonEmpty
                            ),
                            hintedMultilingual: candidate.model.tags?.contains(where: {
                                $0.localizedCaseInsensitiveContains("multilingual")
                            }) ?? false
                        )
                    )
                )
                let snapshot = await ModelStorage.shared.snapshot(name: downloadedModel.apiIdentifier)

                let validationStatus = snapshot?.effectiveValidationStatus ?? .unknown
                let finalBody: [String: Any] = [
                    "status": validationStatus == .validated ? "success" : "validation_failed",
                    "model": downloadedModel.apiIdentifier,
                    "file": file.filename,
                    "size": downloadedModel.size,
                    "completed": downloadedModel.size,
                    "validation_status": validationStatus.rawValue,
                    "validation_message": snapshot?.validationSummary ?? "",
                    "done": true
                ]

                log(
                    .model,
                    level: validationStatus == .validated ? .info : .warning,
                    title: "Pull Completed",
                    message: validationStatus == .validated
                        ? "Downloaded model validated successfully."
                        : "Downloaded model finished, but validation did not pass.",
                    requestID: context.requestID,
                    metadata: [
                        "model": downloadedModel.apiIdentifier,
                        "file": file.filename,
                        "validation_status": validationStatus.rawValue
                    ]
                )

                if stream {
                    sendNDJSONChunk(data: finalBody, on: connection, closeAfterSend: true, context: context)
                } else {
                    sendJSONResponse(status: 200, body: finalBody, on: connection, context: context)
                }
            } catch {
                log(
                    .error,
                    level: .error,
                    title: "Pull Failed",
                    message: error.localizedDescription,
                    requestID: context.requestID,
                    metadata: [
                        "requested_model": requestedName,
                        "requested_file": requestedFilename ?? ""
                    ]
                )
                if stream {
                    sendNDJSONChunk(
                        data: [
                            "error": error.localizedDescription,
                            "done": true
                        ],
                        on: connection,
                        closeAfterSend: true,
                        context: context
                    )
                } else {
                    sendErrorResponse(status: httpStatus(for: error), message: error.localizedDescription, on: connection, context: context)
                }
            }
        }
    }

    func handleDelete(request: String, on connection: NWConnection, context: ServerRequestContext) {
        guard
            let json = decodeJSONObject(from: request),
            let modelName = json["name"] as? String
        else {
            sendErrorResponse(status: 400, message: "Invalid request", on: connection, context: context)
            return
        }

        Task {
            let didDelete = await ModelStorage.shared.deleteModel(name: modelName)

            if didDelete {
                log(.model, title: "Model Deleted", message: "Deleted installed model.", requestID: context.requestID, metadata: ["model": modelName])
                sendJSONResponse(status: 200, body: [:], on: connection, context: context)
            } else {
                log(.model, level: .warning, title: "Delete Failed", message: "Model not found for deletion.", requestID: context.requestID, metadata: ["model": modelName])
                sendErrorResponse(status: 404, message: "Model not found", on: connection, context: context)
            }
        }
    }

    func handleRunningModels(on connection: NWConnection, context: ServerRequestContext) {
        Task {
            let models: [[String: Any]]

            if ModelRunner.shared.isLoaded, let activeCatalogId = ModelRunner.shared.activeCatalogId {
                let snapshot = await serverModel(named: activeCatalogId)
                let expiresAt: Any = AppSettings.shared.keepModelInMemory
                    ? NSNull()
                    : iso8601String(from: Date().addingTimeInterval(TimeInterval(AppSettings.shared.autoOffloadMinutes * 60)))
                let modelIdentifier = snapshot.map { legacyModelName(for: $0) } ?? activeCatalogId

                models = [[
                    "name": modelIdentifier,
                    "model": modelIdentifier,
                    "size": snapshot?.size ?? 0,
                    "size_vram": 0,
                    "expires_at": expiresAt
                ]]
            } else {
                models = []
            }

            sendJSONResponse(status: 200, body: ["models": models], on: connection, context: context)
        }
    }

    func prepareModel(
        named modelName: String,
        requiredRoute: ServerSupportedRoute,
        payload: ParsedInferencePayload,
        context: ServerRequestContext
    ) async throws -> ModelSnapshot {
        guard let model = await resolvedServerModel(named: modelName) else {
            log(.model, level: .warning, title: "Model Not Found", message: "Requested model could not be resolved.", requestID: context.requestID, metadata: ["requested_model": modelName, "route": requiredRoute.rawValue])
            throw NSError(domain: "ServerManager", code: 404, userInfo: [NSLocalizedDescriptionKey: "Model not found. Pull or import a validated model first."])
        }

        do {
            try validateCapabilities(for: model, requiredRoute: requiredRoute, payload: payload)
        } catch {
            log(.routing, level: .warning, title: "Capability Rejected", message: error.localizedDescription, requestID: context.requestID, metadata: ["model": model.displayName, "route": requiredRoute.rawValue])
            throw error
        }
        log(
            .model,
            title: "Resolved Model",
            message: "Using \(model.displayName) for \(requiredRoute.rawValue).",
            requestID: context.requestID,
            metadata: [
                "catalog_id": model.catalogId,
                "backend": model.backendKind.rawValue,
                "route": requiredRoute.rawValue
            ]
        )

        if let entry = try await RuntimeCoordinator.shared.resolveModelReference(
            model.catalogId,
            contextLength: AppSettings.shared.defaultContextLength
        ) {
            let compatibility = await DeviceCapabilityService.shared.compatibility(for: entry)
            guard compatibility.isUsable else {
                log(.model, level: .warning, title: "Device Compatibility Rejected", message: compatibility.message, requestID: context.requestID, metadata: ["model": model.displayName, "route": requiredRoute.rawValue])
                throw NSError(
                    domain: "ServerManager",
                    code: 400,
                    userInfo: [NSLocalizedDescriptionKey: compatibility.message]
                )
            }
        }

        guard model.isServerRunnable else {
            log(.model, level: .warning, title: "Model Not Runnable", message: model.validationSummary ?? "The model is not validated as runnable.", requestID: context.requestID, metadata: ["model": model.displayName, "route": requiredRoute.rawValue])
            throw NSError(
                domain: "ServerManager",
                code: 400,
                userInfo: [
                    NSLocalizedDescriptionKey: model.validationSummary
                        ?? "This model is installed, but it is not validated as runnable on this device yet."
                ]
            )
        }

        guard model.fileExists else {
            log(.model, level: .warning, title: "Model Payload Missing", message: "The installed model payload is missing from disk.", requestID: context.requestID, metadata: ["model": model.displayName, "route": requiredRoute.rawValue])
            throw NSError(domain: "ServerManager", code: 404, userInfo: [NSLocalizedDescriptionKey: "Model payload not found. Re-import or re-download the model."])
        }

        log(.model, title: "Loading Model", message: "Loading model into the runtime.", requestID: context.requestID, metadata: ["model": model.displayName, "route": requiredRoute.rawValue])
        do {
            try await ModelRunner.shared.loadModel(
                catalogId: model.catalogId,
                contextLength: model.runtimeContextLength,
                gpuLayers: AppSettings.shared.gpuLayers
            )
            log(.model, title: "Model Loaded", message: "Model loaded successfully.", requestID: context.requestID, metadata: ["model": model.displayName, "route": requiredRoute.rawValue])
        } catch {
            log(.model, level: .error, title: "Model Load Failed", message: error.localizedDescription, requestID: context.requestID, metadata: ["model": model.displayName, "route": requiredRoute.rawValue])
            throw error
        }

        return model
    }

    func serverModels() async -> [ModelSnapshot] {
        do {
            let entries = try await RuntimeCoordinator.shared.availableEntries(
                contextLength: AppSettings.shared.defaultContextLength
            )
            var snapshots: [ModelSnapshot] = []

            for entry in entries {
                let compatibility = await DeviceCapabilityService.shared.compatibility(for: entry)
                let snapshot = ModelSnapshot(entry: entry)
                if snapshot.isServerRunnable && compatibility.isUsable {
                    snapshots.append(snapshot)
                }
            }

            return snapshots
        } catch {
            log(.error, level: .error, title: "Server Model Refresh Failed", message: error.localizedDescription)
            return []
        }
    }

    func remoteAddress(for connection: NWConnection) -> String {
        let endpoint = connection.currentPath?.remoteEndpoint ?? connection.endpoint

        switch endpoint {
        case .hostPort(let host, let port):
            return "\(host):\(port)"
        case .service(let name, let type, let domain, _):
            return "\(name).\(type)\(domain)"
        case .unix(let path):
            return path
        case .url(let url):
            return url.absoluteString
        case .opaque(let data):
            return String(describing: data)
        @unknown default:
            return "unknown"
        }
    }

    func serverModel(named modelName: String) async -> ModelSnapshot? {
        guard let snapshot = await resolvedServerModel(named: modelName) else {
            return nil
        }

        return snapshot.isServerRunnable ? snapshot : nil
    }

    func resolvedServerModel(named modelName: String) async -> ModelSnapshot? {
        do {
            guard let entry = try await RuntimeCoordinator.shared.resolveModelReference(
                modelName,
                contextLength: AppSettings.shared.defaultContextLength
            ) else {
                return nil
            }

            return ModelSnapshot(entry: entry)
        } catch {
            log(.model, level: .warning, title: "Model Resolution Failed", message: error.localizedDescription, metadata: ["requested_model": modelName])
            return nil
        }
    }

    func legacyModelMetadata(for snapshot: ModelSnapshot) -> [String: Any] {
        let identifier = legacyModelName(for: snapshot)
        return [
            "name": identifier,
            "model": identifier,
            "size": snapshot.size,
            "modified_at": iso8601String(from: snapshot.downloadDate),
            "validation": validationPayload(for: snapshot),
            "capabilities": capabilityPayload(for: snapshot),
            "supported_routes": snapshot.effectiveServerCapabilities.supportedRoutes.map(\.rawValue),
            "details": [
                "parameter_size": snapshot.parameters,
                "quantization_level": snapshot.quantization,
                "context_length": snapshot.contextLength
            ]
        ]
    }

    func openAIModelMetadata(for snapshot: ModelSnapshot, createdAt: Int) -> [String: Any] {
        [
            "id": openAIModelIdentifier(for: snapshot),
            "object": "model",
            "created": createdAt,
            "owned_by": "local",
            "capabilities": capabilityPayload(for: snapshot),
            "supported_routes": snapshot.effectiveServerCapabilities.supportedRoutes.map(\.rawValue),
            "validation": validationPayload(for: snapshot)
        ]
    }

    func capabilityPayload(for snapshot: ModelSnapshot) -> [String: Any] {
        let capabilities = snapshot.effectiveServerCapabilities
        return [
            "text_generation": capabilities.textGeneration,
            "chat": capabilities.chat,
            "streaming": capabilities.streaming,
            "embeddings": capabilities.embeddings,
            "tool_calling": capabilities.toolCalling,
            "reasoning_controls": capabilities.reasoningControls,
            "image_input": capabilities.imageInput,
            "audio_input": capabilities.audioInput,
            "video_input": capabilities.videoInput,
            "multilingual": capabilities.multilingual
        ]
    }

    func validationPayload(for snapshot: ModelSnapshot) -> [String: Any] {
        [
            "status": snapshot.effectiveValidationStatus.rawValue,
            "message": snapshot.validationSummary ?? "",
            "validated_at": snapshot.validatedAt.map { iso8601String(from: $0) } ?? NSNull()
        ]
    }

    func parseChatPayload(
        messages: [[String: Any]],
        json: [String: Any],
        defaultStream: Bool
    ) -> ParsedInferencePayload {
        let systemPrompt = messages
            .filter { isInstructionRole($0["role"] as? String) }
            .compactMap { conversationText(from: $0["content"]) }
            .joined(separator: "\n\n")
            .nonEmpty

        let conversationTurns = messages.compactMap { message -> ConversationTurn? in
            guard let role = message["role"] as? String, !isInstructionRole(role) else {
                return nil
            }

            let parts = extractContentParts(from: message["content"])
            if !parts.isEmpty {
                return ConversationTurn(role: role, parts: parts)
            }

            guard let content = conversationText(from: message["content"]) else {
                return nil
            }

            return ConversationTurn(role: role, content: content)
        }

        return ParsedInferencePayload(
            prompt: "",
            systemPrompt: systemPrompt,
            conversationTurns: conversationTurns,
            tools: parseTools(from: json),
            reasoning: parseReasoning(from: json),
            stream: json["stream"] as? Bool ?? defaultStream
        )
    }

    func parseResponsesPayload(from json: [String: Any]) -> ParsedInferencePayload {
        let tools = parseTools(from: json)
        let reasoning = parseReasoning(from: json)
        let stream = json["stream"] as? Bool ?? false

        if let inputText = conversationText(from: json["input"]) {
            return ParsedInferencePayload(
                prompt: inputText,
                systemPrompt: extractStringContent(from: json["instructions"]),
                conversationTurns: [],
                tools: tools,
                reasoning: reasoning,
                stream: stream
            )
        }

        if let items = json["input"] as? [[String: Any]] {
            if items.allSatisfy({ $0["role"] != nil }) {
                return parseChatPayload(messages: items, json: json, defaultStream: stream)
            }

            let userParts = items.flatMap { extractContentParts(from: $0["content"] ?? $0) }
            return ParsedInferencePayload(
                prompt: "",
                systemPrompt: extractStringContent(from: json["instructions"]),
                conversationTurns: userParts.isEmpty ? [] : [ConversationTurn(role: "user", parts: userParts)],
                tools: tools,
                reasoning: reasoning,
                stream: stream
            )
        }

        return ParsedInferencePayload(
            prompt: "",
            systemPrompt: extractStringContent(from: json["instructions"]),
            conversationTurns: [],
            tools: tools,
            reasoning: reasoning,
            stream: stream
        )
    }

    func parseTools(from json: [String: Any]) -> [InferenceToolDefinition] {
        guard let toolObjects = json["tools"] as? [[String: Any]] else {
            return []
        }

        return toolObjects.compactMap { tool in
            if let function = tool["function"] as? [String: Any],
               let name = function["name"] as? String {
                return InferenceToolDefinition(
                    name: name,
                    description: function["description"] as? String,
                    inputSchemaJSON: serializedJSONString(from: function["parameters"])
                )
            }

            if let name = tool["name"] as? String {
                return InferenceToolDefinition(
                    name: name,
                    description: tool["description"] as? String,
                    inputSchemaJSON: serializedJSONString(from: tool["parameters"])
                )
            }

            return nil
        }
    }

    func parseReasoning(from json: [String: Any]) -> InferenceReasoningOptions? {
        if let reasoning = json["reasoning"] as? [String: Any] {
            return InferenceReasoningOptions(
                effort: reasoning["effort"] as? String,
                summary: reasoning["summary"] as? String
            )
        }

        if let effort = json["reasoning_effort"] as? String {
            return InferenceReasoningOptions(effort: effort, summary: nil)
        }

        return nil
    }

    func extractContentParts(from value: Any?) -> [ConversationContentPart] {
        if let text = value as? String {
            return text.trimmedForLookup.isEmpty ? [] : [.text(text)]
        }

        if let values = value as? [String] {
            let text = values.joined(separator: "\n").trimmedForLookup
            return text.isEmpty ? [] : [.text(text)]
        }

        if let part = value as? [String: Any] {
            return extractContentParts(from: [part])
        }

        guard let parts = value as? [[String: Any]] else {
            return []
        }

        return parts.compactMap { part in
            let partType = ((part["type"] as? String) ?? "").lowercased()
            if let text = (part["text"] as? String)?.nonEmpty ?? (part["input_text"] as? String)?.nonEmpty {
                return .text(text)
            }

            if partType == "image_url" || partType == "input_image" {
                if let image = part["image_url"] as? [String: Any] {
                    return ConversationContentPart(
                        kind: .imageURL,
                        url: image["url"] as? String,
                        detail: image["detail"] as? String
                    )
                }

                return ConversationContentPart(kind: .imageURL, url: part["image_url"] as? String)
            }

            if partType == "audio_url" || partType == "input_audio" {
                if let audio = part["audio_url"] as? [String: Any] {
                    return ConversationContentPart(
                        kind: .audioURL,
                        url: audio["url"] as? String,
                        mimeType: audio["mime_type"] as? String
                    )
                }

                return ConversationContentPart(kind: .audioURL, url: part["audio_url"] as? String)
            }

            if partType == "video_url" || partType == "input_video" {
                if let video = part["video_url"] as? [String: Any] {
                    return ConversationContentPart(
                        kind: .videoURL,
                        url: video["url"] as? String,
                        mimeType: video["mime_type"] as? String
                    )
                }

                return ConversationContentPart(kind: .videoURL, url: part["video_url"] as? String)
            }

            if partType == "file_url" || partType == "input_file" {
                if let file = part["file_url"] as? [String: Any] {
                    return ConversationContentPart(
                        kind: .fileURL,
                        url: file["url"] as? String,
                        mimeType: file["mime_type"] as? String
                    )
                }

                return ConversationContentPart(kind: .fileURL, url: part["file_url"] as? String)
            }

            return nil
        }
    }

    func conversationText(from value: Any?) -> String? {
        let text = extractContentParts(from: value)
            .compactMap(\.text)
            .joined()
            .nonEmpty

        return text ?? extractStringContent(from: value)
    }

    func serializedJSONString(from value: Any?) -> String? {
        guard let value,
              JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8)
        else {
            return nil
        }

        return string
    }

    func validateCapabilities(
        for model: ModelSnapshot,
        requiredRoute: ServerSupportedRoute,
        payload: ParsedInferencePayload
    ) throws {
        let capabilities = model.effectiveServerCapabilities
        guard capabilities.supportedRoutes.contains(requiredRoute) else {
            throw unsupportedCapabilityError(
                "The model \(model.displayName) does not support \(requiredRoute.rawValue). Supported routes: \(capabilities.supportedRoutes.map(\.rawValue).joined(separator: ", "))."
            )
        }

        if payload.stream && !capabilities.streaming {
            throw unsupportedCapabilityError("The model \(model.displayName) does not support streaming responses.")
        }

        if !payload.prompt.trimmedForLookup.isEmpty && !capabilities.textGeneration {
            throw unsupportedCapabilityError("The model \(model.displayName) does not advertise text generation support.")
        }

        if !payload.conversationTurns.isEmpty && !capabilities.chat {
            throw unsupportedCapabilityError("The model \(model.displayName) does not advertise chat-style message support.")
        }

        if !payload.tools.isEmpty && !capabilities.toolCalling {
            throw unsupportedCapabilityError("The model \(model.displayName) does not advertise tool calling support.")
        }

        if payload.reasoning != nil && !capabilities.reasoningControls {
            throw unsupportedCapabilityError("The model \(model.displayName) does not advertise reasoning controls.")
        }

        if payload.conversationTurns.contains(where: { turn in
            turn.parts?.contains(where: { $0.kind == .imageURL }) ?? false
        }) && !capabilities.imageInput {
            throw unsupportedCapabilityError("The model \(model.displayName) does not accept image inputs.")
        }

        if payload.conversationTurns.contains(where: { turn in
            turn.parts?.contains(where: { $0.kind == .audioURL }) ?? false
        }) && !capabilities.audioInput {
            throw unsupportedCapabilityError("The model \(model.displayName) does not accept audio inputs.")
        }

        if payload.conversationTurns.contains(where: { turn in
            turn.parts?.contains(where: { $0.kind == .videoURL }) ?? false
        }) && !capabilities.videoInput {
            throw unsupportedCapabilityError("The model \(model.displayName) does not accept video inputs.")
        }
    }

    func unsupportedCapabilityError(_ message: String) -> NSError {
        NSError(domain: "ServerManager", code: 400, userInfo: [NSLocalizedDescriptionKey: message])
    }

    func streamLegacyGenerate(
        prompt: String,
        systemPrompt: String?,
        model: String,
        parameters: ModelParameters,
        on connection: NWConnection,
        context: ServerRequestContext
    ) async {
        log(.generation, title: "Legacy Generate Started", message: "Streaming `/api/generate` response.", requestID: context.requestID, metadata: ["model": model])
        sendStreamHeaders(contentType: "application/x-ndjson", on: connection, context: context)

        do {
            let result = try await ModelRunner.shared.generate(prompt: prompt, systemPrompt: systemPrompt, parameters: parameters) { [self] token in
                let chunk: [String: Any] = [
                    "model": model,
                    "created_at": self.iso8601String(from: Date()),
                    "response": token,
                    "done": false
                ]
                self.log(.stream, title: "Legacy Generate Chunk", message: "Sent streamed token chunk.", requestID: context.requestID, body: token, metadata: ["model": model])
                self.sendNDJSONChunk(data: chunk, on: connection, closeAfterSend: false, context: context)
            }

            let finalChunk: [String: Any] = [
                "model": model,
                "created_at": iso8601String(from: Date()),
                "response": "",
                "done": true,
                "total_duration": Int(result.generationTime * 1_000_000_000),
                "load_duration": 0,
                "prompt_eval_count": result.promptTokens,
                "prompt_eval_duration": 0,
                "eval_count": result.tokensGenerated,
                "eval_duration": Int(result.generationTime * 1_000_000_000)
            ]

            sendNDJSONChunk(data: finalChunk, on: connection, closeAfterSend: true, context: context)
        } catch {
            let errorChunk: [String: Any] = [
                "error": error.localizedDescription,
                "done": true
            ]
            sendNDJSONChunk(data: errorChunk, on: connection, closeAfterSend: true, context: context)
        }
    }

    func completeLegacyGenerate(
        prompt: String,
        systemPrompt: String?,
        model: String,
        parameters: ModelParameters,
        on connection: NWConnection,
        context: ServerRequestContext
    ) async {
        do {
            log(.generation, title: "Legacy Generate Started", message: "Completing `/api/generate` response.", requestID: context.requestID, metadata: ["model": model])
            let result = try await ModelRunner.shared.generate(prompt: prompt, systemPrompt: systemPrompt, parameters: parameters) { _ in }

            sendJSONResponse(
                status: 200,
                body: [
                    "model": model,
                    "created_at": iso8601String(from: Date()),
                    "response": result.text,
                    "done": true,
                    "total_duration": Int(result.generationTime * 1_000_000_000),
                    "load_duration": 0,
                    "prompt_eval_count": result.promptTokens,
                    "prompt_eval_duration": 0,
                    "eval_count": result.tokensGenerated,
                    "eval_duration": Int(result.generationTime * 1_000_000_000)
                ],
                on: connection,
                context: context
            )
        } catch {
            sendErrorResponse(status: httpStatus(for: error), message: error.localizedDescription, on: connection, context: context)
        }
    }

    func streamLegacyChat(
        conversationTurns: [ConversationTurn],
        systemPrompt: String?,
        model: String,
        parameters: ModelParameters,
        on connection: NWConnection,
        context: ServerRequestContext
    ) async {
        log(.generation, title: "Legacy Chat Started", message: "Streaming `/api/chat` response.", requestID: context.requestID, metadata: ["model": model])
        sendStreamHeaders(contentType: "application/x-ndjson", on: connection, context: context)

        do {
            let result = try await ModelRunner.shared.generate(
                prompt: "",
                systemPrompt: systemPrompt,
                conversationTurns: conversationTurns,
                parameters: parameters
            ) { [self] token in
                let chunk: [String: Any] = [
                    "model": model,
                    "created_at": self.iso8601String(from: Date()),
                    "message": [
                        "role": "assistant",
                        "content": token
                    ],
                    "done": false
                ]
                self.log(.stream, title: "Legacy Chat Chunk", message: "Sent streamed chat token chunk.", requestID: context.requestID, body: token, metadata: ["model": model])
                self.sendNDJSONChunk(data: chunk, on: connection, closeAfterSend: false, context: context)
            }

            let finalChunk: [String: Any] = [
                "model": model,
                "created_at": iso8601String(from: Date()),
                "message": [
                    "role": "assistant",
                    "content": ""
                ],
                "done": true,
                "total_duration": Int(result.generationTime * 1_000_000_000),
                "load_duration": 0,
                "prompt_eval_count": result.promptTokens,
                "prompt_eval_duration": 0,
                "eval_count": result.tokensGenerated,
                "eval_duration": Int(result.generationTime * 1_000_000_000)
            ]

            sendNDJSONChunk(data: finalChunk, on: connection, closeAfterSend: true, context: context)
        } catch {
            let errorChunk: [String: Any] = [
                "error": error.localizedDescription,
                "done": true
            ]
            sendNDJSONChunk(data: errorChunk, on: connection, closeAfterSend: true, context: context)
        }
    }

    func completeLegacyChat(
        conversationTurns: [ConversationTurn],
        systemPrompt: String?,
        model: String,
        parameters: ModelParameters,
        on connection: NWConnection,
        context: ServerRequestContext
    ) async {
        do {
            log(.generation, title: "Legacy Chat Started", message: "Completing `/api/chat` response.", requestID: context.requestID, metadata: ["model": model])
            let result = try await ModelRunner.shared.generate(
                prompt: "",
                systemPrompt: systemPrompt,
                conversationTurns: conversationTurns,
                parameters: parameters
            ) { _ in }

            sendJSONResponse(
                status: 200,
                body: [
                    "model": model,
                    "created_at": iso8601String(from: Date()),
                    "message": [
                        "role": "assistant",
                        "content": result.text
                    ],
                    "done": true,
                    "total_duration": Int(result.generationTime * 1_000_000_000),
                    "load_duration": 0,
                    "prompt_eval_count": result.promptTokens,
                    "prompt_eval_duration": 0,
                    "eval_count": result.tokensGenerated,
                    "eval_duration": Int(result.generationTime * 1_000_000_000)
                ],
                on: connection,
                context: context
            )
        } catch {
            sendErrorResponse(status: httpStatus(for: error), message: error.localizedDescription, on: connection, context: context)
        }
    }

    func streamOpenAICompletion(
        requestId: String,
        createdAt: Int,
        model: String,
        prompt: String,
        parameters: ModelParameters,
        on connection: NWConnection,
        context: ServerRequestContext
    ) async {
        log(.generation, title: "OpenAI Completion Started", message: "Streaming `/v1/completions` response.", requestID: context.requestID, metadata: ["model": model])
        sendStreamHeaders(on: connection, context: context)

        do {
            _ = try await ModelRunner.shared.generate(prompt: prompt, parameters: parameters) { token in
                let chunk: [String: Any] = [
                    "id": requestId,
                    "object": "text_completion",
                    "created": createdAt,
                    "model": model,
                    "choices": [[
                        "text": token,
                        "index": 0,
                        "finish_reason": NSNull()
                    ]]
                ]
                self.log(.stream, title: "OpenAI Completion Chunk", message: "Sent streamed completion delta.", requestID: context.requestID, body: token, metadata: ["model": model])
                self.sendSSEChunk(data: chunk, on: connection, closeAfterSend: false, context: context)
            }

            let finalChunk: [String: Any] = [
                "id": requestId,
                "object": "text_completion",
                "created": createdAt,
                "model": model,
                "choices": [[
                    "text": "",
                    "index": 0,
                    "finish_reason": "stop"
                ]]
            ]
            sendSSEChunk(data: finalChunk, on: connection, closeAfterSend: false, context: context)
            sendDoneChunk(on: connection, context: context)
        } catch {
            let status = httpStatus(for: error)
            sendOpenAIStreamError(status: status, message: error.localizedDescription, type: openAIErrorType(for: status), on: connection, context: context)
        }
    }

    func completeOpenAICompletion(
        requestId: String,
        createdAt: Int,
        model: String,
        prompt: String,
        parameters: ModelParameters,
        on connection: NWConnection,
        context: ServerRequestContext
    ) async {
        do {
            log(.generation, title: "OpenAI Completion Started", message: "Completing `/v1/completions` response.", requestID: context.requestID, metadata: ["model": model])
            let result = try await ModelRunner.shared.generate(prompt: prompt, parameters: parameters) { _ in }
            sendJSONResponse(
                status: 200,
                body: [
                    "id": requestId,
                    "object": "text_completion",
                    "created": createdAt,
                    "model": model,
                    "choices": [[
                        "text": result.text,
                        "index": 0,
                        "finish_reason": "stop"
                    ]],
                    "usage": [
                        "prompt_tokens": result.promptTokens,
                        "completion_tokens": result.tokensGenerated,
                        "total_tokens": result.totalTokens
                    ]
                ],
                on: connection,
                context: context
            )
        } catch {
            let status = httpStatus(for: error)
            sendOpenAIErrorResponse(status: status, message: error.localizedDescription, type: openAIErrorType(for: status), on: connection, context: context)
        }
    }

    func streamOpenAIChatCompletion(
        requestId: String,
        createdAt: Int,
        model: String,
        conversationTurns: [ConversationTurn],
        systemPrompt: String?,
        parameters: ModelParameters,
        on connection: NWConnection,
        context: ServerRequestContext
    ) async {
        log(.generation, title: "OpenAI Chat Started", message: "Streaming `/v1/chat/completions` response.", requestID: context.requestID, metadata: ["model": model])
        sendStreamHeaders(on: connection, context: context)

        let roleChunk: [String: Any] = [
            "id": requestId,
            "object": "chat.completion.chunk",
            "created": createdAt,
            "model": model,
            "choices": [[
                "index": 0,
                "delta": ["role": "assistant"],
                "finish_reason": NSNull()
            ]]
        ]
        sendSSEChunk(data: roleChunk, on: connection, closeAfterSend: false, context: context)

        do {
            _ = try await ModelRunner.shared.generate(
                prompt: "",
                systemPrompt: systemPrompt,
                conversationTurns: conversationTurns,
                parameters: parameters
            ) { token in
                let chunk: [String: Any] = [
                    "id": requestId,
                    "object": "chat.completion.chunk",
                    "created": createdAt,
                    "model": model,
                    "choices": [[
                        "index": 0,
                        "delta": ["content": token],
                        "finish_reason": NSNull()
                    ]]
                ]
                self.log(.stream, title: "OpenAI Chat Chunk", message: "Sent streamed chat delta.", requestID: context.requestID, body: token, metadata: ["model": model])
                self.sendSSEChunk(data: chunk, on: connection, closeAfterSend: false, context: context)
            }

            let finalChunk: [String: Any] = [
                "id": requestId,
                "object": "chat.completion.chunk",
                "created": createdAt,
                "model": model,
                "choices": [[
                    "index": 0,
                    "delta": [:],
                    "finish_reason": "stop"
                ]]
            ]
            sendSSEChunk(data: finalChunk, on: connection, closeAfterSend: false, context: context)
            sendDoneChunk(on: connection, context: context)
        } catch {
            let status = httpStatus(for: error)
            sendOpenAIStreamError(status: status, message: error.localizedDescription, type: openAIErrorType(for: status), on: connection, context: context)
        }
    }

    func completeOpenAIChatCompletion(
        requestId: String,
        createdAt: Int,
        model: String,
        conversationTurns: [ConversationTurn],
        systemPrompt: String?,
        parameters: ModelParameters,
        on connection: NWConnection,
        context: ServerRequestContext
    ) async {
        do {
            log(.generation, title: "OpenAI Chat Started", message: "Completing `/v1/chat/completions` response.", requestID: context.requestID, metadata: ["model": model])
            let result = try await ModelRunner.shared.generate(
                prompt: "",
                systemPrompt: systemPrompt,
                conversationTurns: conversationTurns,
                parameters: parameters
            ) { _ in }
            sendJSONResponse(
                status: 200,
                body: [
                    "id": requestId,
                    "object": "chat.completion",
                    "created": createdAt,
                    "model": model,
                    "choices": [[
                        "index": 0,
                        "message": [
                            "role": "assistant",
                            "content": result.text
                        ],
                        "finish_reason": "stop"
                    ]],
                    "usage": [
                        "prompt_tokens": result.promptTokens,
                        "completion_tokens": result.tokensGenerated,
                        "total_tokens": result.totalTokens
                    ]
                ],
                on: connection,
                context: context
            )
        } catch {
            let status = httpStatus(for: error)
            sendOpenAIErrorResponse(status: status, message: error.localizedDescription, type: openAIErrorType(for: status), on: connection, context: context)
        }
    }

    func streamOpenAIResponses(
        requestId: String,
        createdAt: Int,
        model: String,
        payload: ParsedInferencePayload,
        parameters: ModelParameters,
        on connection: NWConnection,
        context: ServerRequestContext
    ) async {
        log(.generation, title: "OpenAI Responses Started", message: "Streaming `/v1/responses` response.", requestID: context.requestID, metadata: ["model": model])
        sendStreamHeaders(on: connection, context: context)

        let createdEvent: [String: Any] = [
            "type": "response.created",
            "response": [
                "id": requestId,
                "object": "response",
                "created": createdAt,
                "model": model
            ]
        ]
        sendSSEChunk(data: createdEvent, on: connection, closeAfterSend: false, context: context)

        do {
            _ = try await ModelRunner.shared.generate(
                prompt: payload.prompt,
                systemPrompt: payload.systemPrompt,
                conversationTurns: payload.conversationTurns,
                tools: payload.tools,
                reasoning: payload.reasoning,
                parameters: parameters
            ) { token in
                let chunk: [String: Any] = [
                    "type": "response.output_text.delta",
                    "response_id": requestId,
                    "delta": token
                ]
                self.log(.stream, title: "OpenAI Responses Chunk", message: "Sent streamed response delta.", requestID: context.requestID, body: token, metadata: ["model": model])
                self.sendSSEChunk(data: chunk, on: connection, closeAfterSend: false, context: context)
            }

            let finalChunk: [String: Any] = [
                "type": "response.completed",
                "response": [
                    "id": requestId,
                    "object": "response",
                    "created": createdAt,
                    "model": model,
                    "status": "completed"
                ]
            ]
            sendSSEChunk(data: finalChunk, on: connection, closeAfterSend: false, context: context)
            sendDoneChunk(on: connection, context: context)
        } catch {
            let status = httpStatus(for: error)
            sendOpenAIStreamError(status: status, message: error.localizedDescription, type: openAIErrorType(for: status), on: connection, context: context)
        }
    }

    func completeOpenAIResponses(
        requestId: String,
        createdAt: Int,
        model: String,
        payload: ParsedInferencePayload,
        parameters: ModelParameters,
        on connection: NWConnection,
        context: ServerRequestContext
    ) async {
        do {
            log(.generation, title: "OpenAI Responses Started", message: "Completing `/v1/responses` response.", requestID: context.requestID, metadata: ["model": model])
            let result = try await ModelRunner.shared.generate(
                prompt: payload.prompt,
                systemPrompt: payload.systemPrompt,
                conversationTurns: payload.conversationTurns,
                tools: payload.tools,
                reasoning: payload.reasoning,
                parameters: parameters
            ) { _ in }

            sendJSONResponse(
                status: 200,
                body: [
                    "id": requestId,
                    "object": "response",
                    "created": createdAt,
                    "model": model,
                    "status": "completed",
                    "output": [[
                        "type": "message",
                        "role": "assistant",
                        "content": [[
                            "type": "output_text",
                            "text": result.text
                        ]]
                    ]],
                    "output_text": result.text,
                    "usage": [
                        "input_tokens": result.promptTokens,
                        "output_tokens": result.tokensGenerated,
                        "total_tokens": result.totalTokens
                    ]
                ],
                on: connection,
                context: context
            )
        } catch {
            let status = httpStatus(for: error)
            sendOpenAIErrorResponse(status: status, message: error.localizedDescription, type: openAIErrorType(for: status), on: connection, context: context)
        }
    }

    func legacyModelName(for snapshot: ModelSnapshot) -> String {
        snapshot.apiIdentifier
    }

    func openAIModelIdentifier(for snapshot: ModelSnapshot) -> String {
        snapshot.apiIdentifier
    }

    func iso8601String(from date: Date) -> String {
        Self.iso8601FormatterLock.lock()
        defer { Self.iso8601FormatterLock.unlock() }
        return Self.iso8601Formatter.string(from: date)
    }

    func isInstructionRole(_ role: String?) -> Bool {
        guard let role else { return false }
        return role.caseInsensitiveCompare("system") == .orderedSame
            || role.caseInsensitiveCompare("developer") == .orderedSame
    }

    enum ParameterAPIStyle {
        case ollama
        case openAI
    }

    func modelParameters(from json: [String: Any], apiStyle: ParameterAPIStyle) -> ModelParameters {
        var parameters = ModelParameters.appDefault

        let parameterSource: [String: Any]
        switch apiStyle {
        case .ollama:
            parameterSource = json["options"] as? [String: Any] ?? json
        case .openAI:
            parameterSource = json
        }

        if let temperature = extractDouble(forKeys: ["temperature"], from: parameterSource) {
            parameters.temperature = temperature
        }

        if let topP = extractDouble(forKeys: ["top_p", "topP"], from: parameterSource) {
            parameters.topP = topP
        }

        if let topK = extractInt(forKeys: ["top_k", "topK"], from: parameterSource) {
            parameters.topK = topK
        }

        if let repeatPenalty = extractDouble(forKeys: ["repeat_penalty", "repeatPenalty"], from: parameterSource) {
            parameters.repeatPenalty = repeatPenalty
        }

        let maxTokenKeys: [String]
        switch apiStyle {
        case .ollama:
            maxTokenKeys = ["num_predict", "numPredict", "max_tokens", "maxTokens"]
        case .openAI:
            maxTokenKeys = ["max_tokens", "maxTokens", "max_completion_tokens", "maxCompletionTokens", "max_output_tokens", "maxOutputTokens"]
        }

        if let maxTokens = extractInt(forKeys: maxTokenKeys, from: parameterSource) {
            parameters.maxTokens = maxTokens
        }

        if let stopString = parameterSource["stop"] as? String, !stopString.isEmpty {
            parameters.stopSequences = [stopString]
        } else if let stopList = parameterSource["stop"] as? [String] {
            parameters.stopSequences = stopList.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }

        return parameters
    }

    func extractDouble(forKeys keys: [String], from json: [String: Any]) -> Double? {
        for key in keys {
            guard let value = json[key] else { continue }

            if let number = value as? NSNumber {
                return number.doubleValue
            }

            if let string = value as? String, let number = Double(string) {
                return number
            }
        }

        return nil
    }

    func extractInt(forKeys keys: [String], from json: [String: Any]) -> Int? {
        for key in keys {
            guard let value = json[key] else { continue }

            if let number = value as? NSNumber {
                return number.intValue
            }

            if let string = value as? String, let number = Int(string) {
                return number
            }
        }

        return nil
    }

    func decodeJSONObject(from request: String) -> [String: Any]? {
        guard let body = extractBody(from: request) else { return nil }
        return try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    }

    func extractStringContent(from value: Any?) -> String? {
        if let value = value as? String {
            return value
        }

        if let values = value as? [String] {
            return values.joined(separator: "\n")
        }

        if let parts = value as? [[String: Any]] {
            let text = parts.compactMap { part -> String? in
                if let text = part["text"] as? String {
                    return text
                }

                if let nestedText = part["input_text"] as? String {
                    return nestedText
                }

                return nil
            }.joined()

            return text.isEmpty ? nil : text
        }

        return nil
    }

    func sendJSONResponse(
        status: Int,
        body: [String: Any],
        on connection: NWConnection,
        context: ServerRequestContext? = nil
    ) {
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: [.fragmentsAllowed]) else {
            sendErrorResponse(status: 500, message: "Internal Server Error", on: connection, context: context)
            return
        }

        let bodyString = String(data: data, encoding: .utf8)
        logResponse(status: status, body: bodyString, context: context, responseKind: "json")

        let header = """
        HTTP/1.1 \(status) \(HTTPStatusText(status))
        Content-Type: application/json
        Content-Length: \(data.count)
        Access-Control-Allow-Origin: *
        Access-Control-Allow-Headers: Authorization, Content-Type
        Access-Control-Allow-Methods: GET, POST, DELETE, OPTIONS
        Connection: close

        
        """

        connection.send(content: header.data(using: .utf8)! + data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    func sendStreamHeaders(
        contentType: String = "text/event-stream",
        on connection: NWConnection,
        context: ServerRequestContext? = nil
    ) {
        logResponse(status: 200, body: "stream-start \(contentType)", context: context, responseKind: "stream")
        let header = """
        HTTP/1.1 200 OK
        Content-Type: \(contentType)
        Cache-Control: no-cache
        Access-Control-Allow-Origin: *
        Access-Control-Allow-Headers: Authorization, Content-Type
        Access-Control-Allow-Methods: GET, POST, DELETE, OPTIONS
        Connection: close

        
        """

        connection.send(content: header.data(using: .utf8), completion: .contentProcessed { _ in })
    }

    func sendCORSPreflightResponse(on connection: NWConnection, context: ServerRequestContext? = nil) {
        logResponse(status: 204, body: nil, context: context, responseKind: "preflight")
        let header = """
        HTTP/1.1 204 No Content
        Access-Control-Allow-Origin: *
        Access-Control-Allow-Headers: Authorization, Content-Type
        Access-Control-Allow-Methods: GET, POST, DELETE, OPTIONS
        Access-Control-Max-Age: 86400
        Content-Length: 0
        Connection: close

        
        """

        connection.send(content: header.data(using: .utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    func sendSSEChunk(
        data: [String: Any],
        on connection: NWConnection,
        closeAfterSend: Bool,
        context: ServerRequestContext? = nil
    ) {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: data),
              let jsonString = String(data: jsonData, encoding: .utf8)
        else {
            if closeAfterSend {
                connection.cancel()
            }
            return
        }

        log(.stream, title: "SSE Chunk", message: "Sent SSE chunk.", requestID: context?.requestID, body: jsonString)
        sendRawSSEChunk("data: \(jsonString)\n\n", on: connection, closeAfterSend: closeAfterSend, context: context)
    }

    func sendNDJSONChunk(
        data: [String: Any],
        on connection: NWConnection,
        closeAfterSend: Bool,
        context: ServerRequestContext? = nil
    ) {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: data),
              let jsonString = String(data: jsonData, encoding: .utf8)
        else {
            if closeAfterSend {
                connection.cancel()
            }
            return
        }

        log(.stream, title: "NDJSON Chunk", message: "Sent NDJSON chunk.", requestID: context?.requestID, body: jsonString)
        sendRawSSEChunk("\(jsonString)\n", on: connection, closeAfterSend: closeAfterSend, context: context)
    }

    func sendDoneChunk(on connection: NWConnection, context: ServerRequestContext? = nil) {
        sendRawSSEChunk("data: [DONE]\n\n", on: connection, closeAfterSend: true, context: context)
    }

    func sendOpenAIStreamError(
        status: Int,
        message: String,
        type: String = "server_error",
        code: String? = nil,
        on connection: NWConnection,
        context: ServerRequestContext? = nil
    ) {
        let _ = status
        var errorBody: [String: Any] = [
            "message": message,
            "type": type
        ]

        if let code {
            errorBody["code"] = code
        }

        sendSSEChunk(data: ["error": errorBody], on: connection, closeAfterSend: false, context: context)
        sendDoneChunk(on: connection, context: context)
    }

    func sendPullError(
        stream: Bool,
        status: Int,
        message: String,
        on connection: NWConnection,
        context: ServerRequestContext? = nil
    ) {
        if stream {
            sendStreamHeaders(contentType: "application/x-ndjson", on: connection, context: context)
            sendNDJSONChunk(
                data: [
                    "error": message,
                    "status": HTTPStatusText(status).lowercased(),
                    "done": true
                ],
                on: connection,
                closeAfterSend: true,
                context: context
            )
        } else {
            sendErrorResponse(status: status, message: message, on: connection, context: context)
        }
    }

    func sendRawSSEChunk(
        _ chunk: String,
        on connection: NWConnection,
        closeAfterSend: Bool,
        context: ServerRequestContext? = nil
    ) {
        log(.stream, title: "Raw Stream Chunk", message: "Sent raw stream payload.", requestID: context?.requestID, body: chunk)
        connection.send(content: chunk.data(using: .utf8), completion: .contentProcessed { _ in
            if closeAfterSend {
                connection.cancel()
            }
        })
    }

    func sendErrorResponse(
        status: Int,
        message: String,
        on connection: NWConnection,
        context: ServerRequestContext? = nil
    ) {
        sendJSONResponse(status: status, body: ["error": message], on: connection, context: context)
    }

    func sendOpenAIErrorResponse(
        status: Int,
        message: String,
        type: String = "invalid_request_error",
        code: String? = nil,
        on connection: NWConnection,
        context: ServerRequestContext? = nil
    ) {
        var errorBody: [String: Any] = [
            "message": message,
            "type": type
        ]

        if let code {
            errorBody["code"] = code
        }

        sendJSONResponse(status: status, body: ["error": errorBody], on: connection, context: context)
    }

    func extractBody(from request: String) -> Data? {
        requestBodyData(from: request)
    }

    func parseHeaders(from lines: [String]) -> [String: String] {
        var headers: [String: String] = [:]

        for line in lines.dropFirst() {
            if line.isEmpty { break }
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            headers[parts[0].trimmingCharacters(in: .whitespaces)] = parts[1].trimmingCharacters(in: .whitespaces)
        }

        return headers
    }

    func requestLengthIfComplete(in data: Data) -> Int? {
        guard let headerRange = data.range(of: Data("\r\n\r\n".utf8)) else {
            return nil
        }

        let headerEnd = headerRange.upperBound
        let headerData = data.prefix(headerEnd)
        let contentLength = parseContentLength(from: headerData) ?? 0
        let totalLength = headerEnd + contentLength

        guard data.count >= totalLength else {
            return nil
        }

        return totalLength
    }

    func parseContentLength(from headerData: Data) -> Int? {
        guard let headerString = String(data: headerData, encoding: .utf8) else {
            return nil
        }

        for line in headerString.components(separatedBy: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }

            if parts[0].trimmingCharacters(in: .whitespaces).caseInsensitiveCompare("Content-Length") == .orderedSame {
                return Int(parts[1].trimmingCharacters(in: .whitespaces))
            }
        }

        return nil
    }

    func HTTPStatusText(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 500: return "Internal Server Error"
        case 501: return "Not Implemented"
        default: return "Unknown"
        }
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

    func resumeIfNeeded(_ continuation: CheckedContinuation<Void, Never>) {
        let shouldResume = lock.withLock { () -> Bool in
            guard !didResume else { return false }
            didResume = true
            return true
        }

        guard shouldResume else { return }
        continuation.resume()
    }
}

extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
