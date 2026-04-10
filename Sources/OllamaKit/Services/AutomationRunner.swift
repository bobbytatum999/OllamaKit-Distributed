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
        let serverSettings = await MainActor.run { () -> (enabled: Bool, url: String, port: Int) in
            let settings = AppSettings.shared
            return (settings.serverEnabled, settings.localServerURL, settings.serverPort)
        }

        guard serverSettings.enabled else {
            throw AutomationError.serverNotEnabled
        }

        // Get active model
        guard let tagsURL = URL(string: "\(serverSettings.url)/api/tags") else {
            throw AutomationError.connectionFailed(host: "localhost", port: serverSettings.port)
        }
        let (tagsData, tagsResponse) = try await URLSession.shared.data(from: tagsURL)
        guard (tagsResponse as? HTTPURLResponse)?.statusCode == 200 else {
            throw AutomationError.connectionFailed(host: "localhost", port: serverSettings.port)
        }
        let tagsResult = try JSONDecoder().decode([String: [AnyAutomationCodable]].self, from: tagsData)
        
        let modelsWrapper = tagsResult["models"]?.value as? [[String: AnyAutomationCodable]]
        guard let models = modelsWrapper,
              let firstModel = models.first,
              let modelName = firstModel["name"]?.value as? String else {
            throw AutomationError.modelNotFound
        }

        // Interpolate context into prompt
        var prompt = step.params["prompt"] ?? ""
        for (key, value) in context {
            prompt = prompt.replacingOccurrences(of: "{{\(key)}}", with: value)
        }

        let body: [String: Any] = [
            "model": modelName,
            "messages": [["role": "user", "content": prompt]],
            "stream": false
        ]

        guard let chatURL = URL(string: "\(serverSettings.url)/api/chat") else {
            throw AutomationError.connectionFailed(host: "localhost", port: serverSettings.port)
        }
        var request = URLRequest(url: chatURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, chatResponse) = try await URLSession.shared.data(for: request)
        guard (chatResponse as? HTTPURLResponse)?.statusCode == 200 else {
            throw AutomationError.connectionFailed(host: "localhost", port: serverSettings.port)
        }
        let response = try JSONDecoder().decode([String: AnyAutomationCodable].self, from: data)
        let messageDict = response["message"]?.value as? [String: AnyAutomationCodable]
        return messageDict?["content"]?.value as? String ?? "No response"
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
}
