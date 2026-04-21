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
                    SettingsHeroHeader()

                    SurfaceSectionCard(
                        title: "Model Parameters",
                        icon: "slider.horizontal.3",
                        footer: "Default parameters for model inference. These can be overridden per chat."
                    ) {
                        ModelSettingsSection(settings: settings)
                    }

                    SurfaceSectionCard(
                        title: "Performance",
                        icon: "speedometer",
                        footer: "Adjust based on your device's capabilities. More GPU layers means faster inference but higher memory usage."
                    ) {
                        PerformanceSettingsSection(settings: settings)
                    }

                    SurfaceSectionCard(
                        title: "Thermal Monitor",
                        icon: "thermometer.high",
                        footer: "Monitors device thermal state. Estimated temperatures are based on iOS thermal state categories — actual CPU temperature varies by device."
                    ) {
                        ThermalMonitorSection()
                    }

                    SurfaceSectionCard(title: "Memory Management", icon: "memorychip") {
                        MemorySettingsSection(settings: settings)
                    }

                    SurfaceSectionCard(
                        title: "Hugging Face",
                        icon: "person.crop.circle.badge.checkmark",
                        footer: "Required for accessing gated models and higher rate limits."
                    ) {
                        HuggingFaceSettingsSection(settings: settings)
                    }

                    SurfaceSectionCard(title: "Interface", icon: "paintpalette") {
                        InterfaceSettingsSection(settings: settings)
                    }

                    SurfaceSectionCard(
                        title: "App Debug Logs",
                        icon: "ant.fill",
                        footer: "Client-side app events only (tab switches, chat send/receive, runtime errors). Server/API logs remain in the Server tab."
                    ) {
                        AppDebugLogsSection()
                    }

                    SurfaceSectionCard(
                        title: "App Activity Logs",
                        icon: "list.bullet.rectangle.portrait",
                        footer: "Includes chat and model runtime events. Server/API logs remain in the Server panel."
                    ) {
                        AppActivityLogsSection()
                    }

                    SurfaceSectionCard(
                        title: "Model Performance",
                        footer: "Recent model load/generation timing samples to help debug slow responses."
                    ) {
                        ModelPerformanceSection()
                    }

                    SurfaceSectionCard(
                        title: "Benchmark",
                        footer: "Run a quick benchmark using the smallest runnable model on this device."
                    ) {
                        BenchmarkSection()
                    }

                    SurfaceSectionCard(title: "Data Management", icon: "externaldrive") {
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

private struct SettingsHeroHeader: View {
    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [.blue.opacity(0.85), .purple.opacity(0.85)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 54, height: 54)

                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("Advanced Controls")
                    .font(.system(size: 19, weight: .bold))
                Text("Tune model quality, speed, memory, and runtime behavior.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(.white.opacity(0.12), lineWidth: 1)
                )
        )
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
                description: "Layers to offload to GPU (100 = fastest on most devices)"
            )
            
            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("KV Cache Quant")
                    .font(.system(size: 16, weight: .medium))
                Text("Default is safest. Google Turbo (Q4_0) is a community preset and may vary by model.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)

                Picker("KV Cache Quant", selection: Binding(
                    get: { settings.kvCachePreset },
                    set: { settings.kvCachePreset = $0 }
                )) {
                    ForEach(RuntimePreferences.KVCachePreset.allCases, id: \.rawValue) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
                .pickerStyle(.segmented)
            }
            .padding(.vertical, 12)

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

    private var exportedLogText: String {
        recentEntries.map { entry in
            let timestamp = ISO8601DateFormatter().string(from: entry.timestamp)
            return "[\(timestamp)] [\(entry.level.rawValue.uppercased())] [\(entry.category.rawValue)] \(entry.title)\n\(entry.message)"
        }.joined(separator: "\n\n")
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

                HStack(spacing: 12) {
                    Button("Copy") {
                        UIPasteboard.general.string = exportedLogText
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .disabled(recentEntries.isEmpty)

                    ShareLink(
                        item: exportedLogText,
                        subject: Text("OllamaKit App Debug Logs"),
                        message: Text("Exported app debug logs from OllamaKit.")
                    ) {
                        Text("Export")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                    }
                    .disabled(recentEntries.isEmpty)

                    Button("Clear") {
                        logStore.clear()
                        HapticManager.impact(.light)
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.red)
                }
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
        let samples = entries.filter { $0.phase == .generate && ($0.tokensPerSecond ?? 0) > 0 && $0.wasSuccessful }
        guard !samples.isEmpty else { return 0 }
        return samples.reduce(0) { $0 + ($1.tokensPerSecond ?? 0) } / Double(samples.count)
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
                                ? String(format: "%.1f ms • %d tokens • %.1f tok/s%@", entry.elapsedMs, entry.tokens ?? 0, entry.tokensPerSecond ?? 0, entry.wasSuccessful ? "" : " • failed")
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
    @State private var benchmarkTask: Task<Void, Never>?
    @State private var isRunning = false
    @State private var status = "Idle"
    @State private var resultLine = ""
    @State private var errorLine = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Quick Benchmark")
                    .font(.system(size: 16, weight: .medium))
                Spacer()
                Button(isRunning ? "Running…" : "Run") {
                    startBenchmark()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isRunning)
            }

            HStack(spacing: 8) {
                if isRunning {
                    ProgressView()
                        .controlSize(.small)
                }

                Text(status)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            if !resultLine.isEmpty {
                Text(resultLine)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            if !errorLine.isEmpty {
                Text(errorLine)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 12)
        .onDisappear {
            benchmarkTask?.cancel()
            benchmarkTask = nil
        }
    }

    @MainActor
    private func runBenchmark() async {
        isRunning = true
        status = "Refreshing models…"
        resultLine = ""
        errorLine = ""
        defer {
            isRunning = false
            benchmarkTask = nil
        }

        await ModelStorage.shared.refresh()
        let candidates = BuiltInModelCatalog.selectionModels(downloadedModels: ModelStorage.shared.selectionSnapshots)
            .filter(\.canBeSelectedForChat)

        guard let model = resolveBenchmarkCandidate(from: candidates) else {
            status = "Load or download a model first."
            return
        }

        AppLogStore.shared.record(
            .settings,
            title: "Benchmark Started",
            message: "Running the quick benchmark.",
            metadata: [
                "model_id": model.catalogId,
                "validated_runnable": String(model.isValidatedRunnable)
            ]
        )

        do {
            status = "Loading \(model.displayName)…"
            let contextLength = max(min(model.runtimeContextLength, AppSettings.shared.defaultContextLength), 512)
            let loadStart = CFAbsoluteTimeGetCurrent()
            try await ModelRunner.shared.loadModel(
                catalogId: model.catalogId,
                contextLength: contextLength,
                gpuLayers: AppSettings.shared.gpuLayers
            )
            let loadMs = (CFAbsoluteTimeGetCurrent() - loadStart) * 1000

            status = "Generating sample output…"
            let result = try await ModelRunner.shared.generate(
                prompt: "Return a short benchmark response.",
                parameters: SamplingParameters(
                    temperature: 0.2,
                    topP: 0.9,
                    topK: 40,
                    repeatPenalty: 1.05,
                    repeatLastN: 64,
                    maxTokens: 96
                )
            ) { _ in }

            let tokPerSec = result.generationTime > 0
                ? Double(result.tokensGenerated) / result.generationTime
                : 0
            status = "Benchmark complete."
            resultLine = String(
                format: "%@ • load %.0f ms • %d tokens • %.1f tok/s",
                model.displayName,
                loadMs,
                result.tokensGenerated,
                tokPerSec
            )
            AppLogStore.shared.record(
                .settings,
                title: "Benchmark Complete",
                message: "Quick benchmark finished successfully.",
                metadata: [
                    "model_id": model.catalogId,
                    "tokens": "\(result.tokensGenerated)",
                    "tokens_per_second": String(format: "%.1f", tokPerSec)
                ]
            )
        } catch is CancellationError {
            status = "Benchmark cancelled."
        } catch {
            status = "Benchmark failed."
            errorLine = error.localizedDescription
            AppLogStore.shared.record(
                .settings,
                level: .error,
                title: "Benchmark Failed",
                message: "Quick benchmark failed.",
                metadata: ["model_id": model.catalogId],
                body: error.localizedDescription
            )
        }
    }

    @MainActor
    private func startBenchmark() {
        guard !isRunning else { return }
        benchmarkTask?.cancel()
        benchmarkTask = Task {
            await runBenchmark()
        }
    }

    @MainActor
    private func resolveBenchmarkCandidate(from candidates: [ModelSnapshot]) -> ModelSnapshot? {
        guard !candidates.isEmpty else { return nil }

        if let activeCatalogId = ModelRunner.shared.activeCatalogId,
           let activeModel = ModelSnapshot.resolveStoredReference(activeCatalogId, in: candidates) {
            return activeModel
        }

        if let defaultModelID = AppSettings.shared.defaultModelId.nonEmpty,
           let defaultModel = ModelSnapshot.resolveStoredReference(defaultModelID, in: candidates) {
            return defaultModel
        }

        if let validatedCandidate = candidates
            .filter(\.isValidatedRunnable)
            .min(by: { $0.size < $1.size }) {
            return validatedCandidate
        }

        return candidates.min(by: { $0.size < $1.size })
    }
}

struct AppActivityLogsSection: View {
    @ObservedObject private var logStore = AppLogStore.shared
    @State private var liveUpdates = true
    @State private var displayedEntries: [AppLogEntry] = []
    @State private var searchText = ""
    @State private var selectedCategory: AppLogCategory?

    private var filteredEntries: [AppLogEntry] {
        displayedEntries.filter { entry in
            let matchesCategory = selectedCategory.map { entry.category == $0 } ?? true
            let needle = searchText.trimmedForLookup.lowercased()
            guard !needle.isEmpty else { return matchesCategory }

            let haystack = [
                entry.title,
                entry.message,
                entry.body ?? "",
                entry.category.rawValue,
                entry.level.rawValue
            ].joined(separator: " ").lowercased()
            return matchesCategory && haystack.contains(needle)
        }
    }

    private var exportedLogText: String {
        filteredEntries.map(renderEntry).joined(separator: "\n\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                TextField("Search app logs", text: $searchText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(size: 14))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(.ultraThinMaterial)
                    )

                Menu {
                    Button("All Categories") { selectedCategory = nil }
                    ForEach(AppLogCategory.allCases) { category in
                        Button(category.rawValue.replacingOccurrences(of: "_", with: " ").capitalized) {
                            selectedCategory = category
                        }
                    }
                } label: {
                    Label(selectedCategoryLabel, systemImage: "line.3.horizontal.decrease.circle")
                        .font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(.ultraThinMaterial)
                        )
                }
            }

            HStack(spacing: 12) {
                Toggle("Live", isOn: $liveUpdates)
                    .font(.system(size: 13, weight: .medium))

                Spacer()

                Button("Copy") {
                    UIPasteboard.general.string = exportedLogText
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .disabled(filteredEntries.isEmpty)

                ShareLink(
                    item: exportedLogText,
                    subject: Text("OllamaKit App Logs"),
                    message: Text("Exported app/model/chat logs from OllamaKit.")
                ) {
                    Text("Export")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                }
                .disabled(filteredEntries.isEmpty)

                Button("Clear") {
                    logStore.clear()
                    displayedEntries = []
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.red)
            }

            Text(logStore.persistenceSummary)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            ScrollView {
                VStack(spacing: 10) {
                    if filteredEntries.isEmpty {
                        Text("No app activity log entries yet.")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 12)
                    } else {
                        ForEach(filteredEntries.suffix(100)) { entry in
                            AppLogEntryRow(entry: entry)
                        }
                    }
                }
            }
            .frame(minHeight: 240, maxHeight: 360)
        }
        .onAppear {
            displayedEntries = logStore.entries
        }
        .onChange(of: logStore.entries) { _, newValue in
            if liveUpdates {
                displayedEntries = newValue
            }
        }
        .onChange(of: liveUpdates) { _, newValue in
            if newValue {
                displayedEntries = logStore.entries
            }
        }
    }

    private var selectedCategoryLabel: String {
        guard let selectedCategory else { return "Category" }
        return selectedCategory.rawValue.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private func renderEntry(_ entry: AppLogEntry) -> String {
        let timestamp = ISO8601DateFormatter().string(from: entry.timestamp)
        let metadata = entry.metadata
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        let metadataPart = metadata.isEmpty ? "" : "\n\(metadata)"
        let bodyPart = entry.body.map { "\n\($0)" } ?? ""
        return "[\(timestamp)] [\(entry.level.rawValue.uppercased())] [\(entry.category.rawValue)] \(entry.title)\n\(entry.message)\(metadataPart)\(bodyPart)"
    }
}

struct AppLogEntryRow: View {
    let entry: AppLogEntry

    private var tint: Color {
        switch entry.level {
        case .debug:
            return .secondary
        case .info:
            return .blue
        case .warning:
            return .orange
        case .error:
            return .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title)
                        .font(.system(size: 13, weight: .semibold))
                    Text(entry.timestamp, style: .time)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(entry.category.rawValue)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(tint)
            }

            Text(entry.message)
                .font(.system(size: 12))

            if !entry.metadata.isEmpty {
                Text(entry.metadata
                    .sorted { $0.key < $1.key }
                    .map { "\($0.key)=\($0.value)" }
                    .joined(separator: " "))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
            }

            if let body = entry.body {
                Text(body)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(6)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.ultraThinMaterial)
        )
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

// MARK: - Thermal Monitor Section

struct ThermalMonitorSection: View {
    @StateObject private var thermal = ThermalMonitorService.shared

    var body: some View {
        VStack(spacing: 0) {
            // State row
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Thermal State")
                        .font(.system(size: 16, weight: .medium))
                    Text(thermal.statusLabel)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(severityColor)
                }

                Spacer()

                ThermalStateBadge(state: thermal.thermalState)
            }
            .padding(.vertical, 12)

            Divider()

            // Temperature display — both C and F
            HStack(spacing: 0) {
                // Celsius
                VStack(spacing: 4) {
                    Text("°C")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(formattedCelsius)
                        .font(.system(size: 22, weight: .bold, design: .monospaced))
                        .foregroundStyle(.primary)
                    Text("Celsius")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)

                Divider()
                    .padding(.vertical, 4)

                // Fahrenheit
                VStack(spacing: 4) {
                    Text("°F")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(formattedFahrenheit)
                        .font(.system(size: 22, weight: .bold, design: .monospaced))
                        .foregroundStyle(.primary)
                    Text("Fahrenheit")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)

                Divider()
                    .padding(.vertical, 4)

                // Range indicator
                VStack(spacing: 4) {
                    Text("Est. Range")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(rangeString)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.primary)
                    Text("Typical")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.vertical, 14)

            Divider()

            // Thermal state bar
            ThermalStateBar(currentState: thermal.thermalState)
                .padding(.vertical, 12)

            Divider()

            // Monitoring toggle
            Toggle(isOn: $thermal.monitoringEnabled) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Continuous Monitoring")
                        .font(.system(size: 16, weight: .medium))
                    Text("Polls thermal state every 2 seconds")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 10)
        }
    }

    // MARK: - Formatted values

    private var formattedCelsius: String {
        String(format: "%.1f°", thermal.temperatureCelsius)
    }

    private var formattedFahrenheit: String {
        String(format: "%.1f°", thermal.temperatureFahrenheit)
    }

    private var rangeString: String {
        let low = Int(thermal.temperatureRangeCelsius.lowerBound)
        let high = Int(thermal.temperatureRangeCelsius.upperBound)
        return "\(low)–\(high)°"
    }

    private var severityColor: Color {
        switch thermal.thermalState {
        case .nominal:  return .green
        case .fair:     return .green
        case .serious:   return .yellow
        case .critical: return .red
        @unknown default: return .gray
        }
    }
}

// MARK: - Thermal State Badge

struct ThermalStateBadge: View {
    let state: ProcessInfo.ThermalState

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: iconName)
                .font(.system(size: 14, weight: .semibold))
            Text(label)
                .font(.system(size: 13, weight: .semibold))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(backgroundColor.opacity(0.18))
        )
        .foregroundStyle(foregroundColor)
    }

    private var iconName: String {
        switch state {
        case .nominal:  return "checkmark.circle.fill"
        case .fair:     return "thermometer.medium"
        case .serious:   return "thermometer.high"
        case .critical: return "exclamationmark.triangle.fill"
        @unknown default: return "questionmark.circle"
        }
    }

    private var label: String {
        switch state {
        case .nominal:  return "Normal"
        case .fair:     return "Warm"
        case .serious:   return "Hot"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }

    private var backgroundColor: Color {
        switch state {
        case .nominal:  return .green
        case .fair:     return .green
        case .serious:   return .orange
        case .critical: return .red
        @unknown default: return .gray
        }
    }

    private var foregroundColor: Color {
        switch state {
        case .nominal:  return .green
        case .fair:     return .green
        case .serious:   return .orange
        case .critical: return .red
        @unknown default: return .gray
        }
    }
}

// MARK: - Thermal State Bar

struct ThermalStateBar: View {
    let currentState: ProcessInfo.ThermalState

    private let states: [ProcessInfo.ThermalState] = [.nominal, .fair, .serious, .critical]

    var body: some View {
        VStack(spacing: 6) {
            // Segmented bar
            GeometryReader { geometry in
                HStack(spacing: 3) {
                    ForEach(Array(states.enumerated()), id: \.offset) { index, state in
                        RoundedRectangle(cornerRadius: 4)
                            .fill(barColor(for: state))
                            .frame(width: barWidth(for: state, totalWidth: geometry.size.width))
                    }
                }
            }
            .frame(height: 10)

            // Labels
            HStack {
                Text("Cool")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Hot")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func barWidth(for state: ProcessInfo.ThermalState, totalWidth: CGFloat) -> CGFloat {
        let segmentGap: CGFloat = 3 * 3  // 3 gaps
        let width = (totalWidth - segmentGap) / 4
        return max(width, 40)
    }

    private func barColor(for state: ProcessInfo.ThermalState) -> Color {
        let isActive = stateReaches(currentState, upTo: state)
        let baseColor: Color = {
            switch state {
            case .nominal:  return .green
            case .fair:     return .green
            case .serious:   return .orange
            case .critical: return .red
            @unknown default: return .gray
            }
        }()
        return isActive ? baseColor : baseColor.opacity(0.25)
    }

    /// Returns true if thermalState reaches (or exceeds) the target state.
    private func stateReaches(_ current: ProcessInfo.ThermalState, upTo target: ProcessInfo.ThermalState) -> Bool {
        let order: [ProcessInfo.ThermalState] = [.nominal, .fair, .serious, .critical]
        let currentIdx = order.firstIndex(of: current) ?? 0
        let targetIdx = order.firstIndex(of: target) ?? 0
        return currentIdx >= targetIdx
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
    // FIX: Don't use try! in #Preview — crashes on schema errors. Use try? instead.
    guard let container = try? ModelContainer(for: schema, configurations: [configuration]) else {
        // Return a minimal preview that doesn't depend on the full schema
        return SettingsView()
    }

    return SettingsView()
        .modelContainer(container)
}
