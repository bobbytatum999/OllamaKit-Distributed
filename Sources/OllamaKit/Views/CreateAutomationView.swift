import SwiftUI
import SwiftData
import OllamaCore

struct CreateAutomationView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var inputText = ""
    @State private var isGenerating = false
    @State private var generatedAutomation: ParsedAutomation?
    @State private var errorMessage: String?
    @State private var showingError = false

    private let systemPrompt = "You are an automation planner. Respond ONLY with valid JSON. No markdown, no explanation, just the raw JSON object with this exact structure: {\"name\": string, \"triggerType\": \"manual\"|\"cron\"|\"webhook\", \"cronSchedule\": string|null, \"steps\": [{\"service\": \"llm\"|\"http\"|\"notify\", \"action\": string, \"params\": {}, \"outputKey\": string}]}"

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

                            // Generated preview
                            if let automation = generatedAutomation {
                                AutomationPreviewCard(automation: automation, errorMessage: errorMessage)
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

    private func generateAutomation() async {
        let prompt = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }

        isGenerating = true
        generatedAutomation = nil
        errorMessage = nil

        do {
            let content = try await AutomationRunner.shared.planAutomation(
                prompt: prompt,
                systemPrompt: systemPrompt
            )

            // Try multiple strategies to extract valid JSON from the LLM response
            let extractionResult = extractJSON(from: content)

            switch extractionResult {
            case .success(let jsonData):
                do {
                    let parsed = try JSONDecoder().decode(ParsedAutomation.self, from: jsonData)
                    await MainActor.run {
                        generatedAutomation = parsed
                        isGenerating = false
                        HapticManager.impact(.light)
                    }
                } catch let decodeError as DecodingError {
                    // Detailed decoding error - log everything for debugging
                    let errorDetails = detailedDecodingError(decodeError)
                    await MainActor.run {
                        logAutomationParseFailure(content: content, strategy: "JSONDecoder", error: errorDetails)
                        errorMessage = "Failed to parse automation plan. \(errorDetails)"
                        showingError = true
                        isGenerating = false
                    }
                } catch {
                    await MainActor.run {
                        logAutomationParseFailure(content: content, strategy: "JSONDecoder", error: error.localizedDescription)
                        errorMessage = "Failed to parse automation plan: \(error.localizedDescription)"
                        showingError = true
                        isGenerating = false
                    }
                }

            case .failure(let extractionError):
                await MainActor.run {
                    logAutomationParseFailure(content: content, strategy: "extraction", error: extractionError)
                    errorMessage = "Failed to parse automation plan. \(extractionError)"
                    showingError = true
                    isGenerating = false
                }
            }
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
                showingError = true
                isGenerating = false
            }
        }
    }

    // MARK: - JSON Extraction

    private enum JSONExtractionResult {
        case success(Data)
        case failure(String)
    }

    /// Attempts to extract valid JSON from an LLM response using multiple strategies.
    private func extractJSON(from content: String) -> JSONExtractionResult {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strategy 1: Strip markdown code block with language tag (e.g. ```json ... ```)
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
            if let data = withoutOpening.data(using: .utf8),
               JSONSerialization.isValidJSONObject(try? JSONSerialization.jsonObject(with: data)) {
                return .success(data)
            }
        }

        // Strategy 2: Find the first '{' and last '}' to handle text around JSON
        if let firstBrace = trimmed.firstIndex(of: "{"),
           let lastBrace = trimmed.lastIndex(of: "}") {
            let potentialJSON = String(trimmed[firstBrace...lastBrace])
            if let data = potentialJSON.data(using: .utf8),
               JSONSerialization.isValidJSONObject(try? JSONSerialization.jsonObject(with: data)) {
                return .success(data)
            }
        }

        // Strategy 3: Try the raw trimmed content as-is
        if let data = trimmed.data(using: .utf8),
           JSONSerialization.isValidJSONObject(try? JSONSerialization.jsonObject(with: data)) {
            return .success(data)
        }

        return .failure("The model response did not contain valid JSON. Tried: markdown code block stripping, brace extraction, and raw parsing.")
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

    private func saveAutomation() {
        guard let automation = generatedAutomation else { return }

        let steps: [AutomationCoreStep] = automation.steps.map { step in
            AutomationCoreStep(
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

// Rename to avoid conflict with the one in AppModels.swift
public struct AutomationCoreStep: Codable, Identifiable {
    public var id: String
    public var service: String
    public var action: String
    public var params: [String: String]
    public var outputKey: String

    public init(id: String = UUID().uuidString, service: String, action: String, params: [String: String] = [:], outputKey: String = "") {
        self.id = id
        self.service = service
        self.action = action
        self.params = params
        self.outputKey = outputKey
    }
}

struct ParsedAutomation: Codable {
    let name: String
    let triggerType: String
    let cronSchedule: String?
    let steps: [ParsedStep]

    enum CodingKeys: String, CodingKey {
        case name, triggerType, cronSchedule, steps
    }
}

struct ParsedStep: Codable {
    let service: String
    let action: String
    let params: [String: String]
    let outputKey: String
}

struct AutomationPreviewCard: View {
    let automation: ParsedAutomation
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
