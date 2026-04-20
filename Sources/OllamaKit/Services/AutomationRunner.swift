import Foundation
import UserNotifications
import OllamaKit

// NO_REPLY (this is just a marker for me to find where to remove the old AnyCodable definition)

enum AutomationError: LocalizedError {
    case connectionFailed(host: String, port: Int)
    case serverNotEnabled
    case modelNotFound

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let host, let port):
            return "Could not connect to Ollama server at \(host):\(port). Make sure Ollama is running and the server is enabled in Settings."
        case .serverNotEnabled:
            return "Ollama server is not enabled. Enable it in Settings → Server."
        case .modelNotFound:
            return "No model available. Download a model first."
        }
    }
}

actor AutomationRunner {
    static let shared = AutomationRunner()

    private init() {}

    func planAutomation(prompt: String, systemPrompt: String) async throws -> String {
        try await generateLLMResponse(
            prompt: prompt,
            systemPrompt: systemPrompt,
            requestedModelID: nil
        )
    }

    func run(_ automation: SavedAutomation) async throws -> String {
        guard let steps = try? JSONDecoder().decode([AutomationStep].self, from: Data(automation.stepsJSON.utf8)) else {
            return "Failed to parse steps"
        }

        var context: [String: String] = [:]
        var results: [String] = []

        for step in steps {
            let result = try await executeStep(step, context: context)
            if !step.outputKey.isEmpty {
                context[step.outputKey] = result
            }
            results.append("[\(step.service)] \(step.action): \(String(result.prefix(200)))")
        }

        return results.joined(separator: "\n")
    }

    private func executeStep(_ step: AutomationStep, context: [String: String]) async throws -> String {
        switch step.service {
        case "llm":
            return try await runLLMStep(step, context: context)
        case "http":
            return try await runHTTPStep(step, context: context)
        case "notify":
            return try await runNotifyStep(step, context: context)
        default:
            return "Unknown service: \(step.service)"
        }
    }

    private func runLLMStep(_ step: AutomationStep, context: [String: String]) async throws -> String {
        let prompt = interpolate(step.params["prompt"] ?? "", context: context)
        let systemPrompt = interpolateOptional(step.params["system"], context: context)
        let requestedModelID = step.params["model"]?.trimmedForLookup.nonEmpty

        return try await generateLLMResponse(
            prompt: prompt,
            systemPrompt: systemPrompt,
            requestedModelID: requestedModelID
        )
    }

    private func runHTTPStep(_ step: AutomationStep, context: [String: String]) async throws -> String {
        guard let urlString = step.params["url"], let url = URL(string: urlString) else {
            return "Invalid URL"
        }

        var request = URLRequest(url: url)
        request.httpMethod = step.params["method"] ?? "GET"
        if let body = step.params["body"] {
            var interpolatedBody = body
            for (key, value) in context {
                interpolatedBody = interpolatedBody.replacingOccurrences(of: "{{\(key)}}", with: value)
            }
            request.httpBody = interpolatedBody.data(using: .utf8)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, _) = try await URLSession.shared.data(for: request)
        let responseStr = String(data: data, encoding: .utf8) ?? "No response"
        return String(responseStr.prefix(500))
    }

    private func runNotifyStep(_ step: AutomationStep, context: [String: String]) async throws -> String {
        let center = UNUserNotificationCenter.current()
        let granted = try await center.requestAuthorization(options: [.alert, .sound])
        guard granted else { return "Notification permission denied" }

        var body = step.params["body"] ?? ""
        for (key, value) in context {
            body = body.replacingOccurrences(of: "{{\(key)}}", with: value)
        }

        let content = UNMutableNotificationContent()
        content.title = step.params["title"] ?? "OllamaKit"
        content.body = body

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger)
        try await center.add(request)

        return "Notification sent"
    }

    private func generateLLMResponse(
        prompt: String,
        systemPrompt: String?,
        requestedModelID: String?
    ) async throws -> String {
        let targetModel = try await resolveModel(preferredModelID: requestedModelID)

        if ModelRunner.shared.activeCatalogId != targetModel.catalogId {
            try await ModelRunner.shared.loadModel(
                catalogId: targetModel.catalogId,
                contextLength: targetModel.runtimeContextLength
            )
        }

        var responseText = ""
        var parameters = await MainActor.run { SamplingParameters.appDefault }
        parameters.maxTokens = max(parameters.maxTokens, 1024)

        _ = try await ModelRunner.shared.generate(
            prompt: prompt,
            systemPrompt: systemPrompt,
            parameters: parameters
        ) { token in
            responseText += token
        }

        let trimmed = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "No response" : trimmed
    }

    private func resolveModel(preferredModelID: String?) async throws -> ModelSnapshot {
        var selection = await MainActor.run {
            BuiltInModelCatalog.selectionModels(downloadedModels: ModelStorage.shared.selectionSnapshots)
        }

        if selection.isEmpty {
            await ModelStorage.shared.refresh()
            selection = await MainActor.run {
                BuiltInModelCatalog.selectionModels(downloadedModels: ModelStorage.shared.selectionSnapshots)
            }
        }

        if let preferredModelID = preferredModelID?.trimmedForLookup.nonEmpty,
           let model = ModelSnapshot.resolveStoredReference(preferredModelID, in: selection) {
            return model
        }

        if let activeCatalogId = ModelRunner.shared.activeCatalogId,
           let model = ModelSnapshot.resolveStoredReference(activeCatalogId, in: selection) {
            return model
        }

        if let defaultModelID = await MainActor.run({ AppSettings.shared.defaultModelId.nonEmpty }),
           let model = ModelSnapshot.resolveStoredReference(defaultModelID, in: selection) {
            return model
        }

        if let installedModel = selection.first(where: { !$0.isBuiltInAppleModel }) {
            return installedModel
        }

        if let fallbackModel = selection.first {
            return fallbackModel
        }

        throw AutomationError.modelNotFound
    }

    private func interpolate(_ template: String, context: [String: String]) -> String {
        var result = template
        for (key, value) in context {
            result = result.replacingOccurrences(of: "{{\(key)}}", with: value)
        }
        return result
    }

    private func interpolateOptional(_ template: String?, context: [String: String]) -> String? {
        guard let template else { return nil }
        let interpolated = interpolate(template, context: context)
        return interpolated.trimmedForLookup.isEmpty ? nil : interpolated
    }
}
