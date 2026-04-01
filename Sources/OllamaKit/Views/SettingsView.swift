import SwiftUI
import SwiftData

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

                    SurfaceSectionCard(
                        title: "Power Agent",
                        footer: "Agent automation controls for local files, workspaces, runtimes, GitHub, and the hidden browser automation surface. Writes and external side effects still pause for approval."
                    ) {
                        PowerAgentSettingsSection(settings: settings)
                    }

                    SurfaceSectionCard(title: "Interface") {
                        InterfaceSettingsSection(settings: settings)
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

struct PowerAgentSettingsSection: View {
    @ObservedObject var settings: AppSettings
    @StateObject private var workspaceManager = AgentWorkspaceManager.shared
    @ObservedObject private var serverLogs = ServerLogStore.shared
    @ObservedObject private var agentLogs = AgentLogStore.shared
    @State private var showingGitHubToken = false
    @State private var settingsMode: PowerAgentSettingsMode = .basic

    private var activeWorkspaceName: String {
        workspaceManager.workspace(id: settings.agentDefaultWorkspaceID)?.name
            ?? settings.agentDefaultWorkspaceID.nonEmpty
            ?? "OllamaKit Mirror"
    }

    private var runtimePackages: [RuntimePackageRecord] {
        AgentToolRuntime.shared.runtimePackagePreview().filter { $0.id != "git" }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Power Agent Mode", selection: $settingsMode) {
                ForEach(PowerAgentSettingsMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding(.vertical, 12)

            Divider()

            if settingsMode == .basic {
                basicSettings
            } else {
                advancedSettings
            }
        }
        .task {
            workspaceManager.bootstrapIfNeeded()
        }
    }

    private var basicSettings: some View {
        VStack(spacing: 0) {
            Toggle(isOn: $settings.powerAgentEnabled) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Enable Power Agent")
                        .font(.system(size: 16, weight: .medium))
                    Text("Turns on agent tools, checkpoints, workspaces, runtime access, and hidden browser automation.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 12)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("How It Works")
                    .font(.system(size: 16, weight: .medium))
                Text("Power Agent can work inside granted folders, internal workspaces, GitHub, and embedded runtimes. The browser is agent-only and does not appear as a personal browser anymore.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Text("Model-specific browser and coding permissions still live in the Models tab.")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 12)

            Divider()

            LocalFilesSettingsView()

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Active Workspace")
                    .font(.system(size: 16, weight: .medium))
                Text(activeWorkspaceName)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text("Reads run automatically. Writes, deletes, restores, GitHub pushes, and relay reconnects still pause for approval.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 12)

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("Runtime Health")
                    .font(.system(size: 16, weight: .medium))
                ForEach(runtimePackages) { package in
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(package.title)
                                .font(.system(size: 14, weight: .semibold))
                            HStack(spacing: 8) {
                                Text(package.statusTitle)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(package.available ? .green : .orange)
                                if let version = package.version?.nonEmpty {
                                    Text(version)
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            if let reason = package.availabilityReason?.nonEmpty {
                                Text(reason)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                            if !package.supportedOperations.isEmpty {
                                Text(package.supportedOperations.joined(separator: " • "))
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        Spacer()
                    }
                }
                Text("Installed means the runtime wrapper, manifest, support resources, and bridge all loaded from the IPA. Model policy can still disable a runtime per model.")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 12)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Stored Logs")
                    .font(.system(size: 16, weight: .medium))
                Text("Agent: \(agentLogs.entries.count) entries • keeps \(agentLogs.retentionLimit)")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text("Server: \(serverLogs.entries.count) entries • keeps \(serverLogs.retentionLimit)")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text("Logs are stored on device and survive app relaunches and server restarts until you explicitly clear them.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 12)
        }
    }

    private var advancedSettings: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("GitHub Repository")
                    .font(.system(size: 16, weight: .medium))
                TextField("owner/repo", text: $settings.agentGitHubRepository)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(size: 14, design: .monospaced))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(.ultraThinMaterial)
                    )
                Text("Used for GitHub metadata, workflow reads, remote refreshes, and workspace pushes.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 12)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("GitHub OAuth Client ID")
                    .font(.system(size: 16, weight: .medium))
                TextField("Iv1.1234567890abcdef", text: $settings.agentGitHubClientID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(size: 14, design: .monospaced))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(.ultraThinMaterial)
                    )
                Text("Used for GitHub device-flow login. Leave empty if you only use a personal access token.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                if settings.hasPendingGitHubDeviceFlow {
                    Text("Pending device flow: code \(settings.agentGitHubUserCode) at \(settings.agentGitHubVerificationURL)")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 12)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("GitHub Token")
                        .font(.system(size: 16, weight: .medium))
                    Spacer()
                    Button {
                        showingGitHubToken.toggle()
                    } label: {
                        Image(systemName: showingGitHubToken ? "eye.slash" : "eye")
                            .foregroundStyle(.secondary)
                    }
                }

                TextField(
                    "github_pat_...",
                    text: Binding(
                        get: {
                            showingGitHubToken
                                ? settings.agentGitHubToken
                                : String(repeating: "•", count: min(settings.agentGitHubToken.count, 24))
                        },
                        set: { newValue in
                            if showingGitHubToken || newValue.contains("github_") || newValue.contains("ghp_") {
                                settings.agentGitHubToken = newValue
                            }
                        }
                    )
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(size: 14, design: .monospaced))
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(.ultraThinMaterial)
                )

                Text("Optional for public metadata reads. Required for GitHub pushes and private repositories.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 12)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Agent Browser Start URL")
                    .font(.system(size: 16, weight: .medium))
                TextField("https://github.com", text: $settings.agentBrowserHomeURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(size: 14, design: .monospaced))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(.ultraThinMaterial)
                    )
                Text("Used only by the hidden browser automation runtime when an agent starts a browsing task.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 12)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Managed Relay")
                    .font(.system(size: 16, weight: .medium))
                Text(settings.normalizedManagedRelayBaseURL ?? "Configured in Server settings")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text("Managed public URL settings live in the Server tab. Power Agent tools read the same relay session and permissions.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 12)

            Divider()

            Toggle(isOn: $settings.agentBundleExpertMode) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Expert Bundle Mode")
                        .font(.system(size: 16, weight: .medium))
                    Text(settings.isJailbreakBuild
                         ? "Requires a writable live-bundle workspace. Allows broader resource edits, but still does not enable binary Mach-O rewriting."
                         : "Standard sideload IPAs keep bundle resources read-only. This toggle only matters when a writable live bundle workspace exists.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(!settings.isJailbreakBuild)
            .padding(.vertical, 12)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Build Diagnostics")
                    .font(.system(size: 16, weight: .medium))
                Text(settings.buildVariant.title)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text("Browser surface: agent-only hidden")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text("Log storage: \(agentLogs.storageLocationDescription) and \(serverLogs.storageLocationDescription)")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 12)
        }
    }
}

private enum PowerAgentSettingsMode: String, CaseIterable, Identifiable {
    case basic
    case advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .basic:
            return "Basic"
        case .advanced:
            return "Advanced"
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
