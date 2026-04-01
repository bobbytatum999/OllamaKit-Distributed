import Foundation

#if canImport(AnemllCore)
@preconcurrency import AnemllCore
#endif

#if canImport(FoundationModels)
import FoundationModels
#endif

public actor RuntimeCoordinator {
    public static let shared = RuntimeCoordinator()

    private let registry = ModelRegistryStore.shared
    private let capabilityService = DeviceCapabilityService.shared
    private let ggufBackend = GGUFBackend()
    private let appleBackend: InferenceBackend = RuntimeCoordinator.makeAppleFoundationBackend()
    private let coreMLBackend = CoreMLPackageBackend()

    private var activeCatalogIdValue: String?
    private var activeBackendKind: ModelBackendKind?

    public func availableEntries(contextLength: Int = 4096) async throws -> [ModelCatalogEntry] {
        try await registry.allEntries(includeBuiltIn: true, contextLength: contextLength)
    }

    public func installedEntries() async throws -> [ModelCatalogEntry] {
        try await registry.installedEntries()
    }

    public func resolveModelReference(_ reference: String, contextLength: Int = 4096) async throws -> ModelCatalogEntry? {
        try await registry.resolve(reference: reference, contextLength: contextLength)
    }

    public func activeCatalogId() -> String? {
        activeCatalogIdValue
    }

    public func activeEntry(contextLength: Int = 4096) async throws -> ModelCatalogEntry? {
        guard let activeCatalogIdValue else { return nil }
        return try await registry.resolve(reference: activeCatalogIdValue, contextLength: contextLength)
    }

    public func validateModel(
        catalogId: String,
        runtime: RuntimePreferences
    ) async throws -> ModelValidationOutcome {
        guard let entry = try await registry.resolve(reference: catalogId, contextLength: runtime.contextLength) else {
            throw InferenceError.registryFailure("The selected model could not be found in the registry.")
        }

        let compatibility = await capabilityService.compatibility(for: entry)
        guard compatibility.isUsable else {
            return ModelValidationOutcome(status: .failed, message: compatibility.message)
        }

        switch entry.backendKind {
        case .ggufLlama:
            if activeCatalogIdValue == entry.catalogId, activeBackendKind == .ggufLlama {
                return ModelValidationOutcome(status: .validated, message: "This GGUF model is already loaded and responding on this device.")
            }

            do {
                try await ggufBackend.validate(entry: entry, runtime: runtime)
                return ModelValidationOutcome(status: .validated, message: "Validated a local GGUF load with conservative runtime settings.")
            } catch {
                return ModelValidationOutcome(status: .failed, message: error.localizedDescription)
            }
        case .coreMLPackage:
            return ModelValidationOutcome(
                status: .validated,
                message: compatibility.message
            )
        case .appleFoundation:
            return ModelValidationOutcome(
                status: .validated,
                message: compatibility.message
            )
        }
    }

    @discardableResult
    public func loadModel(catalogId: String, runtime: RuntimePreferences) async throws -> ModelCatalogEntry {
        guard let entry = try await registry.resolve(reference: catalogId, contextLength: runtime.contextLength) else {
            throw InferenceError.registryFailure("The selected model could not be found in the registry.")
        }

        let compatibility = await capabilityService.compatibility(for: entry)
        guard compatibility.isUsable else {
            throw InferenceError.compatibilityFailure(compatibility.message)
        }

        await unloadInactiveBackends(keeping: entry.backendKind)
        try await backend(for: entry.backendKind).load(entry: entry, runtime: runtime)
        activeCatalogIdValue = entry.catalogId
        activeBackendKind = entry.backendKind
        return entry
    }

    public func unloadModel() async {
        await ggufBackend.unload()
        await appleBackend.unload()
        await coreMLBackend.unload()
        activeCatalogIdValue = nil
        activeBackendKind = nil
    }

    public func stopGeneration() async {
        await ggufBackend.stopGeneration()
        await appleBackend.stopGeneration()
        await coreMLBackend.stopGeneration()
    }

    public func generate(
        request: InferenceRequest,
        onChunk: @escaping @Sendable (InferenceChunk) -> Void
    ) async throws -> InferenceResult {
        let entry = try await loadModel(catalogId: request.catalogId, runtime: request.runtimePreferences)
        let result = try await backend(for: entry.backendKind).generate(
            entry: entry,
            request: request,
            onChunk: onChunk
        )
        activeCatalogIdValue = entry.catalogId
        activeBackendKind = entry.backendKind
        return result
    }

    private func unloadInactiveBackends(keeping backendKind: ModelBackendKind) async {
        if backendKind != .ggufLlama {
            await ggufBackend.unload()
        }
        if backendKind != .appleFoundation {
            await appleBackend.unload()
        }
        if backendKind != .coreMLPackage {
            await coreMLBackend.unload()
        }
    }

    private func backend(for kind: ModelBackendKind) -> InferenceBackend {
        switch kind {
        case .ggufLlama:
            return ggufBackend
        case .appleFoundation:
            return appleBackend
        case .coreMLPackage:
            return coreMLBackend
        }
    }

    private static func makeAppleFoundationBackend() -> InferenceBackend {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            return AppleFoundationBackend()
        }
        #endif

        return UnsupportedAppleFoundationBackend()
    }
}

final class UnsupportedAppleFoundationBackend: InferenceBackend, @unchecked Sendable {
    let kind: ModelBackendKind = .appleFoundation

    var activeCatalogId: String? { nil }

    func load(entry: ModelCatalogEntry, runtime: RuntimePreferences) async throws {
        let _ = entry
        let _ = runtime
        throw InferenceError.appleModelUnavailable("Apple's on-device model requires iOS 26 or macOS 26 or newer.")
    }

    func unload() async {}

    func generate(
        entry: ModelCatalogEntry,
        request: InferenceRequest,
        onChunk: @escaping @Sendable (InferenceChunk) -> Void
    ) async throws -> InferenceResult {
        let _ = entry
        let _ = request
        let _ = onChunk
        throw InferenceError.appleModelUnavailable("Apple's on-device model requires iOS 26 or macOS 26 or newer.")
    }

    func stopGeneration() async {}
}

@available(iOS 26.0, macOS 26.0, *)
final class AppleFoundationBackend: InferenceBackend, @unchecked Sendable {
    let kind: ModelBackendKind = .appleFoundation

    var activeCatalogId: String? {
        stateLock.withLock { _activeCatalogId }
    }

    private let stateLock = NSLock()
    private var activeTask: Task<InferenceResult, Error>?
    private var activeRequestID = UUID()
    private var _activeCatalogId: String?

    func load(entry: ModelCatalogEntry, runtime: RuntimePreferences) async throws {
        let _ = runtime
        stateLock.withLock {
            _activeCatalogId = entry.catalogId
        }
    }

    func unload() async {
        await stopGeneration()
        stateLock.withLock {
            _activeCatalogId = nil
        }
    }

    func generate(
        entry: ModelCatalogEntry,
        request: InferenceRequest,
        onChunk: @escaping @Sendable (InferenceChunk) -> Void
    ) async throws -> InferenceResult {
        let _ = onChunk
        stateLock.withLock {
            _activeCatalogId = entry.catalogId
        }

        #if canImport(FoundationModels)
        await stopGeneration()

        let requestID = UUID()
        activeRequestID = requestID

        let normalizedPrompt: String
        if request.isChatRequest {
            normalizedPrompt = ConversationPrompting.promptForAssistant(
                systemPrompt: nil,
                turns: request.conversationTurns
            )
        } else {
            normalizedPrompt = request.prompt.trimmedForLookup
        }

        let instructions = ConversationPrompting.guardedSystemPrompt(
            request.systemPrompt,
            includeGuard: request.isChatRequest
        )
        let chatStopSequences = ConversationPrompting.mergedStopSequences(
            request.parameters.stopSequences,
            includeDefaultChatStops: request.isChatRequest
        )

        let task = Task<InferenceResult, Error> {
            let startedAt = CFAbsoluteTimeGetCurrent()
            let session: LanguageModelSession
            if let instructions {
                session = LanguageModelSession(instructions: instructions)
            } else {
                session = LanguageModelSession()
            }

            let response = try await session.respond(to: normalizedPrompt)
            try Task.checkCancellation()
            let responseText = request.isChatRequest
                ? ConversationPrompting.finalizedAssistantText(
                    from: response.content,
                    stopSequences: chatStopSequences
                )
                : response.content.trimmedForLookup

            let elapsed = max(CFAbsoluteTimeGetCurrent() - startedAt, 0.001)
            return InferenceResult(
                text: responseText,
                tokensGenerated: 0,
                promptTokens: 0,
                generationTime: elapsed,
                tokensPerSecond: 0,
                wasCancelled: false
            )
        }

        activeTask = task

        do {
            let result = try await task.value
            if activeRequestID == requestID {
                activeTask = nil
            }
            return result
        } catch is CancellationError {
            if activeRequestID == requestID {
                activeTask = nil
            }
            throw InferenceError.generationCancelled
        } catch {
            if activeRequestID == requestID {
                activeTask = nil
            }
            throw error
        }
        #else
        throw InferenceError.appleModelUnavailable("This build does not include Apple's on-device model.")
        #endif
    }

    func stopGeneration() async {
        activeRequestID = UUID()
        activeTask?.cancel()
        activeTask = nil
    }
}

final class CoreMLPackageBackend: InferenceBackend, @unchecked Sendable {
    let kind: ModelBackendKind = .coreMLPackage

    var activeCatalogId: String? {
        stateLock.withLock { _activeCatalogId }
    }

    private let stateLock = NSLock()
    private var _activeCatalogId: String?
    private var loadedPackageRootPath: String?
    private var loadedRuntimeRootPath: String?
    private var activeTask: Task<InferenceResult, Error>?
    private var activeRequestID = UUID()

    #if canImport(AnemllCore)
    private var loadedConfig: AnemllCore.YAMLConfig?
    private var loadedTokenizer: AnemllCore.Tokenizer?
    private var loadedModels: AnemllCore.LoadedModels?
    private var inferenceManager: AnemllCore.InferenceManager?
    #endif

    func load(entry: ModelCatalogEntry, runtime: RuntimePreferences) async throws {
        let _ = runtime
        guard let packageRootPath = entry.packageRootPath?.trimmedForLookup, !packageRootPath.isEmpty else {
            throw InferenceError.backendUnavailable("This CoreML package is missing its package root.")
        }

        guard FileManager.default.fileExists(atPath: packageRootPath) else {
            throw InferenceError.backendUnavailable("This CoreML package no longer exists on disk.")
        }

        #if canImport(AnemllCore)
        let packageRootURL = URL(fileURLWithPath: packageRootPath)
        guard let runtimeRootURL = CoreMLPackageLocator.runtimeModelRootURL(packageRootURL: packageRootURL) else {
            throw InferenceError.backendUnavailable(
                "Import the full ANEMLL/CoreML model folder containing meta.yaml, tokenizer assets, and compiled .mlmodelc or .mlpackage payloads."
            )
        }

        let needsReload = stateLock.withLock {
            loadedPackageRootPath != packageRootPath || loadedRuntimeRootPath != runtimeRootURL.path || inferenceManager == nil
        }

        if needsReload {
            await stopGeneration()
            unloadLoadedRuntime()

            let metaURL = runtimeRootURL.appendingPathComponent("meta.yaml")
            let config: AnemllCore.YAMLConfig
            do {
                config = try AnemllCore.YAMLConfig.load(from: metaURL.path)
            } catch {
                throw InferenceError.backendUnavailable("Failed to read meta.yaml from the imported CoreML package: \(error.localizedDescription)")
            }

            let template = templateName(for: config.modelPrefix)
            let tokenizer: AnemllCore.Tokenizer
            do {
                tokenizer = try await AnemllCore.Tokenizer(
                    modelPath: runtimeRootURL.path,
                    template: template,
                    debugLevel: 0
                )
            } catch {
                throw InferenceError.backendUnavailable("Failed to initialize the imported model tokenizer: \(error.localizedDescription)")
            }

            let loader = AnemllCore.ModelLoader()
            let models: AnemllCore.LoadedModels
            do {
                models = try await loader.loadModel(from: config)
            } catch {
                throw InferenceError.backendUnavailable("Failed to load the imported CoreML models: \(error.localizedDescription)")
            }

            let manager: AnemllCore.InferenceManager
            do {
                manager = try AnemllCore.InferenceManager(
                    models: models,
                    contextLength: config.contextLength,
                    batchSize: config.batchSize,
                    splitLMHead: config.splitLMHead,
                    debugLevel: 0,
                    v110: config.configVersion == "0.1.1",
                    argmaxInModel: config.argmaxInModel,
                    slidingWindow: config.slidingWindow,
                    updateMaskPrefill: config.updateMaskPrefill,
                    prefillDynamicSlice: config.prefillDynamicSlice,
                    modelPrefix: config.modelPrefix,
                    vocabSize: config.vocabSize,
                    lmHeadChunkSizes: config.lmHeadChunkSizes
                )
            } catch {
                throw InferenceError.backendUnavailable("Failed to initialize the imported CoreML inference engine: \(error.localizedDescription)")
            }

            stateLock.withLock {
                loadedPackageRootPath = packageRootPath
                loadedRuntimeRootPath = runtimeRootURL.path
                loadedConfig = config
                loadedTokenizer = tokenizer
                loadedModels = models
                inferenceManager = manager
            }
        }

        stateLock.withLock {
            _activeCatalogId = entry.catalogId
        }
        #else
        throw InferenceError.backendUnavailable("This build does not include the ANEMLL CoreML runtime.")
        #endif
    }

    func unload() async {
        await stopGeneration()
        unloadLoadedRuntime()
        stateLock.withLock {
            _activeCatalogId = nil
        }
    }

    func generate(
        entry: ModelCatalogEntry,
        request: InferenceRequest,
        onChunk: @escaping @Sendable (InferenceChunk) -> Void
    ) async throws -> InferenceResult {
        #if canImport(AnemllCore)
        try await load(entry: entry, runtime: request.runtimePreferences)
        await stopGeneration()

        let requestID = UUID()
        let runtimeState = stateLock.withLock {
            activeRequestID = requestID
            return (
                inferenceManager,
                loadedTokenizer,
                loadedConfig != nil
            )
        }

        guard let manager = runtimeState.0,
              let tokenizer = runtimeState.1,
              runtimeState.2 else {
            throw InferenceError.backendUnavailable("The imported CoreML package was not initialized correctly.")
        }

        let sampling = coreMLSamplingConfig(from: request.parameters)
        manager.setSamplingConfig(sampling)

        let chatMessages = buildChatMessages(from: request)
        let initialTokens = tokenizer.applyChatTemplate(
            input: chatMessages,
            addGenerationPrompt: true
        )

        let stopSequences = ConversationPrompting.mergedStopSequences(
            request.parameters.stopSequences,
            includeDefaultChatStops: request.isChatRequest
        )
        let generationTask = Task<InferenceResult, Error> {
            var accumulatedText = ""
            var emittedCharacters = 0
            let startedAt = CFAbsoluteTimeGetCurrent()

            let generation = try await manager.generateResponse(
                initialTokens: initialTokens,
                temperature: sampling.doSample ? Float(max(request.parameters.temperature, 0.01)) : 0,
                maxTokens: request.parameters.maxTokens,
                eosTokens: tokenizer.eosTokenIds,
                tokenizer: tokenizer,
                onToken: { token in
                    if Task.isCancelled {
                        manager.AbortGeneration(Code: 900)
                        return
                    }

                    let tokenText = tokenizer.decode(tokens: [token], skipSpecialTokens: true)
                    guard !tokenText.isEmpty else { return }

                    accumulatedText.append(tokenText)
                    let trimmed: (visibleText: String, didMatchStopSequence: Bool)
                    if request.isChatRequest {
                        let visible = ConversationPrompting.visibleAssistantText(
                            from: accumulatedText,
                            stopSequences: stopSequences
                        )
                        trimmed = (visible.visibleText, visible.shouldStop)
                    } else {
                        trimmed = self.trimmedForStopSequences(accumulatedText, stopSequences: stopSequences)
                    }

                    if trimmed.didMatchStopSequence {
                        manager.AbortGeneration(Code: 901)
                    }

                    if trimmed.visibleText.count > emittedCharacters {
                        let delta = String(trimmed.visibleText.dropFirst(emittedCharacters))
                        emittedCharacters = trimmed.visibleText.count
                        if !delta.isEmpty {
                            onChunk(InferenceChunk(text: delta))
                        }
                    }
                },
                onWindowShift: nil
            )

            let elapsed = max(CFAbsoluteTimeGetCurrent() - startedAt, 0.001)
            let finalText: String
            if request.isChatRequest {
                finalText = ConversationPrompting.finalizedAssistantText(
                    from: accumulatedText,
                    stopSequences: stopSequences
                )
            } else {
                finalText = trimmedForStopSequences(accumulatedText, stopSequences: stopSequences).visibleText
            }

            return InferenceResult(
                text: finalText,
                tokensGenerated: generation.0.count,
                promptTokens: initialTokens.count,
                generationTime: elapsed,
                tokensPerSecond: generation.0.isEmpty ? 0 : Double(generation.0.count) / elapsed,
                wasCancelled: false
            )
        }

        stateLock.withLock {
            activeTask = generationTask
        }

        do {
            let result = try await generationTask.value
            stateLock.withLock {
                if activeRequestID == requestID {
                    activeTask = nil
                }
            }
            return result
        } catch is CancellationError {
            stateLock.withLock {
                if activeRequestID == requestID {
                    activeTask = nil
                }
            }
            throw InferenceError.generationCancelled
        } catch let error as InferenceError {
            stateLock.withLock {
                if activeRequestID == requestID {
                    activeTask = nil
                }
            }
            throw error
        } catch {
            stateLock.withLock {
                if activeRequestID == requestID {
                    activeTask = nil
                }
            }
            throw InferenceError.backendUnavailable("CoreML generation failed: \(error.localizedDescription)")
        }
        #else
        let _ = entry
        let _ = request
        let _ = onChunk
        throw InferenceError.unsupportedBackend("This build does not include the ANEMLL CoreML runtime.")
        #endif
    }

    func stopGeneration() async {
        stateLock.withLock {
            activeRequestID = UUID()
            #if canImport(AnemllCore)
            inferenceManager?.AbortGeneration(Code: 900)
            #endif
            activeTask?.cancel()
            activeTask = nil
        }
    }

    private func unloadLoadedRuntime() {
        #if canImport(AnemllCore)
        stateLock.withLock {
            inferenceManager?.unload()
            inferenceManager = nil
            loadedModels = nil
            loadedTokenizer = nil
            loadedConfig = nil
            loadedPackageRootPath = nil
            loadedRuntimeRootPath = nil
        }
        #else
        stateLock.withLock {
            loadedPackageRootPath = nil
            loadedRuntimeRootPath = nil
        }
        #endif
    }

    #if canImport(AnemllCore)
    private func buildChatMessages(from request: InferenceRequest) -> [AnemllCore.Tokenizer.ChatMessage] {
        var messages: [AnemllCore.Tokenizer.ChatMessage] = []

        if let systemPrompt = ConversationPrompting.guardedSystemPrompt(
            request.systemPrompt,
            includeGuard: request.isChatRequest
        ) {
            messages.append(.system(systemPrompt))
        }

        let structuredTurns = ConversationPrompting.normalizedTurns(request.conversationTurns)
        if !structuredTurns.isEmpty {
            for turn in structuredTurns {
                switch turn.role {
                case "system":
                    messages.append(.system(turn.content))
                case "assistant":
                    messages.append(.assistant(turn.content))
                case "user":
                    messages.append(.user(turn.content))
                default:
                    break
                }
            }
            return messages
        }

        let parsedTurns = parseTranscriptPrompt(request.prompt)
        if !parsedTurns.isEmpty {
            messages.append(contentsOf: parsedTurns)
            return messages
        }

        let prompt = request.prompt.trimmedForLookup
        if let nonEmptyPrompt = prompt.nonEmpty {
            messages.append(.user(nonEmptyPrompt))
        }

        return messages
    }

    private func parseTranscriptPrompt(_ prompt: String) -> [AnemllCore.Tokenizer.ChatMessage] {
        let trimmedPrompt = prompt.trimmedForLookup
        guard !trimmedPrompt.isEmpty else { return [] }

        let pattern = #"(?m)^(System|User|Assistant|Human|Me|Bot):\n"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }

        let nsRange = NSRange(trimmedPrompt.startIndex..<trimmedPrompt.endIndex, in: trimmedPrompt)
        let matches = regex.matches(in: trimmedPrompt, options: [], range: nsRange)
        guard !matches.isEmpty else { return [] }

        var messages: [AnemllCore.Tokenizer.ChatMessage] = []

        for (index, match) in matches.enumerated() {
            guard let roleRange = Range(match.range(at: 1), in: trimmedPrompt) else { continue }
            guard let contentStart = Range(match.range, in: trimmedPrompt)?.upperBound else { continue }

            let contentEnd: String.Index
            if index + 1 < matches.count,
               let nextRange = Range(matches[index + 1].range, in: trimmedPrompt) {
                contentEnd = nextRange.lowerBound
            } else {
                contentEnd = trimmedPrompt.endIndex
            }

            let content = trimmedPrompt[contentStart..<contentEnd].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { continue }

            switch trimmedPrompt[roleRange].lowercased() {
            case "system":
                messages.append(.system(content))
            case "assistant", "bot":
                messages.append(.assistant(content))
            case "human", "me", "user":
                messages.append(.user(content))
            default:
                break
            }
        }

        return messages
    }

    private func coreMLSamplingConfig(from parameters: SamplingParameters) -> AnemllCore.SamplingConfig {
        let shouldSample = parameters.temperature > 0.001 && parameters.topP > 0
        if !shouldSample {
            return .greedy
        }

        return AnemllCore.SamplingConfig(
            doSample: true,
            temperature: max(parameters.temperature, 0.01),
            topK: max(parameters.topK, 0),
            topP: min(max(parameters.topP, 0.01), 1.0),
            repetitionPenalty: max(parameters.repeatPenalty, 1.0)
        )
    }
    #endif

    private func templateName(for modelPrefix: String) -> String {
        let normalized = modelPrefix.trimmedForLookup.lowercased()

        if normalized.contains("gemma3") { return "gemma3" }
        if normalized.contains("gemma") { return "gemma" }
        if normalized.contains("qwen") { return "qwen" }
        if normalized.contains("deepseek") { return "deepseek" }
        if normalized.contains("deephermes") { return "deephermes" }
        if normalized.contains("llama") { return "llama" }
        if normalized.contains("mistral") { return "mistral" }

        return "default"
    }

    private func trimmedForStopSequences(
        _ text: String,
        stopSequences: [String]
    ) -> (visibleText: String, didMatchStopSequence: Bool) {
        let effectiveStopSequences = stopSequences
            .filter { !$0.isEmpty }

        guard !effectiveStopSequences.isEmpty else {
            return (text, false)
        }

        var earliestRange: Range<String.Index>?

        for stopSequence in effectiveStopSequences {
            guard let range = text.range(of: stopSequence) else { continue }
            if let currentEarliestRange = earliestRange {
                if range.lowerBound < currentEarliestRange.lowerBound {
                    earliestRange = range
                }
            } else {
                earliestRange = range
            }
        }

        guard let earliestRange else {
            return (text, false)
        }

        return (String(text[..<earliestRange.lowerBound]), true)
    }
}
