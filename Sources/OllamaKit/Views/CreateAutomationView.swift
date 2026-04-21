import SwiftUI
import SwiftData
import OllamaCore

struct CreateAutomationView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var inputText = ""
    @State private var isGenerating = false
    @State private var planningPhase: AutomationPlanningPhase = .idle
    @State private var generatedAutomation: ParsedAutomation?
    @State private var rawPlanJSON = ""
    @State private var errorMessage: String?
    @State private var showingError = false

    private let systemPrompt = """
    You are an automation planner.
    Return exactly one JSON object and nothing else.
    Never wrap the JSON in markdown.
    Every step must include service, action, params, and outputKey.
    Use an empty string for outputKey when a step does not expose output.
    Valid services are llm, http, and notify.
    Valid triggerType values are manual, cron, and webhook.
    Use this exact shape:
    {"name": string, "triggerType": "manual"|"cron"|"webhook", "cronSchedule": string|null, "steps": [{"service": "llm"|"http"|"notify", "action": string, "params": {}, "outputKey": string}]}
    """

    var body: some View {
        NavigationStack {
            ZStack {
                AnimatedMeshBackground()

                VStack(spacing: 0) {
                    ScrollView {
                        VStack(spacing: 20) {
                            // Header instruction
                            VStack(spacing: 8) {
                                Image(systemName: "wand.and.stars")
                                    .font(.system(size: 40))
                                    .foregroundStyle(Color.accentColor)

                                Text("Describe Your Automation")
                                    .font(.system(size: 20, weight: .bold))

                                Text("Tell me what you want to automate in plain English. I'll plan the steps for you.")
                                    .font(.system(size: 15))
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                            .padding(.top, 20)

                            // Example prompts
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Try saying:")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.secondary)

                                ForEach(examplePrompts, id: \.self) { example in
                                    Button {
                                        inputText = example
                                    } label: {
                                        Text(example)
                                            .font(.system(size: 14))
                                            .foregroundStyle(.primary)
                                            .padding(.horizontal, 14)
                                            .padding(.vertical, 10)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .background(
                                                RoundedRectangle(cornerRadius: 12)
                                                    .fill(.ultraThinMaterial)
                                            )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 16)

                            if isGenerating {
                                AutomationPlanningProgressCard(phase: planningPhase)
                                    .padding(.horizontal, 16)
                            }

                            // Generated preview
                            if let automation = generatedAutomation {
                                AutomationPreviewCard(
                                    automation: automation,
                                    rawPlanJSON: rawPlanJSON,
                                    errorMessage: errorMessage
                                )
                                    .padding(.horizontal, 16)
                            }
                        }
                        .padding(.bottom, 120)
                    }

                    // Input area
                    VStack(spacing: 0) {
                        Divider()

                        HStack(spacing: 12) {
                            TextField("e.g. remind me to stretch every 30 minutes", text: $inputText, axis: .vertical)
                                .textFieldStyle(.plain)
                                .font(.system(size: 16))
                                .lineLimit(1...4)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                                .background(
                                    RoundedRectangle(cornerRadius: 20)
                                        .fill(.ultraThinMaterial)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 20)
                                                .stroke(.white.opacity(0.1), lineWidth: 0.5)
                                        )
                                )

                            Button {
                                Task { await generateAutomation() }
                            } label: {
                                if isGenerating {
                                    ProgressView()
                                        .frame(width: 32, height: 32)
                                } else {
                                    Image(systemName: "arrow.up.circle.fill")
                                        .font(.system(size: 32))
                                        .foregroundStyle(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.secondary : Color.accentColor)
                                }
                            }
                            .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isGenerating)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }
                    .background(.ultraThinMaterial)
                }
            }
            .navigationTitle("New Automation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }

                if generatedAutomation != nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            saveAutomation()
                        }
                    }
                }
            }
            .alert("Error", isPresented: $showingError) {
                Button("Retry") {
                    Task { await generateAutomation() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "Failed to generate automation")
            }
        }
    }

    private let examplePrompts = [
        "Remind me to stretch every 30 minutes",
        "Check my GitHub notifications daily at 9 AM",
        "Send me a morning weather summary every day",
        "Summarize my chat history and save to notes"
    ]

    @MainActor
    private func generateAutomation() async {
        let prompt = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }

        isGenerating = true
        planningPhase = .generatingPlan
        generatedAutomation = nil
        rawPlanJSON = ""
        errorMessage = nil
        showingError = false

        AppLogStore.shared.record(
            .app,
            title: "Automation Planning Started",
            message: "Generating a new automation plan.",
            metadata: ["prompt_length": "\(prompt.count)"]
        )

        do {
            let content = try await planAutomationWithTimeout(
                prompt: prompt,
                systemPrompt: systemPrompt
            )

            planningPhase = .validatingJSON
            let extractionResult = AutomationPlanParser.extractJSON(from: content)

            switch extractionResult {
            case .success(let jsonData, let strategy):
                rawPlanJSON = String(data: jsonData, encoding: .utf8) ?? ""
                planningPhase = .repairingSchema
                do {
                    let parsed = try JSONDecoder().decode(ParsedAutomation.self, from: jsonData)
                    generatedAutomation = parsed
                    planningPhase = .readyToReview
                    isGenerating = false
                    AppLogStore.shared.record(
                        .app,
                        title: "Automation Plan Ready",
                        message: "Generated automation plan is ready for review.",
                        metadata: [
                            "steps": "\(parsed.steps.count)",
                            "extraction_strategy": strategy.rawValue
                        ],
                        body: rawPlanJSON
                    )
                    HapticManager.impact(.light)
                } catch let decodeError as DecodingError {
                    let errorDetails = detailedDecodingError(decodeError)
                    logAutomationParseFailure(content: content, strategy: "JSONDecoder", error: errorDetails)
                    errorMessage = "Failed to parse automation plan. \(errorDetails)"
                    showingError = true
                    planningPhase = .failed
                    isGenerating = false
                } catch let validationError as AutomationPlanValidationError {
                    let errorDetails = validationError.localizedDescription
                    logAutomationParseFailure(content: content, strategy: "normalization", error: errorDetails)
                    errorMessage = "Failed to parse automation plan. \(errorDetails)"
                    showingError = true
                    planningPhase = .failed
                    isGenerating = false
                } catch {
                    logAutomationParseFailure(content: content, strategy: "JSONDecoder", error: error.localizedDescription)
                    errorMessage = "Failed to parse automation plan: \(error.localizedDescription)"
                    showingError = true
                    planningPhase = .failed
                    isGenerating = false
                }

            case .failure(let extractionError):
                logAutomationParseFailure(content: content, strategy: "extraction", error: extractionError)
                errorMessage = "Failed to parse automation plan. \(extractionError)"
                showingError = true
                planningPhase = .failed
                isGenerating = false
            }
        } catch {
            errorMessage = error.localizedDescription
            showingError = true
            planningPhase = .failed
            isGenerating = false
        }
    }

    /// Converts a DecodingError into a human-readable diagnostic string.
    private func detailedDecodingError(_ error: DecodingError) -> String {
        switch error {
        case .keyNotFound(let key, let context):
            let path = context.codingPath.map { $0.stringValue }.joined(separator: ".")
            return "Missing required field '\(key.stringValue)' at '\(path.isEmpty ? "root" : path)'. Expected type: \(context.debugDescription)"
        case .typeMismatch(let type, let context):
            let path = context.codingPath.map { $0.stringValue }.joined(separator: ".")
            return "Type mismatch at '\(path.isEmpty ? "root" : path)': expected \(type), got \(context.debugDescription)"
        case .valueNotFound(let type, let context):
            let path = context.codingPath.map { $0.stringValue }.joined(separator: ".")
            return "Missing value at '\(path.isEmpty ? "root" : path)': expected \(type)"
        case .dataCorrupted(let context):
            return "Invalid JSON structure: \(context.debugDescription)"
        @unknown default:
            return error.localizedDescription
        }
    }

    /// Logs detailed failure information to AppLogStore for debugging in Settings > Logs.
    private func logAutomationParseFailure(content: String, strategy: String, error: String) {
        AppLogStore.shared.record(
            .app,
            level: .error,
            title: "Automation Plan Parse Failed",
            message: "Failed to parse automation plan using \(strategy).",
            metadata: [
                "extraction_strategy": strategy,
                "error_type": "parse_failure",
                "content_length": "\(content.count)",
                "error_summary": error
            ],
            body: "Raw LLM response (first 2000 chars):\n\(String(content.prefix(2000)))\n\nParse Error: \(error)"
        )
    }

    private func planAutomationWithTimeout(
        prompt: String,
        systemPrompt: String,
        timeoutSeconds: UInt64 = 30
    ) async throws -> String {
        let timeoutNanoseconds = timeoutSeconds * 1_000_000_000

        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await AutomationRunner.shared.planAutomation(
                    prompt: prompt,
                    systemPrompt: systemPrompt
                )
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                throw AutomationPlanningTimeoutError(seconds: Int(timeoutSeconds))
            }

            guard let firstResult = try await group.next() else {
                throw AutomationPlanningTimeoutError(seconds: Int(timeoutSeconds))
            }

            group.cancelAll()
            return firstResult
        }
    }

    private func saveAutomation() {
        guard let automation = generatedAutomation else { return }

        let steps: [AutomationStep] = automation.steps.map { step in
            AutomationStep(
                service: step.service,
                action: step.action,
                params: step.params,
                outputKey: step.outputKey
            )
        }

        let encoder = JSONEncoder()
        let stepsData = (try? encoder.encode(steps)) ?? Data()
        let stepsJSON = String(data: stepsData, encoding: .utf8) ?? "[]"

        let saved = SavedAutomation(
            name: automation.name,
            triggerType: automation.triggerType,
            cronSchedule: automation.cronSchedule,
            stepsJSON: stepsJSON
        )

        modelContext.insert(saved)
        try? modelContext.save()

        Task { @MainActor in
            HapticManager.impact(.medium)
        }

        dismiss()
    }
}

private struct AutomationPlanningTimeoutError: LocalizedError {
    let seconds: Int

    var errorDescription: String? {
        "Automation planning timed out after \(seconds) seconds. Try again or simplify the request."
    }
}

private enum AutomationPlanningPhase {
    case idle
    case generatingPlan
    case validatingJSON
    case repairingSchema
    case readyToReview
    case failed

    var title: String {
        switch self {
        case .idle:
            return "Ready to plan"
        case .generatingPlan:
            return "Generating plan"
        case .validatingJSON:
            return "Validating JSON"
        case .repairingSchema:
            return "Repairing schema"
        case .readyToReview:
            return "Ready to review"
        case .failed:
            return "Planning failed"
        }
    }

    var detail: String {
        switch self {
        case .idle:
            return "Describe an automation in plain English to generate a plan."
        case .generatingPlan:
            return "Running the model and waiting for an automation plan."
        case .validatingJSON:
            return "Checking the planner output for valid JSON."
        case .repairingSchema:
            return "Normalizing missing fields and preparing a reviewable plan."
        case .readyToReview:
            return "The plan is ready to review and save."
        case .failed:
            return "The last attempt did not produce a usable automation."
        }
    }
}

private struct AutomationPlanningProgressCard: View {
    let phase: AutomationPlanningPhase

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ProgressView()
                .controlSize(.regular)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text(phase.title)
                    .font(.system(size: 15, weight: .semibold))
                Text(phase.detail)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(.white.opacity(0.12), lineWidth: 0.6)
                )
        )
    }
}

private enum AutomationPlanValidationError: LocalizedError {
    case missingSteps

    var errorDescription: String? {
        switch self {
        case .missingSteps:
            return "The generated automation did not include any executable steps."
        }
    }
}

private enum AutomationPlanExtractionStrategy: String {
    case markdownCodeBlock = "markdown_code_block"
    case braceExtraction = "brace_extraction"
    case rawJSON = "raw_json"
}

private enum AutomationPlanExtractionResult {
    case success(Data, AutomationPlanExtractionStrategy)
    case failure(String)
}

private enum AutomationPlanParser {
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

private struct ParsedAutomation: Decodable {
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

private struct ParsedStep: Decodable {
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

struct AutomationPreviewCard: View {
    let automation: ParsedAutomation
    let rawPlanJSON: String
    let errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                Text("Automation Plan")
                    .font(.system(size: 16, weight: .semibold))

                Spacer()

                if errorMessage != nil {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Name:")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(automation.name.isEmpty ? "(unnamed)" : automation.name)
                        .font(.system(size: 14))
                }

                HStack {
                    Text("Trigger:")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(automation.triggerType.capitalized)
                        .font(.system(size: 14))
                }

                if let schedule = automation.cronSchedule {
                    HStack {
                        Text("Schedule:")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(schedule)
                            .font(.system(size: 13, design: .monospaced))
                    }
                }
            }

            Divider()

            Text("Steps (\(automation.steps.count))")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)

            ForEach(Array(automation.steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top, spacing: 10) {
                    Text("\(index + 1)")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.accentColor))

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(step.service.uppercased())
                                .font(.system(size: 11, weight: .semibold))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(
                                    Capsule()
                                        .fill(Color.accentColor.opacity(0.2))
                                )
                                .foregroundStyle(Color.accentColor)

                            Text(step.action)
                                .font(.system(size: 13, weight: .medium))
                        }

                        if !step.params.isEmpty {
                            Text(step.params.description)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if !rawPlanJSON.isEmpty {
                Divider()

                DisclosureGroup("Generated JSON") {
                    Text(rawPlanJSON)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 8)
                        .textSelection(.enabled)
                }
                .font(.system(size: 13, weight: .medium))
            }

            if let error = errorMessage {
                Text("Error: \(error)")
                    .font(.system(size: 13))
                    .foregroundStyle(.orange)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.orange.opacity(0.1))
                    )
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(.white.opacity(0.12), lineWidth: 0.6)
                )
        )
    }
}

#Preview {
    CreateAutomationView()
        .modelContainer(for: [SavedAutomation.self], inMemory: true)
}
