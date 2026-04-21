import Foundation
import OllamaCore

enum AutomationPlanValidationError: LocalizedError {
    case missingSteps

    var errorDescription: String? {
        switch self {
        case .missingSteps:
            return "The generated automation did not include any executable steps."
        }
    }
}

enum AutomationPlanExtractionStrategy: String {
    case markdownCodeBlock = "markdown_code_block"
    case braceExtraction = "brace_extraction"
    case rawJSON = "raw_json"
}

enum AutomationPlanExtractionResult {
    case success(Data, AutomationPlanExtractionStrategy)
    case failure(String)
}

enum AutomationPlanParser {
    static func extractJSON(from content: String) -> AutomationPlanExtractionResult {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.hasPrefix("```") {
            var withoutOpening = trimmed
            if let firstNewline = withoutOpening.firstIndex(of: "\n") {
                withoutOpening = String(withoutOpening[withoutOpening.index(after: firstNewline)...])
            }
            withoutOpening = withoutOpening.trimmingCharacters(in: .whitespacesAndNewlines)
            if withoutOpening.hasSuffix("```") {
                withoutOpening = String(withoutOpening.dropLast(3))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let data = validatedJSONData(from: withoutOpening) {
                return .success(data, .markdownCodeBlock)
            }
        }

        if let firstBrace = trimmed.firstIndex(of: "{"),
           let lastBrace = trimmed.lastIndex(of: "}") {
            let candidate = String(trimmed[firstBrace...lastBrace])
            if let data = validatedJSONData(from: candidate) {
                return .success(data, .braceExtraction)
            }
        }

        if let data = validatedJSONData(from: trimmed) {
            return .success(data, .rawJSON)
        }

        return .failure("The model response did not contain valid JSON. Tried: markdown code block stripping, brace extraction, and raw parsing.")
    }

    private static func validatedJSONData(from string: String) -> Data? {
        guard let data = string.data(using: .utf8) else { return nil }
        do {
            _ = try JSONSerialization.jsonObject(with: data)
            return data
        } catch {
            return nil
        }
    }
}

struct ParsedAutomation: Decodable {
    let name: String
    let triggerType: String
    let cronSchedule: String?
    let steps: [ParsedStep]

    enum CodingKeys: String, CodingKey {
        case name
        case triggerType
        case cronSchedule
        case steps
    }

    init(name: String, triggerType: String, cronSchedule: String?, steps: [ParsedStep]) {
        self.name = name
        self.triggerType = triggerType
        self.cronSchedule = cronSchedule
        self.steps = steps
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let name = try container.decodeIfPresent(String.self, forKey: .name)?.trimmedForLookup.nonEmpty ?? "New Automation"
        let triggerType = Self.normalizeTriggerType(
            try container.decodeIfPresent(String.self, forKey: .triggerType)
        )
        let cronSchedule = try container.decodeIfPresent(String.self, forKey: .cronSchedule)?.trimmedForLookup.nonEmpty
        let decodedSteps = try container.decodeIfPresent([ParsedStep].self, forKey: .steps) ?? []
        let normalizedSteps = decodedSteps.enumerated().map { index, step in
            step.normalized(fallbackIndex: index)
        }

        guard !normalizedSteps.isEmpty else {
            throw AutomationPlanValidationError.missingSteps
        }

        self.init(
            name: name,
            triggerType: triggerType,
            cronSchedule: cronSchedule,
            steps: normalizedSteps
        )
    }

    private static func normalizeTriggerType(_ rawValue: String?) -> String {
        switch rawValue?.trimmedForLookup.lowercased() {
        case "cron", "schedule", "scheduled":
            return "cron"
        case "webhook", "http":
            return "webhook"
        default:
            return "manual"
        }
    }
}

struct ParsedStep: Decodable {
    let service: String
    let action: String
    let params: [String: String]
    let outputKey: String

    enum CodingKeys: String, CodingKey {
        case service
        case action
        case params
        case outputKey
    }

    init(service: String, action: String, params: [String: String], outputKey: String) {
        self.service = service
        self.action = action
        self.params = params
        self.outputKey = outputKey
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let service = Self.normalizeService(
            try container.decodeIfPresent(String.self, forKey: .service)
        )
        let action = try container.decodeIfPresent(String.self, forKey: .action)?.trimmedForLookup.nonEmpty
            ?? Self.defaultAction(for: service)
        let rawParams = try container.decodeIfPresent([String: FlexibleStringValue].self, forKey: .params) ?? [:]
        let params = rawParams.reduce(into: [String: String]()) { partialResult, entry in
            let key = entry.key.trimmedForLookup
            guard !key.isEmpty else { return }
            partialResult[key] = entry.value.stringValue
        }
        let outputKey = try container.decodeIfPresent(String.self, forKey: .outputKey)?.trimmedForLookup ?? ""

        self.init(service: service, action: action, params: params, outputKey: outputKey)
    }

    func normalized(fallbackIndex: Int) -> ParsedStep {
        ParsedStep(
            service: service,
            action: action,
            params: params,
            outputKey: outputKey.nonEmpty ?? Self.defaultOutputKey(
                for: service,
                action: action,
                fallbackIndex: fallbackIndex
            )
        )
    }

    private static func normalizeService(_ rawValue: String?) -> String {
        switch rawValue?.trimmedForLookup.lowercased() {
        case "http", "web", "fetch", "request":
            return "http"
        case "notify", "notification", "reminder", "alert":
            return "notify"
        default:
            return "llm"
        }
    }

    private static func defaultAction(for service: String) -> String {
        switch service {
        case "http":
            return "request"
        case "notify":
            return "notify"
        default:
            return "generate"
        }
    }

    private static func defaultOutputKey(for service: String, action: String, fallbackIndex: Int) -> String {
        guard service != "notify" else { return "" }

        let sanitizedAction = action
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .joined(separator: "_")
            .trimmedForLookup
            .lowercased()

        let base = sanitizedAction.nonEmpty ?? "\(service)_step"
        return "\(base)_result_\(fallbackIndex + 1)"
    }
}

private enum FlexibleStringValue: Decodable {
    case string(String)
    case integer(Int)
    case double(Double)
    case boolean(Bool)
    case object([String: FlexibleStringValue])
    case array([FlexibleStringValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Int.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else if let value = try? container.decode([String: FlexibleStringValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([FlexibleStringValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported parameter value.")
        }
    }

    var stringValue: String {
        switch self {
        case .string(let value):
            return value
        case .integer(let value):
            return String(value)
        case .double(let value):
            return String(value)
        case .boolean(let value):
            return value ? "true" : "false"
        case .null:
            return ""
        case .object, .array:
            return serializedJSONString()
        }
    }

    private func serializedJSONString() -> String {
        let object: Any
        switch self {
        case .object(let value):
            object = value.mapValues(\.jsonObject)
        case .array(let value):
            object = value.map(\.jsonObject)
        default:
            return stringValue
        }

        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return ""
        }

        return string
    }

    private var jsonObject: Any {
        switch self {
        case .string(let value):
            return value
        case .integer(let value):
            return value
        case .double(let value):
            return value
        case .boolean(let value):
            return value
        case .object(let value):
            return value.mapValues(\.jsonObject)
        case .array(let value):
            return value.map(\.jsonObject)
        case .null:
            return NSNull()
        }
    }
}
