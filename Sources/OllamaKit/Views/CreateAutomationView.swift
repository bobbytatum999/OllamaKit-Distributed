import SwiftUI
import SwiftData

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
            let body: [String: Any] = [
                "model": "llama3.2",
                "messages": [
                    ["role": "system", "content": systemPrompt],
                    ["role": "user", "content": prompt]
                ],
                "stream": false
            ]

            guard let url = URL(string: "\(AppSettings.shared.localServerURL)/api/chat") else {
                errorMessage = "Invalid server URL"
                showingError = true
                isGenerating = false
                return
            }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.timeoutInterval = 30

            let (data, _) = try await URLSession.shared.data(for: request)
            let response = try JSONDecoder().decode([String: AnyCodable].self, from: data)
            let content = (response["message"] as? [String: AnyCodable])?["content"]?.value as? String ?? ""

            // Clean the response - strip markdown code blocks if present
            var jsonString = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if jsonString.hasPrefix("```") {
                // Strip markdown code block
                if let firstNewline = jsonString.firstIndex(of: "\n") {
                    jsonString = String(jsonString[jsonString.index(after: firstNewline)...])
                }
            }
            if jsonString.hasSuffix("```") {
                jsonString = String(jsonString.dropLast(3))
            }
            jsonString = jsonString.trimmingCharacters(in: .whitespacesAndNewlines)

            guard let jsonData = jsonString.data(using: .utf8),
                  let parsed = try? JSONDecoder().decode(ParsedAutomation.self, from: jsonData) else {
                await MainActor.run {
                    errorMessage = "Failed to parse automation plan. The model returned an unexpected format."
                    showingError = true
                    isGenerating = false
                }
                return
            }

            await MainActor.run {
                generatedAutomation = parsed
                isGenerating = false
                HapticManager.impact(.light)
            }
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
                showingError = true
                isGenerating = false
            }
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
            HapticManager.notification(.success)
        }

        dismiss()
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
