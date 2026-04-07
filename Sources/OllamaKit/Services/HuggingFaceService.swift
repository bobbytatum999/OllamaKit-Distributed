import Foundation
import OllamaCore

final class HuggingFaceService: @unchecked Sendable {
    static let shared = HuggingFaceService()

    private struct ActiveDownload {
        let token: UUID
        let task: URLSessionDownloadTask
        let observation: NSKeyValueObservation
    }

    private let baseURLString = "https://huggingface.co/api"
    private let downloadBaseURLString = "https://huggingface.co"
    private let session: URLSession
    private let decoder: JSONDecoder
    private let activeDownloadsLock = NSLock()
    private var activeDownloads: [String: ActiveDownload] = [:]

    private init(session: URLSession = .shared) {
        self.session = session
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        self.decoder = decoder
    }

    func searchModels(query: String, limit: Int = 20) async throws -> [HuggingFaceModel] {
        await MainActor.run {
            AppLogStore.shared.record(
                .huggingFace,
                level: .debug,
                title: "HF Search Started",
                message: "Searching for: \(query)",
                metadata: ["query": query, "limit": "\(limit)"]
            )
        }

        guard let baseURL = URL(string: baseURLString) else {
            throw URLError(.badURL)
        }

        var components = URLComponents(url: baseURL.appendingPathComponent("models"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "search", value: query),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "sort", value: "downloads"),
            URLQueryItem(name: "direction", value: "-1"),
            URLQueryItem(name: "filter", value: "gguf")
        ]

        guard let url = components?.url else {
            throw URLError(.badURL)
        }

        let (data, response) = try await session.data(for: authorizedRequest(url: url))
        try validate(response: response)
        let results = try decoder.decode([HuggingFaceModel].self, from: data)

        await MainActor.run {
            AppLogStore.shared.record(
                .huggingFace,
                level: .info,
                title: "HF Search Completed",
                message: "Found \(results.count) models for: \(query)",
                metadata: ["query": query, "result_count": "\(results.count)"]
            )
        }

        return results
    }

    func getTrendingModels(limit: Int = 20) async throws -> [HuggingFaceModel] {
        await MainActor.run {
            AppLogStore.shared.record(
                .huggingFace,
                level: .debug,
                title: "HF Trending Started",
                message: "Fetching trending models",
                metadata: ["limit": "\(limit)"]
            )
        }

        guard let baseURL = URL(string: baseURLString) else {
            throw URLError(.badURL)
        }

        var components = URLComponents(url: baseURL.appendingPathComponent("models"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "sort", value: "downloads"),
            URLQueryItem(name: "direction", value: "-1"),
            URLQueryItem(name: "filter", value: "gguf")
        ]

        guard let url = components?.url else {
            throw URLError(.badURL)
        }

        let (data, response) = try await session.data(for: authorizedRequest(url: url))
        try validate(response: response)
        let results = try decoder.decode([HuggingFaceModel].self, from: data)

        await MainActor.run {
            AppLogStore.shared.record(
                .huggingFace,
                level: .info,
                title: "HF Trending Completed",
                message: "Found \(results.count) trending models",
                metadata: ["result_count": "\(results.count)"]
            )
        }

        return results
    }

    func searchModelsDetailed(query: String, limit: Int = 20) async throws -> [HuggingFaceModel] {
        let results = try await searchModels(query: query, limit: limit)
        let detailedResults = try await hydrate(models: results)

        await MainActor.run {
            let modelNames = detailedResults.prefix(5).map { $0.displayName }.joined(separator: ", ")
            AppLogStore.shared.record(
                .huggingFace,
                level: .info,
                title: "HF Detailed Search Completed",
                message: "Found \(detailedResults.count) detailed models for: \(query)",
                metadata: ["query": query, "result_count": "\(detailedResults.count)", "first_models": modelNames]
            )
        }

        return detailedResults
    }

    func getModelFiles(modelId: String) async throws -> [GGUFInfo] {
        let url = try repoAPIURL(modelId: modelId, suffix: ["tree", "main"])
        let (data, response) = try await session.data(for: authorizedRequest(url: url))
        try validate(response: response)

        guard let rawFiles = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }

        return rawFiles.compactMap { file in
            guard let path = file["path"] as? String, path.lowercased().hasSuffix(".gguf") else {
                return nil
            }

            let filename = URL(fileURLWithPath: path).lastPathComponent
            guard let downloadURL = try? repoDownloadURL(
                modelId: modelId,
                suffix: ["resolve", "main"] + path.split(separator: "/").map(String.init)
            ) else {
                return nil
            }

            return GGUFInfo(
                url: downloadURL,
                filename: filename,
                size: file["size"] as? Int64 ?? (file["size"] as? NSNumber)?.int64Value,
                quantization: extractQuantization(from: filename)
            )
        }
        .sorted { lhs, rhs in
            (lhs.size ?? 0) < (rhs.size ?? 0)
        }
    }

    func getModelDetails(modelId: String) async throws -> HuggingFaceModel {
        await MainActor.run {
            AppLogStore.shared.record(
                .huggingFace,
                level: .debug,
                title: "HF Model Details Requested",
                message: "Fetching details for: \(modelId)",
                metadata: ["model_id": modelId]
            )
        }

        let url = try repoAPIURL(modelId: modelId)
        let (data, response) = try await session.data(for: authorizedRequest(url: url))
        try validate(response: response)
        return try decoder.decode(HuggingFaceModel.self, from: data)
    }

    func recommendedModels(
        runtimeProfile: DeviceRuntimeProfile,
        limit: Int = 6,
        sourceLimit: Int = 18
    ) async throws -> [HuggingFaceCandidate] {
        let trendingModels = try await getTrendingModels(limit: sourceLimit)
        var candidates: [HuggingFaceCandidate] = []

        for trendingModel in trendingModels {
            do {
                let detailedModel = try await hydratedModel(from: trendingModel)
                guard let candidate = try await bestDownloadCandidate(
                    for: detailedModel,
                    runtimeProfile: runtimeProfile,
                    includeCautionaryModels: false
                ) else {
                    continue
                }

                candidates.append(candidate)
            } catch {
                continue
            }
        }

        return candidates
            .sorted { self.compareCandidates($0, $1) }
            .prefix(limit)
            .map { $0 }
    }

    func resolvePullCandidate(
        requestedName: String,
        requestedFilename: String?,
        runtimeProfile: DeviceRuntimeProfile
    ) async throws -> HuggingFaceCandidate {
        let trimmedName = requestedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw NSError(
                domain: "HuggingFaceService",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "Missing model name."]
            )
        }

        if trimmedName.contains("/") {
            let detailedModel = try await hydratedModel(from: HuggingFaceModel(
                id: trimmedName,
                description: nil,
                downloads: nil,
                likes: nil,
                tags: nil,
                author: nil,
                pipelineTag: nil,
                libraryName: nil,
                gated: nil,
                disabled: nil,
                siblings: nil,
                gguf: nil
            ))

            if let candidate = try await bestDownloadCandidate(
                for: detailedModel,
                requestedFilename: requestedFilename,
                runtimeProfile: runtimeProfile,
                includeCautionaryModels: true
            ) {
                return candidate
            }

            throw NSError(
                domain: "HuggingFaceService",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "No GGUF files were found for \(trimmedName)."]
            )
        }

        let searchResults = try await searchModels(query: trimmedName, limit: 15)
        let detailedResults = try await hydrate(models: searchResults.prefix(10).map { $0 })
        let exactMatches = detailedResults.filter {
            $0.modelId.caseInsensitiveCompare(trimmedName) == .orderedSame
                || $0.displayName.caseInsensitiveCompare(trimmedName) == .orderedSame
        }
        let rankedResults = exactMatches + detailedResults.filter { candidate in
            !exactMatches.contains(where: { $0.modelId == candidate.modelId })
        }

        var candidates: [HuggingFaceCandidate] = []

        for result in rankedResults {
            if let candidate = try await bestDownloadCandidate(
                for: result,
                requestedFilename: requestedFilename,
                runtimeProfile: runtimeProfile,
                includeCautionaryModels: false
            ) {
                candidates.append(candidate)
            }
        }

        if let bestCandidate = candidates.sorted(by: { self.compareCandidates($0, $1) }).first {
            return bestCandidate
        }

        if let blockedModel = rankedResults.first {
            let assessment = blockedModel.repositoryAssessment
            throw NSError(
                domain: "HuggingFaceService",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: assessment.reason]
            )
        }

        throw NSError(
            domain: "HuggingFaceService",
            code: 404,
            userInfo: [NSLocalizedDescriptionKey: "Could not resolve a reliable chat-capable GGUF repository for \(trimmedName)."]
        )
    }

    func downloadModel(
        from url: URL,
        filename: String,
        modelId: String,
        progressHandler: @escaping (DownloadProgress) -> Void
    ) async throws -> DownloadedModel {
        await MainActor.run {
            AppLogStore.shared.record(
                .huggingFace,
                level: .info,
                title: "HF Model Download Started",
                message: "Downloading: \(modelId)",
                metadata: ["model_id": modelId, "file": filename]
            )
        }

        try ModelPathHelper.ensureModelsDirectoryExists()

        var destinationDirectory = ModelPathHelper.modelsDirectoryURL
        for component in modelId.split(separator: "/").map(String.init) {
            destinationDirectory.appendPathComponent(component, isDirectory: true)
        }

        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

        let destinationURL = destinationDirectory.appendingPathComponent(filename)
        let stagedURL = destinationDirectory.appendingPathComponent("\(filename).download-\(UUID().uuidString)")

        progressHandler(DownloadProgress(totalBytes: 0, downloadedBytes: 0, progress: 0, speed: 0))

        do {
            let (temporaryURL, response) = try await download(
                request: authorizedRequest(url: url),
                id: url.absoluteString,
                progressHandler: { progress in
                    Task { @MainActor in
                        AppLogStore.shared.record(
                            .huggingFace,
                            level: .debug,
                            title: "HF Download Progress",
                            message: "Downloading: \(modelId)",
                            metadata: ["model_id": modelId, "bytes_written": "\(progress.downloadedBytes)", "total_bytes": "\(progress.totalBytes)"]
                        )
                    }
                    progressHandler(progress)
                }
            )
            try validate(response: response)
            try Task.checkCancellation()

            try? FileManager.default.removeItem(at: stagedURL)
            try FileManager.default.moveItem(at: temporaryURL, to: stagedURL)

            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }

            try FileManager.default.moveItem(at: stagedURL, to: destinationURL)

            let fileSize = (try FileManager.default.attributesOfItem(atPath: destinationURL.path)[.size] as? NSNumber)?.int64Value ?? 0
            progressHandler(DownloadProgress(totalBytes: fileSize, downloadedBytes: fileSize, progress: 1, speed: 0))

            await MainActor.run {
                AppLogStore.shared.record(
                    .huggingFace,
                    level: .info,
                    title: "HF Model Download Completed",
                    message: "Downloaded: \(modelId)",
                    metadata: ["model_id": modelId, "destination": destinationURL.path, "size_bytes": "\(fileSize)"]
                )
            }

            return DownloadedModel(
                name: filename.replacingOccurrences(of: ".gguf", with: ""),
                modelId: modelId,
                localPath: destinationURL.path,
                size: fileSize,
                downloadDate: .now,
                isDownloaded: true,
                quantization: extractQuantization(from: filename) ?? "GGUF",
                parameters: inferParameterSize(from: filename),
                contextLength: AppSettings.shared.defaultContextLength
            )
        } catch {
            try? FileManager.default.removeItem(at: stagedURL)
            await MainActor.run {
                AppLogStore.shared.record(
                    .huggingFace,
                    level: .error,
                    title: "HF Download Failed",
                    message: "Failed to download \(modelId): \(error.localizedDescription)",
                    metadata: ["model_id": modelId, "error": error.localizedDescription]
                )
            }
            throw error
        }
    }

    func cancelDownload(id: String) {
        await MainActor.run {
            AppLogStore.shared.record(
                .huggingFace,
                level: .warning,
                title: "HF Download Cancelled",
                message: "Download cancelled: \(id)",
                metadata: ["model_id": id]
            )
        }
        activeDownloadsLock.withLock {
            activeDownloads[id]?.task.cancel()
        }
    }

    func getModelInfo(modelId: String) async throws -> ModelInfo {
        let url = try repoAPIURL(modelId: modelId)
        let (data, response) = try await session.data(for: authorizedRequest(url: url))
        try validate(response: response)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }

        return ModelInfo(
            id: json["id"] as? String ?? modelId,
            description: json["description"] as? String,
            tags: json["tags"] as? [String] ?? [],
            downloads: json["downloads"] as? Int ?? 0,
            likes: json["likes"] as? Int ?? 0,
            author: json["author"] as? String
        )
    }

    private func authorizedRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        let token = AppSettings.shared.huggingFaceToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func validate(response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let statusCode = httpResponse.statusCode
            Task { @MainActor in
                AppLogStore.shared.record(
                    .huggingFace,
                    level: .error,
                    title: "HF HTTP Error",
                    message: "HTTP request failed with status: \(statusCode)",
                    metadata: ["status_code": "\(statusCode)"]
                )
            }
            throw NSError(
                domain: "HuggingFaceService",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Hugging Face request failed with status \(httpResponse.statusCode)."]
            )
        }
    }

    private func download(
        request: URLRequest,
        id: String,
        progressHandler: @escaping (DownloadProgress) -> Void
    ) async throws -> (URL, URLResponse) {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(URL, URLResponse), Error>) in
            let downloadToken = UUID()
            let startedAt = Date()
            let task = session.downloadTask(with: request) { [weak self] temporaryURL, response, error in
                var completedDownload: ActiveDownload?
                if let self {
                    completedDownload = self.activeDownloadsLock.withLock { () -> ActiveDownload? in
                        guard let activeDownload = self.activeDownloads[id], activeDownload.token == downloadToken else {
                            return nil
                        }

                        return self.activeDownloads.removeValue(forKey: id)
                    }
                }
                completedDownload?.observation.invalidate()

                if let error {
                    Task { @MainActor in
                        AppLogStore.shared.record(
                            .huggingFace,
                            level: .error,
                            title: "HF Download Failed",
                            message: "Download session failed: \(error.localizedDescription)",
                            metadata: ["model_id": id, "error": error.localizedDescription]
                        )
                    }
                    continuation.resume(throwing: error)
                    return
                }

                guard let temporaryURL, let response else {
                    Task { @MainActor in
                        AppLogStore.shared.record(
                            .huggingFace,
                            level: .debug,
                            title: "HF Download Session Ended",
                            message: "Download session ended for: \(id)",
                            metadata: ["model_id": id]
                        )
                    }
                    continuation.resume(throwing: URLError(.badServerResponse))
                    return
                }

                Task { @MainActor in
                    AppLogStore.shared.record(
                        .huggingFace,
                        level: .debug,
                        title: "HF Download Session Ended",
                        message: "Download session completed for: \(id)",
                        metadata: ["model_id": id]
                    )
                }
                continuation.resume(returning: (temporaryURL, response))
            }

            let observation = task.progress.observe(\.fractionCompleted, options: [.initial, .new]) { progress, _ in
                let totalBytes = max(progress.totalUnitCount, Int64(0))
                let downloadedBytes = max(progress.completedUnitCount, Int64(0))
                let normalizedProgress: Double

                if totalBytes > 0 {
                    normalizedProgress = min(max(Double(downloadedBytes) / Double(totalBytes), 0), 1)
                } else {
                    normalizedProgress = min(max(progress.fractionCompleted, 0), 1)
                }

                let elapsed = max(Date().timeIntervalSince(startedAt), 0.001)
                progressHandler(
                    DownloadProgress(
                        totalBytes: totalBytes,
                        downloadedBytes: downloadedBytes,
                        progress: normalizedProgress,
                        speed: Double(downloadedBytes) / elapsed
                    )
                )
            }

            activeDownloadsLock.withLock {
                if let existingDownload = activeDownloads[id] {
                    existingDownload.task.cancel()
                    existingDownload.observation.invalidate()
                }
                activeDownloads[id] = ActiveDownload(token: downloadToken, task: task, observation: observation)
            }

            task.resume()
        }
    }

    private func extractQuantization(from filename: String) -> String? {
        let patterns = [
            "TURBO4", "TURBO",
            "Q2_K", "Q3_K_S", "Q3_K_M", "Q3_K_L",
            "Q4_0", "Q4_K_S", "Q4_K_M",
            "Q5_0", "Q5_K_S", "Q5_K_M",
            "Q6_K", "Q8_0", "F16", "FP16", "FP32"
        ]

        return patterns.first { filename.localizedCaseInsensitiveContains($0) }
    }

    private func inferParameterSize(from filename: String) -> String {
        let matches = filename.range(of: "\\d+(\\.\\d+)?[Bb]", options: .regularExpression)
        return matches.map { String(filename[$0]) } ?? "Unknown"
    }

    private func repoAPIURL(modelId: String, suffix: [String] = []) throws -> URL {
        guard let baseURL = URL(string: baseURLString) else {
            throw URLError(.badURL)
        }

        var url = baseURL.appendingPathComponent("models")
        for component in modelId.split(separator: "/").map(String.init) + suffix {
            url.appendPathComponent(component)
        }
        return url
    }

    private func repoDownloadURL(modelId: String, suffix: [String]) throws -> URL {
        guard let downloadBaseURL = URL(string: downloadBaseURLString) else {
            throw URLError(.badURL)
        }

        var url = downloadBaseURL
        for component in modelId.split(separator: "/").map(String.init) + suffix {
            url.appendPathComponent(component)
        }
        return url
    }

    private func hydratedModel(from model: HuggingFaceModel) async throws -> HuggingFaceModel {
        if model.pipelineTag != nil || model.gated != nil || model.disabled != nil || model.siblings != nil || model.gguf != nil {
            return model
        }

        return try await getModelDetails(modelId: model.modelId)
    }

    private func hydrate(models: [HuggingFaceModel]) async throws -> [HuggingFaceModel] {
        var hydrated: [HuggingFaceModel] = []
        hydrated.reserveCapacity(models.count)

        for model in models {
            do {
                hydrated.append(try await hydratedModel(from: model))
            } catch {
                hydrated.append(model)
            }
        }

        return hydrated
    }

    private func bestDownloadCandidate(
        for model: HuggingFaceModel,
        requestedFilename: String? = nil,
        runtimeProfile: DeviceRuntimeProfile,
        includeCautionaryModels: Bool
    ) async throws -> HuggingFaceCandidate? {
        let assessment = model.repositoryAssessment
        if !includeCautionaryModels && !assessment.isResolutionEligible {
            return nil
        }
        if includeCautionaryModels && assessment.disposition == .blocked {
            return nil
        }

        let files = try await getModelFiles(modelId: model.modelId)
        guard !files.isEmpty else { return nil }

        let selectedFiles: [GGUFInfo]
        if let requestedFilename = requestedFilename?.trimmingCharacters(in: .whitespacesAndNewlines), !requestedFilename.isEmpty {
            selectedFiles = files.filter { $0.filename.caseInsensitiveCompare(requestedFilename) == .orderedSame }
        } else {
            selectedFiles = files
        }

        guard !selectedFiles.isEmpty else { return nil }

        return selectedFiles
            .compactMap { file -> HuggingFaceCandidate? in
                let compatibility = compatibilityReport(for: file.size, runtimeProfile: runtimeProfile)
                if !includeCautionaryModels && compatibility.level == .unavailable {
                    return nil
                }

                return HuggingFaceCandidate(
                    model: model,
                    file: file,
                    assessment: assessment,
                    compatibility: compatibility
                )
            }
            .sorted { self.compareCandidates($0, $1) }
            .first
    }

    private func compareCandidates(_ lhs: HuggingFaceCandidate, _ rhs: HuggingFaceCandidate) -> Bool {
        let lhsDispositionRank = dispositionRank(lhs.assessment.disposition)
        let rhsDispositionRank = dispositionRank(rhs.assessment.disposition)
        if lhsDispositionRank != rhsDispositionRank {
            return lhsDispositionRank < rhsDispositionRank
        }

        let lhsCompatibilityRank = compatibilityRank(lhs.compatibility.level)
        let rhsCompatibilityRank = compatibilityRank(rhs.compatibility.level)
        if lhsCompatibilityRank != rhsCompatibilityRank {
            return lhsCompatibilityRank < rhsCompatibilityRank
        }

        let lhsQuantizationRank = quantizationRank(for: lhs.file.quantization)
        let rhsQuantizationRank = quantizationRank(for: rhs.file.quantization)
        if lhsQuantizationRank != rhsQuantizationRank {
            return lhsQuantizationRank < rhsQuantizationRank
        }

        let lhsSize = lhs.file.size ?? .max
        let rhsSize = rhs.file.size ?? .max
        if lhsSize != rhsSize {
            return lhsSize < rhsSize
        }

        if lhs.model.downloads != rhs.model.downloads {
            return (lhs.model.downloads ?? 0) > (rhs.model.downloads ?? 0)
        }

        return lhs.model.modelId.localizedCaseInsensitiveCompare(rhs.model.modelId) == .orderedAscending
    }

    private func dispositionRank(_ disposition: HuggingFaceRepositoryDisposition) -> Int {
        switch disposition {
        case .recommended:
            return 0
        case .caution:
            return 1
        case .blocked:
            return 2
        }
    }

    private func compatibilityRank(_ level: ModelCompatibilityLevel) -> Int {
        switch level {
        case .recommended:
            return 0
        case .supported:
            return 1
        case .unknown:
            return 2
        case .unavailable:
            return 3
        }
    }

    private func quantizationRank(for quantization: String?) -> Int {
        switch quantization?.uppercased() {
        case "TURBO4", "TURBO":
            return 0
        case "Q4_K_M", "Q4_K_S", "Q4_0":
            return 1
        case "Q5_K_M", "Q5_K_S", "Q5_0", "Q6_K":
            return 2
        case "Q3_K_M", "Q3_K_S", "Q3_K_L", "Q2_K":
            return 3
        case "Q8_0", "F16", "FP16", "FP32":
            return 4
        default:
            return 5
        }
    }

    private func compatibilityReport(
        for sizeBytes: Int64?,
        runtimeProfile: DeviceRuntimeProfile
    ) -> CompatibilityReport {
        guard let sizeBytes, sizeBytes > 0 else {
            return CompatibilityReport(
                backendKind: .ggufLlama,
                level: .unknown,
                title: "Unknown Size",
                message: "This GGUF file has no size metadata yet."
            )
        }

        if sizeBytes <= runtimeProfile.recommendedGGUFBudgetBytes {
            return CompatibilityReport(
                backendKind: .ggufLlama,
                level: .recommended,
                title: "Recommended",
                message: "This GGUF file is within the recommended budget for \(runtimeProfile.deviceLabel)."
            )
        }

        if sizeBytes <= runtimeProfile.supportedGGUFBudgetBytes {
            return CompatibilityReport(
                backendKind: .ggufLlama,
                level: .supported,
                title: "May Run",
                message: "This GGUF file is larger than recommended for \(runtimeProfile.deviceLabel), but it still has a realistic chance of loading."
            )
        }

        return CompatibilityReport(
            backendKind: .ggufLlama,
            level: .unavailable,
            title: "Too Large",
            message: "This GGUF file is above the likely working size for \(runtimeProfile.deviceLabel)."
        )
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

struct DownloadProgress {
    let totalBytes: Int64
    let downloadedBytes: Int64
    let progress: Double
    let speed: Double

    var formattedTotal: String {
        ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }

    var formattedDownloaded: String {
        ByteCountFormatter.string(fromByteCount: downloadedBytes, countStyle: .file)
    }

    var formattedSpeed: String {
        "\(ByteCountFormatter.string(fromByteCount: Int64(speed), countStyle: .file))/s"
    }

    var percentage: Int {
        Int(progress * 100)
    }
}

struct ModelInfo {
    let id: String
    let description: String?
    let tags: [String]
    let downloads: Int
    let likes: Int
    let author: String?
}
