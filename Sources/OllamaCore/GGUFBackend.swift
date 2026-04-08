import Foundation

#if canImport(llama)
import llama
#endif

final class GGUFBackend: InferenceBackend, @unchecked Sendable {
    let kind: ModelBackendKind = .ggufLlama

    var activeCatalogId: String? {
        stateLock.withLock { _activeCatalogId }
    }

    private let queue = DispatchQueue(label: "com.ollamakit.ollamacore.gguf", qos: .userInitiated)
    // FIX: All writes to cancelRequested go through a single serial queue.
    // Previously setCancelRequested() was called from both queue.async blocks and from
    // the main actor, creating a data race from Swift's perspective (writes from multiple
    // isolation domains to the same mutable state without synchronized access).
    // By routing every write through the queue, all reads and writes are serialized.
    private let cancelQueue = DispatchQueue(label: "com.ollamakit.gguf.cancel")
    private var _cancelRequested = false

    private var cancelRequested: Bool {
        get { _cancelRequested }
        set { cancelQueue.sync { _cancelRequested = newValue } }
    }

    private let stateLock = NSLock()

    private var backend: BackendEngine?
    private var autoOffloadTask: Task<Void, Never>?
    private var _activeCatalogId: String?
    private var _loadedModelPath: String?

    func validate(entry: ModelCatalogEntry, runtime: RuntimePreferences) async throws {
        guard let path = entry.localPath?.trimmedForLookup, !path.isEmpty else {
            throw InferenceError.invalidPath
        }

        guard FileManager.default.fileExists(atPath: path) else {
            throw InferenceError.modelNotFound("Model file not found at the stored path. Please re-download the model.")
        }

        let configuration = BackendConfiguration(
            catalogId: entry.catalogId,
            modelPath: path,
            contextLength: runtime.contextLength,
            gpuLayers: runtime.gpuLayers,
            threads: runtime.threads,
            batchSize: runtime.batchSize,
            kvCachePreset: runtime.kvCachePreset,
            flashAttentionEnabled: runtime.flashAttentionEnabled,
            mmapEnabled: runtime.mmapEnabled,
            mlockEnabled: runtime.mlockEnabled
        )

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    let temporaryEngine = try BackendEngine(configuration: configuration)
                    withExtendedLifetime(temporaryEngine) {}
                    continuation.resume()
                } catch {
                    let fileName = URL(fileURLWithPath: path).lastPathComponent
                    let sizeDescription = ByteCountFormatter.string(
                        fromByteCount: entry.capabilitySummary.sizeBytes,
                        countStyle: .file
                    )
                    let message = "GGUF validation failed for \(entry.displayName) (\(fileName), \(sizeDescription), \(entry.capabilitySummary.quantization)): \(error.localizedDescription)"
                    continuation.resume(throwing: InferenceError.backendUnavailable(message))
                }
            }
        }
    }

    func load(entry: ModelCatalogEntry, runtime: RuntimePreferences) async throws {
        guard let path = entry.localPath?.trimmedForLookup, !path.isEmpty else {
            throw InferenceError.invalidPath
        }

        guard FileManager.default.fileExists(atPath: path) else {
            throw InferenceError.modelNotFound("Model file not found at the stored path. Please re-download the model.")
        }

        cancelAutoOffload()

        let configuration = BackendConfiguration(
            catalogId: entry.catalogId,
            modelPath: path,
            contextLength: runtime.contextLength,
            gpuLayers: runtime.gpuLayers,
            threads: runtime.threads,
            batchSize: runtime.batchSize,
            kvCachePreset: runtime.kvCachePreset,
            flashAttentionEnabled: runtime.flashAttentionEnabled,
            mmapEnabled: runtime.mmapEnabled,
            mlockEnabled: runtime.mlockEnabled
        )

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    if let backend = self.backend, backend.matches(configuration) {
                        self.setCancelRequested(false)
                        self.stateLock.withLock {
                            self._activeCatalogId = configuration.catalogId
                            self._loadedModelPath = configuration.modelPath
                        }
                        continuation.resume()
                        return
                    }

                    self.setCancelRequested(true)
                    self.backend = nil

                    let backend = try BackendEngine(configuration: configuration)
                    self.backend = backend
                    self.setCancelRequested(false)

                    self.stateLock.withLock {
                        self._activeCatalogId = configuration.catalogId
                        self._loadedModelPath = configuration.modelPath
                    }
                    continuation.resume()
                } catch {
                    self.backend = nil
                    self.setCancelRequested(false)
                    self.stateLock.withLock {
                        self._activeCatalogId = nil
                        self._loadedModelPath = nil
                    }
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func unload() async {
        cancelAutoOffload()

        stateLock.withLock {
            _activeCatalogId = nil
            _loadedModelPath = nil
        }

        queue.async {
            self.setCancelRequested(true)
            self.backend = nil
        }
    }

    func generate(
        entry: ModelCatalogEntry,
        request: InferenceRequest,
        onChunk: @escaping @Sendable (InferenceChunk) -> Void
    ) async throws -> InferenceResult {
        if activeCatalogId != entry.catalogId {
            try await load(entry: entry, runtime: request.runtimePreferences)
            guard activeCatalogId == entry.catalogId else {
                throw InferenceError.noModelLoaded
            }
        }

        cancelAutoOffload()
        let isChatRequest = request.isChatRequest
        let effectivePrompt = buildEffectivePrompt(request: request)
        let effectiveParameters = effectiveParameters(for: request)

        let result: InferenceResult = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<InferenceResult, Error>) in
            queue.async {
                guard let backend = self.backend else {
                    continuation.resume(throwing: InferenceError.noModelLoaded)
                    return
                }

                self.setCancelRequested(false)

                do {
                    let result = try backend.generate(
                        prompt: effectivePrompt,
                        parameters: effectiveParameters,
                        treatOutputAsChat: isChatRequest,
                        shouldCancel: { [weak self] in
                            self?.isCancellationRequested ?? true
                        },
                        onToken: { token in
                            onChunk(InferenceChunk(text: token))
                        }
                    )

                    self.setCancelRequested(false)
                    continuation.resume(returning: result)
                } catch {
                    self.setCancelRequested(false)
                    continuation.resume(throwing: error)
                }
            }
        }

        scheduleAutoOffloadIfNeeded(using: request.runtimePreferences)
        return result
    }

    func stopGeneration() async {
        setCancelRequested(true)
    }

    private func buildEffectivePrompt(request: InferenceRequest) -> String {
        if request.isChatRequest {
            return ConversationPrompting.promptForAssistant(
                systemPrompt: request.systemPrompt,
                turns: request.conversationTurns
            )
        }

        return [request.systemPrompt?.trimmedForLookup, request.prompt.trimmedForLookup]
            .compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: "\n\n")
    }

    private func effectiveParameters(for request: InferenceRequest) -> SamplingParameters {
        guard request.isChatRequest else { return request.parameters }

        var parameters = request.parameters
        parameters.stopSequences = ConversationPrompting.mergedStopSequences(
            parameters.stopSequences,
            includeDefaultChatStops: true
        )
        return parameters
    }

    private func cancelAutoOffload() {
        autoOffloadTask?.cancel()
        autoOffloadTask = nil
    }

    private func scheduleAutoOffloadIfNeeded(using runtime: RuntimePreferences) {
        cancelAutoOffload()
        guard activeCatalogId != nil, !runtime.keepModelInMemory else { return }

        autoOffloadTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(runtime.autoOffloadMinutes * 60))
                guard !Task.isCancelled else { return }
                await self?.unload()
            } catch {
                return
            }
        }
    }

    private var isCancellationRequested: Bool {
        stateLock.withLock { cancelRequested }
    }

    private func setCancelRequested(_ value: Bool) {
        stateLock.withLock {
            cancelRequested = value
        }
    }
}

private struct BackendConfiguration: Equatable {
    let catalogId: String
    let modelPath: String
    let contextLength: Int
    let gpuLayers: Int
    let threads: Int
    let batchSize: Int
    let kvCachePreset: RuntimePreferences.KVCachePreset
    let flashAttentionEnabled: Bool
    let mmapEnabled: Bool
    let mlockEnabled: Bool
}

#if canImport(llama)
private final class BackendEngine {
    private static let backendInitLock = NSLock()
    private static var backendInitialized = false

    private let configuration: BackendConfiguration
    private let model: OpaquePointer
    private let context: OpaquePointer
    private let vocab: OpaquePointer
    private let batchCapacity: Int32
    private var batch: llama_batch
    private var invalidUTF8Buffer: [CChar] = []

    init(configuration: BackendConfiguration) throws {
        self.configuration = configuration

        try Self.initializeBackendIfNeeded()

        var modelParams = llama_model_default_params()

        #if targetEnvironment(simulator)
        modelParams.n_gpu_layers = 0
        #else
        modelParams.n_gpu_layers = Int32(configuration.gpuLayers)
        #endif

        modelParams.use_mmap = configuration.mmapEnabled
        modelParams.use_mlock = configuration.mlockEnabled
        modelParams.check_tensors = false

        guard let loadedModel = llama_model_load_from_file(configuration.modelPath, modelParams) else {
            throw InferenceError.failedToLoadModel
        }

        var contextParams = llama_context_default_params()
        let normalizedBatchSize = min(max(configuration.batchSize, 32), configuration.contextLength)

        contextParams.n_ctx = UInt32(configuration.contextLength)
        contextParams.n_batch = UInt32(normalizedBatchSize)
        contextParams.n_ubatch = UInt32(normalizedBatchSize)
        contextParams.n_seq_max = 1
        contextParams.n_threads = Int32(configuration.threads)
        contextParams.n_threads_batch = Int32(configuration.threads)
        contextParams.flash_attn_type = configuration.flashAttentionEnabled ? LLAMA_FLASH_ATTN_TYPE_ENABLED : LLAMA_FLASH_ATTN_TYPE_DISABLED
        contextParams.no_perf = false
        Self.applyKVCachePreset(configuration.kvCachePreset, to: &contextParams)

        #if targetEnvironment(simulator)
        contextParams.offload_kqv = false
        contextParams.op_offload = false
        #else
        let shouldOffload = configuration.gpuLayers > 0
        contextParams.offload_kqv = shouldOffload
        contextParams.op_offload = shouldOffload
        #endif

        guard let createdContext = llama_init_from_model(loadedModel, contextParams) else {
            llama_model_free(loadedModel)
            throw InferenceError.failedToCreateContext
        }

        guard let loadedVocab = llama_model_get_vocab(loadedModel) else {
            llama_free(createdContext)
            llama_model_free(loadedModel)
            throw InferenceError.failedToLoadModel
        }

        self.model = loadedModel
        self.context = createdContext
        self.vocab = loadedVocab
        self.batchCapacity = Int32(normalizedBatchSize)
        self.batch = llama_batch_init(self.batchCapacity, 0, 1)
    }

    deinit {
        llama_batch_free(batch)
        llama_free(context)
        llama_model_free(model)
    }

    func matches(_ configuration: BackendConfiguration) -> Bool {
        self.configuration == configuration
    }

    private static func applyKVCachePreset(_ preset: RuntimePreferences.KVCachePreset, to params: inout llama_context_params) {
        switch preset {
        case .platformDefault:
            break
        case .q8_0:
            params.type_k = GGML_TYPE_Q8_0
            params.type_v = GGML_TYPE_Q8_0
        case .googleTurboQ4:
            // TurboQuant-style setting used by community forks (e.g. `-ctk turbo4 -ctv turbo4`)
            // is approximated here by forcing Q4_0 KV cache types on stock llama.cpp.
            params.type_k = GGML_TYPE_Q4_0
            params.type_v = GGML_TYPE_Q4_0
        }
    }

    func generate(
        prompt: String,
        parameters: SamplingParameters,
        treatOutputAsChat: Bool,
        shouldCancel: () -> Bool,
        onToken: (String) -> Void
    ) throws -> InferenceResult {
        let startedAt = CFAbsoluteTimeGetCurrent()
        llama_memory_clear(llama_get_memory(context), true)
        invalidUTF8Buffer.removeAll(keepingCapacity: true)

        let promptTokens = try tokenize(prompt)
        guard !promptTokens.isEmpty else {
            throw InferenceError.tokenizationError
        }

        let boundedPromptTokens = truncatePromptTokensIfNeeded(promptTokens)
        try decodePromptTokens(boundedPromptTokens)

        let sampler = try makeSampler(parameters: parameters)
        defer { llama_sampler_free(sampler) }

        var rawGeneratedText = ""
        var streamedText = ""
        var generatedTokenCount = 0
        var currentPosition = Int32(boundedPromptTokens.count)
        var wasCancelled = false
        var stoppedByStopSequence = false
        let maxNewTokens = normalizedMaxNewTokens(
            promptTokens: boundedPromptTokens.count,
            requestedMaxTokens: parameters.maxTokens
        )

        while generatedTokenCount < maxNewTokens {
            if shouldCancel() {
                wasCancelled = true
                break
            }

            let token = llama_sampler_sample(sampler, context, batch.n_tokens - 1)
            if llama_vocab_is_eog(vocab, token) {
                break
            }

            llama_sampler_accept(sampler, token)

            let piece = tokenToPiece(token)
            if !piece.isEmpty {
                rawGeneratedText += piece

                let stopHandling = applyStopSequences(
                    to: rawGeneratedText,
                    stopSequences: parameters.stopSequences,
                    treatOutputAsChat: treatOutputAsChat
                )
                let nextVisibleText = stopHandling.visibleText

                if nextVisibleText.count > streamedText.count {
                    let deltaStart = nextVisibleText.index(nextVisibleText.startIndex, offsetBy: streamedText.count)
                    let delta = String(nextVisibleText[deltaStart...])
                    streamedText = nextVisibleText
                    onToken(delta)
                }

                if stopHandling.shouldStop {
                    stoppedByStopSequence = true
                    break
                }
            }

            llamaBatchClear(&batch)
            llamaBatchAdd(&batch, token, currentPosition, [0], true)
            currentPosition += 1

            if llama_decode(context, batch) != 0 {
                throw InferenceError.decodeError
            }

            generatedTokenCount += 1
        }

        llama_synchronize(context)
        let elapsed = max(CFAbsoluteTimeGetCurrent() - startedAt, 0.001)
        let finalText: String
        if treatOutputAsChat {
            finalText = ConversationPrompting.finalizedAssistantText(
                from: stoppedByStopSequence ? streamedText : rawGeneratedText,
                stopSequences: parameters.stopSequences
            )
        } else {
            finalText = stoppedByStopSequence ? streamedText : rawGeneratedText
        }

        return InferenceResult(
            text: finalText,
            tokensGenerated: generatedTokenCount,
            promptTokens: boundedPromptTokens.count,
            generationTime: elapsed,
            tokensPerSecond: Double(max(generatedTokenCount, 1)) / elapsed,
            wasCancelled: wasCancelled
        )
    }

    private static func initializeBackendIfNeeded() throws {
        backendInitLock.withLock {
            guard !backendInitialized else { return }
            llama_backend_init()
            backendInitialized = true
        }
    }

    private func tokenize(_ text: String) throws -> [llama_token] {
        let utf8Count = text.utf8.count
        let addSpecial = llama_vocab_get_add_bos(vocab)
        let maxTokenCount = max(utf8Count + 8, configuration.contextLength + 8)
        let tokens = UnsafeMutablePointer<llama_token>.allocate(capacity: maxTokenCount)
        defer { tokens.deallocate() }

        let tokenCount = llama_tokenize(
            vocab,
            text,
            Int32(utf8Count),
            tokens,
            Int32(maxTokenCount),
            addSpecial,
            false
        )

        guard tokenCount > 0 else {
            throw InferenceError.tokenizationError
        }

        return Array(UnsafeBufferPointer(start: tokens, count: Int(tokenCount)))
    }

    private func truncatePromptTokensIfNeeded(_ tokens: [llama_token]) -> [llama_token] {
        let reservedForGeneration = max(min(configuration.contextLength / 8, 512), 64)
        let availablePromptSlots = max(configuration.contextLength - reservedForGeneration, 1)

        guard tokens.count > availablePromptSlots else { return tokens }
        return Array(tokens.suffix(availablePromptSlots))
    }

    private func decodePromptTokens(_ tokens: [llama_token]) throws {
        var startIndex = 0

        while startIndex < tokens.count {
            let endIndex = min(startIndex + Int(batchCapacity), tokens.count)
            let chunk = tokens[startIndex..<endIndex]

            llamaBatchClear(&batch)

            for (offset, token) in chunk.enumerated() {
                let absoluteIndex = startIndex + offset
                let shouldEmitLogits = absoluteIndex == tokens.count - 1
                llamaBatchAdd(&batch, token, Int32(absoluteIndex), [0], shouldEmitLogits)
            }

            if llama_decode(context, batch) != 0 {
                throw InferenceError.decodeError
            }

            startIndex = endIndex
        }
    }

    private func normalizedMaxNewTokens(promptTokens: Int, requestedMaxTokens: Int) -> Int {
        let remainingContext = max(configuration.contextLength - promptTokens, 1)

        if requestedMaxTokens > 0 {
            return min(requestedMaxTokens, remainingContext)
        }

        return remainingContext
    }

    private func makeSampler(parameters: SamplingParameters) throws -> UnsafeMutablePointer<llama_sampler> {
        let samplerParams = llama_sampler_chain_default_params()
        guard let sampler = llama_sampler_chain_init(samplerParams) else {
            throw InferenceError.failedToInitializeBackend
        }

        llama_sampler_chain_add(
            sampler,
            llama_sampler_init_penalties(
                Int32(max(parameters.repeatLastN, 0)),
                Float(parameters.repeatPenalty),
                0,
                0
            )
        )

        if parameters.topK > 0 {
            llama_sampler_chain_add(sampler, llama_sampler_init_top_k(Int32(parameters.topK)))
        }

        if parameters.topP > 0 {
            llama_sampler_chain_add(sampler, llama_sampler_init_top_p(Float(parameters.topP), 1))
        }

        if parameters.temperature <= 0.0001 {
            llama_sampler_chain_add(sampler, llama_sampler_init_greedy())
        } else {
            llama_sampler_chain_add(sampler, llama_sampler_init_temp(Float(parameters.temperature)))
            llama_sampler_chain_add(sampler, llama_sampler_init_dist(LLAMA_DEFAULT_SEED))
        }

        return sampler
    }

    private func tokenToPiece(_ token: llama_token) -> String {
        let tokenBytes = tokenToPieceBytes(token)
        invalidUTF8Buffer.append(contentsOf: tokenBytes)

        if let string = String(validatingUTF8: invalidUTF8Buffer + [0]) {
            invalidUTF8Buffer.removeAll(keepingCapacity: true)
            return string
        }

        if (0..<invalidUTF8Buffer.count).contains(where: { suffixLength in
            guard suffixLength > 0 else { return false }
            return String(validatingUTF8: Array(invalidUTF8Buffer.suffix(suffixLength)) + [0]) != nil
        }) {
            let string = String(cString: invalidUTF8Buffer + [0])
            invalidUTF8Buffer.removeAll(keepingCapacity: true)
            return string
        }

        return ""
    }

    private func tokenToPieceBytes(_ token: llama_token) -> [CChar] {
        let initialCapacity = 16
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: initialCapacity)
        buffer.initialize(repeating: 0, count: initialCapacity)
        defer { buffer.deallocate() }

        let count = llama_token_to_piece(vocab, token, buffer, Int32(initialCapacity), 0, false)

        if count < 0 {
            let largerCapacity = Int(-count)
            let largerBuffer = UnsafeMutablePointer<CChar>.allocate(capacity: largerCapacity)
            largerBuffer.initialize(repeating: 0, count: largerCapacity)
            defer { largerBuffer.deallocate() }

            let resolvedCount = llama_token_to_piece(vocab, token, largerBuffer, Int32(largerCapacity), 0, false)
            return Array(UnsafeBufferPointer(start: largerBuffer, count: Int(resolvedCount)))
        }

        return Array(UnsafeBufferPointer(start: buffer, count: Int(count)))
    }

    private func applyStopSequences(
        to text: String,
        stopSequences: [String],
        treatOutputAsChat: Bool
    ) -> (visibleText: String, shouldStop: Bool) {
        if treatOutputAsChat {
            return ConversationPrompting.visibleAssistantText(
                from: text,
                stopSequences: stopSequences
            )
        }

        let cleanedStopSequences = stopSequences.filter { !$0.isEmpty }
        guard !cleanedStopSequences.isEmpty else {
            return (text, false)
        }

        let matches = cleanedStopSequences.compactMap { sequence in
            text.range(of: sequence).map { range in
                (range, sequence)
            }
        }

        if let earliestMatch = matches.min(by: { lhs, rhs in
            lhs.0.lowerBound < rhs.0.lowerBound
        }) {
            return (String(text[..<earliestMatch.0.lowerBound]), true)
        }

        let withheldCount = cleanedStopSequences.reduce(into: 0) { partialResult, sequence in
            let maxCandidateLength = min(sequence.count - 1, text.count)
            guard maxCandidateLength > 0 else { return }

            for length in stride(from: maxCandidateLength, through: 1, by: -1) {
                let suffixStart = text.index(text.endIndex, offsetBy: -length)
                let suffix = String(text[suffixStart...])
                if sequence.hasPrefix(suffix) {
                    partialResult = max(partialResult, length)
                    break
                }
            }
        }

        guard withheldCount > 0 else {
            return (text, false)
        }

        let visibleEnd = text.index(text.endIndex, offsetBy: -withheldCount)
        return (String(text[..<visibleEnd]), false)
    }
}

private func llamaBatchClear(_ batch: inout llama_batch) {
    batch.n_tokens = 0
}

private func llamaBatchAdd(
    _ batch: inout llama_batch,
    _ token: llama_token,
    _ position: llama_pos,
    _ sequenceIDs: [llama_seq_id],
    _ emitLogits: Bool
) {
    let index = Int(batch.n_tokens)
    batch.token[index] = token
    batch.pos[index] = position
    batch.n_seq_id[index] = Int32(sequenceIDs.count)

    for (offset, sequenceID) in sequenceIDs.enumerated() {
        batch.seq_id[index]?[offset] = sequenceID
    }

    batch.logits[index] = emitLogits ? 1 : 0
    batch.n_tokens += 1
}
#else
private final class BackendEngine {
    private let configuration: BackendConfiguration

    init(configuration: BackendConfiguration) throws {
        self.configuration = configuration
        throw InferenceError.failedToInitializeBackend
    }

    func matches(_ configuration: BackendConfiguration) -> Bool {
        self.configuration == configuration
    }

    func generate(
        prompt: String,
        parameters: SamplingParameters,
        treatOutputAsChat: Bool,
        shouldCancel: () -> Bool,
        onToken: (String) -> Void
    ) throws -> InferenceResult {
        let _ = prompt
        let _ = parameters
        let _ = treatOutputAsChat
        let _ = shouldCancel
        let _ = onToken
        throw InferenceError.failedToInitializeBackend
    }
}
#endif
