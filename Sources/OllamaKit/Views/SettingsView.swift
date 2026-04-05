import SwiftUI
import SwiftData
import OllamaCore

private let huggingFaceTokensURL = URL(string: "https://huggingface.co/settings/tokens")
private let githubHomepageURL = URL(string: "https://github.com")
private let huggingFaceHomepageURL = URL(string: "https://huggingface.co")

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var showingResetConfirmation = false
    
    var body: some View {
        ZStack {
            AnimatedMeshBackground()

            ScrollView {
                VStack(spacing: 20) {
                    SurfaceSectionCard(
                        title: "Model Parameters",
                        footer: "Default parameters for model inference. These can be overridden per chat."
                    ) {
                        ModelSettingsSection(settings: settings)
                    }

                    SurfaceSectionCard(
                        title: "Performance",
                        footer: "Adjust based on your device's capabilities. More GPU layers means faster inference but higher memory usage."
                    ) {
                        PerformanceSettingsSection(settings: settings)
                    }

                    SurfaceSectionCard(title: "Memory Management") {
                        MemorySettingsSection(settings: settings)
                    }

                    SurfaceSectionCard(
                        title: "Hugging Face",
                        footer: "Required for accessing gated models and higher rate limits."
                    ) {
                        HuggingFaceSettingsSection(settings: settings)
                    }

                    SurfaceSectionCard(title: "Interface") {
                        InterfaceSettingsSection(settings: settings)
                    }

                    SurfaceSectionCard(
                        title: "App Debug Logs",
                        footer: "Client-side app events only (tab switches, chat send/receive, runtime errors). Server/API logs remain in the Server tab."
                    ) {
                        AppDebugLogsSection()
                    }

                    SurfaceSectionCard(
                        title: "Model Performance",
                        footer: "Recent model load/generation timing samples to help debug slow responses."
                    ) {
                        ModelPerformanceSection()
                    }

                    SurfaceSectionCard(
                        title: "Benchmark",
                        footer: "Runs a quick on-device generation benchmark against a runnable model."
                    ) {
                        BenchmarkSection()
                    }

                    SurfaceSectionCard(title: "Data Management") {
                        DataManagementSection()
                    }

                    SurfaceSectionCard {
                        AboutSection()
                    }

                    SurfaceSectionCard {
                        Button(role: .destructive) {
                            showingResetConfirmation = true
                        } label: {
                            HStack {
                                Spacer()
                                Text("Reset All Settings")
                                Spacer()
                            }
                        }
                        .padding(.vertical, 14)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            }
            .scrollIndicators(.hidden)
        }
        .navigationTitle("Settings")
        .alert("Reset Settings?", isPresented: $showingResetConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) {
                Task {
                    await ServerManager.shared.stopServer()
                    BackgroundTaskManager.shared.cancelScheduledBackgroundTask()
                    ModelRunner.shared.unloadModel()
                    await MainActor.run {
                        settings.resetToDefaults()
                        HapticManager.notification(.success)
                    }
                }
            }
        } message: {
            Text("This will reset all settings to their default values. Your downloaded models and chats will not be affected.")
        }
    }
}

struct ModelSettingsSection: View {
    @ObservedObject var settings: AppSettings
    
    var body: some View {
        VStack(spacing: 0) {
            // Temperature
            ParameterSlider(
                title: "Temperature",
                value: $settings.defaultTemperature,
                range: 0...2,
                step: 0.1,
                description: "Randomness of output"
            )
            
            Divider()
            
            // Top P
            ParameterSlider(
                title: "Top P",
                value: $settings.defaultTopP,
                range: 0...1,
                step: 0.05,
                description: "Nucleus sampling"
            )
            
            Divider()
            
            // Top K
            ParameterStepper(
                title: "Top K",
                value: $settings.defaultTopK,
                range: 1...100,
                description: "Top-k sampling"
            )
            
            Divider()
            
            // Repeat Penalty
            ParameterSlider(
                title: "Repeat Penalty",
                value: $settings.defaultRepeatPenalty,
                range: 0.5...2,
                step: 0.05,
                description: "Penalize repetition"
            )
            
            Divider()
            
            // Context Length
            ParameterStepper(
                title: "Context Length",
                value: $settings.defaultContextLength,
                range: 512...32768,
                step: 512,
                description: "Maximum context tokens"
            )
            
            Divider()
            
            // Max Tokens
            ParameterStepper(
                title: "Max Tokens",
                value: Binding(
                    get: { max(settings.maxTokens, -1) },
                    set: { settings.maxTokens = $0 }
                ),
                range: -1...8192,
                step: 128,
                description: "-1 for unlimited"
            )
        }
    }
}

struct PerformanceSettingsSection: View {
    @ObservedObject var settings: AppSettings
    
    var body: some View {
        VStack(spacing: 0) {
            // Threads
            ParameterStepper(
                title: "CPU Threads",
                value: $settings.threads,
                range: 1...16,
                description: "Number of CPU threads"
            )
            
            Divider()
            
            // Batch Size
            ParameterStepper(
                title: "Batch Size",
                value: $settings.batchSize,
                range: 64...2048,
                step: 64,
                description: "Processing batch size"
            )
            
            Divider()
            
            // GPU Layers
            ParameterStepper(
                title: "GPU Layers",
                value: $settings.gpuLayers,
                range: 0...100,
                description: "Layers to offload to GPU"
            )
            
            Divider()
            
            // Flash Attention
            Toggle(isOn: $settings.flashAttentionEnabled) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Flash Attention")
                        .font(.system(size: 16, weight: .medium))
                    Text("Faster attention mechanism")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 12)
            
            Divider()

            TurboQuantModePickerRow(selection: $settings.turboQuantMode)

            Divider()

            KVCachePickerRow(
                title: "KV Cache Type (K)",
                description: "Key-cache precision for experimental TurboQuant-style tuning",
                selection: $settings.kvCacheTypeK
            )
            .disabled(settings.turboQuantMode != .disabled)

            Divider()

            KVCachePickerRow(
                title: "KV Cache Type (V)",
                description: "Value-cache precision for experimental TurboQuant-style tuning",
                selection: $settings.kvCacheTypeV
            )
            .disabled(settings.turboQuantMode != .disabled)

        }
    }
}

private struct TurboQuantModePickerRow: View {
    @Binding var selection: RuntimePreferences.TurboQuantMode

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("TurboQuant Mode")
                .font(.system(size: 16, weight: .medium))
            Text("Google TurboQuant-inspired KV presets. Balanced/Aggressive override manual K/V selectors.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            Picker("TurboQuant Mode", selection: $selection) {
                ForEach(RuntimePreferences.TurboQuantMode.allCases, id: \.self) { mode in
                    Text(label(for: mode)).tag(mode)
                }
            }
            .pickerStyle(.menu)
        }
        .padding(.vertical, 12)
    }

    private func label(for mode: RuntimePreferences.TurboQuantMode) -> String {
        switch mode {
        case .disabled:
            return "Disabled (Manual)"
        case .googleTurboQuantBalanced:
            return "Google TurboQuant Balanced"
        case .googleTurboQuantAggressive:
            return "Google TurboQuant Aggressive"
        }
    }
}

private struct KVCachePickerRow: View {
    let title: String
    let description: String
    @Binding var selection: RuntimePreferences.KVCacheQuantization

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 16, weight: .medium))
            Text(description)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            Picker(title, selection: $selection) {
                ForEach(RuntimePreferences.KVCacheQuantization.allCases, id: \.self) { option in
                    Text(label(for: option)).tag(option)
                }
            }
            .pickerStyle(.menu)
        }
        .padding(.vertical, 12)
    }

    private func label(for option: RuntimePreferences.KVCacheQuantization) -> String {
        switch option {
        case .float16:
            return "F16"
        case .float32:
            return "F32"
        case .q8_0:
            return "Q8_0"
        case .q6_K:
            return "Q6_K"
        case .q5_0:
            return "Q5_0"
        case .q4_0:
            return "Q4_0"
        }
    }
}

struct MemorySettingsSection: View {
    @ObservedObject var settings: AppSettings
    
    var body: some View {
        VStack(spacing: 0) {
            // mmap
            Toggle(isOn: $settings.mmapEnabled) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Memory Mapping")
                        .font(.system(size: 16, weight: .medium))
                    Text("Map model files to memory")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 12)
            
            Divider()
            
            // mlock
            Toggle(isOn: $settings.mlockEnabled) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Lock Memory")
                        .font(.system(size: 16, weight: .medium))
                    Text("Prevent swapping to disk")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 12)
            
            Divider()
            
            // Keep in memory
            Toggle(isOn: $settings.keepModelInMemory) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Keep Model Loaded")
                        .font(.system(size: 16, weight: .medium))
                    Text("Don't unload after generation")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 12)
            
            if !settings.keepModelInMemory {
                Divider()
                
                // Auto-offload time
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Auto-offload Delay")
                            .font(.system(size: 16, weight: .medium))
                        Text("Minutes before unloading")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    
                    Spacer()
                    
                    HStack(spacing: 4) {
                        Button {
                            if settings.autoOffloadMinutes > 1 {
                                settings.autoOffloadMinutes -= 1
                            }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .font(.system(size: 22))
                                .foregroundStyle(Color.accentColor)
                        }
                        
                        Text("\(settings.autoOffloadMinutes)m")
                            .font(.system(size: 16, weight: .medium, design: .monospaced))
                            .frame(minWidth: 50)
                        
                        Button {
                            if settings.autoOffloadMinutes < 60 {
                                settings.autoOffloadMinutes += 1
                            }
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 22))
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
                .padding(.vertical, 12)
            }
        }
    }
}

struct HuggingFaceSettingsSection: View {
    @ObservedObject var settings: AppSettings
    @State private var showingToken = false
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("API Token")
                        .font(.system(size: 16, weight: .medium))
                    Text("For gated models and rate limits")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                HStack(spacing: 8) {
                    if settings.huggingFaceToken.isEmpty {
                        Text("Not Set")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                    } else {
                        Text(showingToken ? settings.huggingFaceToken : String(repeating: "•", count: min(settings.huggingFaceToken.count, 20)))
                            .font(.system(size: 14, design: .monospaced))
                            .lineLimit(1)
                    }
                    
                    Button {
                        showingToken.toggle()
                    } label: {
                        Image(systemName: showingToken ? "eye.slash" : "eye")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.ultraThinMaterial)
                )
            }
            .padding(.vertical, 12)
            
            Divider()
            
            NavigationLink {
                HuggingFaceTokenEditView(token: $settings.huggingFaceToken)
            } label: {
                HStack {
                    Text(settings.huggingFaceToken.isEmpty ? "Add Token" : "Edit Token")
                        .font(.system(size: 16, weight: .medium))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 12)
        }
    }
}

struct HuggingFaceTokenEditView: View {
    @Binding var token: String
    @Environment(\.dismiss) private var dismiss
    @State private var tempToken: String = ""
    
    var body: some View {
        Form {
            Section {
                TextField("hf_...", text: $tempToken)
                    .font(.system(size: 16, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            } header: {
                Text("Hugging Face Token")
            } footer: {
                Text("Get your token from huggingface.co/settings/tokens")
            }
            
            Section {
                if let huggingFaceTokensURL {
                    Link(destination: huggingFaceTokensURL) {
                        HStack {
                            Text("Get Token")
                            Spacer()
                            Image(systemName: "arrow.up.right.square")
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
            }
        }
        .navigationTitle("API Token")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    token = tempToken
                    dismiss()
                }
            }
        }
        .onAppear {
            tempToken = token
        }
    }
}

struct InterfaceSettingsSection: View {
    @ObservedObject var settings: AppSettings
    
    var body: some View {
        VStack(spacing: 0) {
            Toggle(isOn: $settings.darkMode) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Dark Mode")
                        .font(.system(size: 16, weight: .medium))
                }
            }
            .padding(.vertical, 12)
            
            Divider()
            
            Toggle(isOn: $settings.hapticFeedback) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Haptic Feedback")
                        .font(.system(size: 16, weight: .medium))
                }
            }
            .padding(.vertical, 12)
            
            Divider()
            
            Toggle(isOn: $settings.showTokenCount) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Show Token Count")
                        .font(.system(size: 16, weight: .medium))
                }
            }
            .padding(.vertical, 12)
            
            Divider()
            
            Toggle(isOn: $settings.showGenerationSpeed) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Show Generation Speed")
                        .font(.system(size: 16, weight: .medium))
                }
            }
            .padding(.vertical, 12)
            
            Divider()
            
            Toggle(isOn: $settings.markdownRendering) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Markdown Rendering")
                        .font(.system(size: 16, weight: .medium))
                }
            }
            .padding(.vertical, 12)
            
            Divider()
            
            Toggle(isOn: $settings.streamingEnabled) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Streaming Response")
                        .font(.system(size: 16, weight: .medium))
                    Text("Show tokens as they're generated")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 12)
        }
    }
}

struct DataManagementSection: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var chatSessions: [ChatSession]
    @StateObject private var modelStore = ModelStorage.shared

    @State private var showingClearChatsConfirmation = false
    @State private var showingClearModelsConfirmation = false

    init() {}
    
    var body: some View {
        VStack(spacing: 0) {
            Button {
                showingClearChatsConfirmation = true
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Clear All Chats")
                            .font(.system(size: 16, weight: .medium))
                        Text("Delete all chat history")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    
                    Spacer()
                    
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            .padding(.vertical, 12)
            
            Divider()
            
            Button {
                showingClearModelsConfirmation = true
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Delete All Models")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.red)
                        Text("Remove all imported and downloaded models")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    
                    Spacer()
                    
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            .padding(.vertical, 12)
        }
        .alert("Clear All Chats?", isPresented: $showingClearChatsConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) {
                for session in chatSessions {
                    modelContext.delete(session)
                }
                try? modelContext.save()
            }
        } message: {
            Text("This will permanently delete all your chat history. This action cannot be undone.")
        }
        .alert("Delete All Models?", isPresented: $showingClearModelsConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                Task { @MainActor in
                    await ServerManager.shared.stopServer()
                    BackgroundTaskManager.shared.cancelScheduledBackgroundTask()
                    ModelRunner.shared.unloadModel()
                    await modelStore.deleteAllInstalledModels()
                    AppSettings.shared.defaultModelId = ""
                    HapticManager.notification(.warning)
                }
            }
        } message: {
            Text("This will permanently delete all downloaded and imported models. You'll need to add them again to use them.")
        }
    }
}

struct AppDebugLogsSection: View {
    @ObservedObject private var logStore = AppLogStore.shared

    private var recentEntries: [AppLogEntry] {
        Array(logStore.entries.suffix(60).reversed())
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Recent Events")
                        .font(.system(size: 16, weight: .medium))
                    Text(logStore.persistenceSummary)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Clear") {
                    logStore.clear()
                    HapticManager.impact(.light)
                }
                .font(.system(size: 13, weight: .semibold))
                .buttonStyle(.bordered)
            }
            .padding(.vertical, 12)

            if recentEntries.isEmpty {
                Divider()
                Text("No app debug logs yet.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(recentEntries) { entry in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("[\(entry.category.rawValue)] \(entry.title)")
                                    .font(.system(size: 13, weight: .semibold))
                                Text(entry.message)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                Text(entry.timestamp.formatted(date: .omitted, time: .standard))
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
            }
        }
    }
}

struct ModelPerformanceSection: View {
    @ObservedObject private var performanceStore = ModelPerformanceStore.shared

    private var entries: [ModelPerformanceSample] {
        Array(performanceStore.entries.suffix(40).reversed())
    }

    private var averageTokensPerSecond: Double {
        let samples = entries.filter { $0.phase == .generate && $0.tokensPerSecond > 0 && $0.wasSuccessful }
        guard !samples.isEmpty else { return 0 }
        return samples.reduce(0) { $0 + $1.tokensPerSecond } / Double(samples.count)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Recent Speed Samples")
                        .font(.system(size: 16, weight: .medium))
                    Text(averageTokensPerSecond > 0 ? String(format: "Avg generate speed: %.1f tok/s", averageTokensPerSecond) : "No completed generation samples yet.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Clear") {
                    performanceStore.clear()
                    HapticManager.impact(.light)
                }
                .font(.system(size: 13, weight: .semibold))
                .buttonStyle(.bordered)
            }
            .padding(.vertical, 12)

            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(entries) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("[\(entry.phase.rawValue)] \(entry.modelID)")
                                .font(.system(size: 13, weight: .semibold))
                            Text(
                                entry.phase == .generate
                                ? String(format: "%.1f ms • %d tokens • %.1f tok/s%@", entry.elapsedMs, entry.tokens, entry.tokensPerSecond, entry.wasSuccessful ? "" : " • failed")
                                : String(format: "%.1f ms%@", entry.elapsedMs, entry.wasSuccessful ? "" : " • failed")
                            )
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            if let notes = entry.notes, !notes.isEmpty {
                                Text(notes)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)
        }
    }
}

struct BenchmarkSection: View {
    @State private var isRunning = false
    @State private var status = "Idle"
    @State private var lastResult: String?
    @State private var lastError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Quick Model Benchmark")
                    .font(.system(size: 16, weight: .medium))
                Spacer()
                Button(isRunning ? "Running…" : "Run") {
                    Task { @MainActor in
                        await runBenchmark()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isRunning)
            }

            Text(status)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            if let lastResult {
                Text(lastResult)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            if let lastError {
                Text(lastError)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 12)
    }

    @MainActor
    private func runBenchmark() async {
        isRunning = true
        status = "Refreshing model list…"
        lastError = nil
        lastResult = nil
        defer { isRunning = false }

        await ModelStorage.shared.refresh()
        let candidates = ModelStorage.shared.selectionSnapshots
            .filter { $0.canBeSelectedForChat && $0.isValidatedRunnable }
            .sorted { $0.size < $1.size }
        guard let model = candidates.first else {
            status = "No runnable model available for benchmark."
            return
        }

        let loadStart = CFAbsoluteTimeGetCurrent()
        do {
            status = "Loading \(model.displayName)…"
            let benchmarkContextLength = max(
                min(model.runtimeContextLength, AppSettings.shared.defaultContextLength),
                512
            )
            try await ModelRunner.shared.loadModel(
                catalogId: model.catalogId,
                contextLength: benchmarkContextLength,
                gpuLayers: AppSettings.shared.gpuLayers
            )
            let loadMs = (CFAbsoluteTimeGetCurrent() - loadStart) * 1000

            status = "Generating benchmark response…"
            let result = try await ModelRunner.shared.generate(
                prompt: "Write a concise benchmark response.",
                parameters: SamplingParameters(
                    temperature: 0.2,
                    topP: 0.9,
                    topK: 40,
                    repeatPenalty: 1.05,
                    repeatLastN: 64,
                    maxTokens: 96
                )
            ) { _ in }

            let tokPerSec = result.generationTime > 0 ? Double(result.tokensGenerated) / result.generationTime : 0
            status = "Benchmark completed."
            lastResult = String(
                format: "%@ • load %.0f ms • %d tokens in %.2f s • %.1f tok/s",
                model.displayName,
                loadMs,
                result.tokensGenerated,
                result.generationTime,
                tokPerSec
            )
            AppLogStore.shared.record(
                .runtime,
                title: "Benchmark Completed",
                message: "Settings benchmark finished.",
                metadata: [
                    "model": model.displayName,
                    "load_ms": String(format: "%.0f", loadMs),
                    "tokens": String(result.tokensGenerated),
                    "generation_seconds": String(format: "%.2f", result.generationTime),
                    "tok_per_sec": String(format: "%.1f", tokPerSec)
                ]
            )
        } catch {
            status = "Benchmark failed."
            lastError = error.localizedDescription
            AppLogStore.shared.record(
                .error,
                level: .error,
                title: "Benchmark Failed",
                message: error.localizedDescription
            )
        }
    }
}

struct AboutSection: View {
    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Spacer()
                
                VStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 24)
                            .fill(
                                LinearGradient(
                                    colors: [.purple.opacity(0.3), .blue.opacity(0.3)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 100, height: 100)
                        
                        Image(systemName: "cube.box.fill")
                            .font(.system(size: 50))
                            .foregroundStyle(.white)
                    }
                    
                    VStack(spacing: 4) {
                        Text("OllamaKit")
                            .font(.system(size: 24, weight: .bold))
                        
                        Text("Version 1.0.0")
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                    }
                }
                
                Spacer()
            }
            
            Text("Manage local GGUF models, chat sessions, and a local API server. On-device inference is powered by a linked llama.cpp runtime in the app build.")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            
            HStack(spacing: 20) {
                if let githubHomepageURL {
                    Link(destination: githubHomepageURL) {
                        Image(systemName: "link")
                            .font(.system(size: 24))
                    }
                }
                
                if let huggingFaceHomepageURL {
                    Link(destination: huggingFaceHomepageURL) {
                        Image(systemName: "globe")
                            .font(.system(size: 24))
                    }
                }
            }
            .foregroundStyle(Color.accentColor)
        }
        .padding(20)
    }
}

// MARK: - Reusable Components

struct ParameterSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let description: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 16, weight: .medium))
                    Text(description)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                Text(String(format: "%.2f", value))
                    .font(.system(size: 16, weight: .medium, design: .monospaced))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(.ultraThinMaterial)
                    )
            }
            
            Slider(value: $value, in: range, step: step)
                .tint(Color.accentColor)
        }
        .padding(.vertical, 12)
    }
}

struct ParameterStepper: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    var step: Int = 1
    let description: String
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 16, weight: .medium))
                Text(description)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            HStack(spacing: 12) {
                Button {
                    if value - step >= range.lowerBound {
                        value -= step
                    }
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(Color.accentColor)
                }
                .disabled(value <= range.lowerBound)
                
                Text("\(value)")
                    .font(.system(size: 16, weight: .medium, design: .monospaced))
                    .frame(minWidth: 60)
                
                Button {
                    if value + step <= range.upperBound {
                        value += step
                    }
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(Color.accentColor)
                }
                .disabled(value >= range.upperBound)
            }
        }
        .padding(.vertical, 12)
    }
}

#Preview {
    let schema = Schema([
        DownloadedModel.self,
        ChatSession.self,
        ChatMessage.self,
        FileSource.self,
        IndexedFile.self
    ])
    let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    let container = try! ModelContainer(for: schema, configurations: [configuration])

    return SettingsView()
        .modelContainer(container)
}
