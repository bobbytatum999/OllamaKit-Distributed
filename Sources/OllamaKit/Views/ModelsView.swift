import OllamaCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ModelsView: View {
    @ObservedObject private var modelRunner = ModelRunner.shared
    @StateObject private var modelStore = ModelStorage.shared
    @StateObject private var viewModel = ModelsViewModel()
    @State private var showingSearch = false
    @State private var showingImporter = false

    private var installedModels: [ModelSnapshot] {
        modelStore.installedSnapshots
    }

    private var activeModel: ModelSnapshot? {
        guard let activeCatalogId = modelRunner.activeCatalogId else { return nil }
        return modelStore.selectionSnapshots.first { $0.catalogId == activeCatalogId }
    }

    private var supportedImportTypes: [UTType] {
        if let ggufType = UTType(filenameExtension: "gguf") {
            return [ggufType, .folder, .data]
        }

        return [.folder, .data]
    }
    
    private var totalStorageUsed: Int64 {
        installedModels.reduce(0) { $0 + $1.size }
    }

    var body: some View {
        ZStack {
            AnimatedMeshBackground()

            ScrollView {
                VStack(spacing: 20) {
                    if let activeModel {
                        SurfaceSectionCard(title: "Active Model") {
                            ActiveModelSummary(model: activeModel)
                        }
                    }

                    BuiltInAppleModelCard()

                    if !installedModels.isEmpty {
                        SurfaceSectionCard(title: "Storage") {
                            HStack {
                                Image(systemName: "internaldrive")
                                    .foregroundStyle(.secondary)
                                Text("Total Used")
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(formatBytes(totalStorageUsed))
                                    .fontWeight(.semibold)
                            }
                            .font(.system(size: 14))
                        }
                    }

                    SurfaceSectionCard(
                        title: "Installed Models",
                        footer: installedModels.isEmpty
                            ? "Download GGUF models or import a local GGUF/CoreML package to get started."
                            : "\(installedModels.count) model\(installedModels.count == 1 ? "" : "s") available on this device."
                    ) {
                        if installedModels.isEmpty {
                            EmptyModelsView()
                        } else {
                            VStack(spacing: 12) {
                                ForEach(installedModels, id: \.id) { model in
                                    DownloadedModelRow(model: model, viewModel: viewModel)
                                }
                            }
                        }
                    }

                    BrowseMoreCard {
                        showingSearch = true
                    }

                    ImportLocalModelCard {
                        showingImporter = true
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            }
            .scrollIndicators(.hidden)
        }
        .navigationTitle("Models")
        .sheet(isPresented: $showingSearch) {
            ModelSearchSheet()
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: supportedImportTypes,
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                Task {
                    await viewModel.importLocalModel(from: url)
                }
            case .failure(let error):
                viewModel.alertTitle = "Import Failed"
                viewModel.errorMessage = error.localizedDescription
                viewModel.showError = true
            }
        }
        .alert(isPresented: $viewModel.showError) {
            Alert(
                title: Text(viewModel.alertTitle),
                message: Text(viewModel.errorMessage),
                dismissButton: .default(Text("OK"))
            )
        }
        .task {
            await modelStore.refresh()
        }
    }
}

private extension ModelSnapshot {
    var importSourceLabel: String {
        switch importSource {
        case .builtIn:
            return "Built In"
        case .huggingFaceDownload:
            return "Downloaded"
        case .localImport:
            return "Local"
        case .coreMLImport:
            return "CoreML"
        case .migratedLegacy:
            return "Migrated"
        }
    }

    var importSourceIcon: String {
        switch importSource {
        case .builtIn:
            return "apple.logo"
        case .huggingFaceDownload:
            return "arrow.down.circle"
        case .localImport:
            return "square.and.arrow.down"
        case .coreMLImport:
            return "shippingbox"
        case .migratedLegacy:
            return "clock.arrow.trianglehead.counterclockwise.rotate.90"
        }
    }

    var backendDisplayName: String {
        switch backendKind {
        case .ggufLlama:
            return "GGUF / llama.cpp"
        case .coreMLPackage:
            return "CoreML Package"
        case .appleFoundation:
            return "Apple Foundation"
        }
    }

    var isRunnableInCurrentBuild: Bool {
        switch backendKind {
        case .ggufLlama:
            return isValidatedRunnable
        case .coreMLPackage:
            return hasRunnableCoreMLPayload
        case .appleFoundation:
            return true
        }
    }

    var runtimeAvailabilityLabel: String? {
        switch backendKind {
        case .ggufLlama:
            switch effectiveValidationStatus {
            case .pending:
                return "Validating"
            case .failed:
                return "Validation Failed"
            case .unknown:
                return "Needs Validation"
            case .validated:
                return nil
            }
        case .coreMLPackage:
            guard !hasRunnableCoreMLPayload else { return nil }
            return "Incomplete Import"
        case .appleFoundation:
            return nil
        }
    }

    var runtimeAvailabilityMessage: String? {
        switch backendKind {
        case .ggufLlama:
            return validationSummary
        case .coreMLPackage:
            guard !hasRunnableCoreMLPayload else { return nil }
            return "Import the full ANEMLL/CoreML model folder containing meta.yaml, tokenizer assets, and compiled .mlmodelc or .mlpackage payloads."
        case .appleFoundation:
            return nil
        }
    }
}

private extension ModelCompatibilityLevel {
    var tint: Color {
        switch self {
        case .recommended:
            return .green
        case .supported:
            return .orange
        case .unavailable:
            return .red
        case .unknown:
            return .secondary
        }
    }
}

private enum AgentCapabilityOverrideChoice: String, CaseIterable, Identifiable {
    case inherited
    case enabled
    case disabled

    var id: String { rawValue }

    init(value: Bool?) {
        switch value {
        case true:
            self = .enabled
        case false:
            self = .disabled
        case nil:
            self = .inherited
        }
    }

    var optionalBool: Bool? {
        switch self {
        case .inherited:
            return nil
        case .enabled:
            return true
        case .disabled:
            return false
        }
    }

    var title: String {
        switch self {
        case .inherited:
            return "Default"
        case .enabled:
            return "On"
        case .disabled:
            return "Off"
        }
    }
}

private struct AgentCapabilitySettingDefinition: Identifiable {
    let capability: AgentToolCapabilityKey
    let title: String
    let detail: String

    var id: String { capability.rawValue }
}

private let agentCapabilityDefinitions: [AgentCapabilitySettingDefinition] = [
    AgentCapabilitySettingDefinition(capability: .browserRead, title: "Browser Read", detail: "Open pages, navigate, inspect DOM, and read content."),
    AgentCapabilitySettingDefinition(capability: .browserActions, title: "Browser Actions", detail: "Type, click, submit forms, and download through the embedded browser."),
    AgentCapabilitySettingDefinition(capability: .internetRead, title: "Internet Read", detail: "Read public web resources and fetch URLs."),
    AgentCapabilitySettingDefinition(capability: .internetWrite, title: "Internet Write", detail: "Perform side-effecting network actions such as PR creation or workflow reruns."),
    AgentCapabilitySettingDefinition(capability: .workspaceRead, title: "Workspace Read", detail: "Read files, search code, and inspect diffs."),
    AgentCapabilitySettingDefinition(capability: .workspaceWrite, title: "Workspace Write", detail: "Create checkpoints, write files, move paths, and delete workspace content."),
    AgentCapabilitySettingDefinition(capability: .codeTools, title: "Code Tools", detail: "Use shell-style coding tools and web scaffolding helpers."),
    AgentCapabilitySettingDefinition(capability: .jsRuntime, title: "JavaScript Runtime", detail: "Execute JavaScript locally with JavaScriptCore."),
    AgentCapabilitySettingDefinition(capability: .pythonRuntime, title: "Python Runtime", detail: "Run embedded Python when that runtime is bundled."),
    AgentCapabilitySettingDefinition(capability: .nodeRuntime, title: "Node Runtime", detail: "Run embedded Node.js tooling when that runtime is bundled."),
    AgentCapabilitySettingDefinition(capability: .swiftRuntime, title: "Swift Runtime", detail: "Run embedded Swift script or SwiftPM tooling when that runtime is bundled."),
    AgentCapabilitySettingDefinition(capability: .gitRead, title: "Git Read", detail: "Inspect repository state and clone repository workspaces."),
    AgentCapabilitySettingDefinition(capability: .gitWrite, title: "Git Write", detail: "Create branches and push workspace changes through the configured git/GitHub bridge."),
    AgentCapabilitySettingDefinition(capability: .githubAccess, title: "GitHub Access", detail: "Use GitHub repository, code search, issues, and PR APIs."),
    AgentCapabilitySettingDefinition(capability: .remoteCI, title: "Remote CI", detail: "Read or trigger GitHub Actions runs for jobs the phone cannot do locally."),
    AgentCapabilitySettingDefinition(capability: .managedRelayAccess, title: "Managed Relay", detail: "Inspect or reconnect the managed public relay when this build exposes it."),
    AgentCapabilitySettingDefinition(capability: .bundleEdits, title: "Bundle Edits", detail: "Allow live bundle resource edits on writable jailbreak-style installs.")
]

struct ActiveModelSummary: View {
    let model: ModelSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.green.opacity(0.16))
                        .frame(width: 46, height: 46)

                    Image(systemName: "bolt.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.green)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(model.displayName)
                        .font(.system(size: 18, weight: .semibold))

                    Text("Loaded and ready for chat")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Unload") {
                    ModelRunner.shared.unloadModel()
                    Task { @MainActor in
                        HapticManager.impact(.medium)
                    }
                }
                .buttonStyle(.bordered)
                .tint(.orange)
            }

            HStack(spacing: 10) {
                ModelFactChip(icon: "cpu", text: model.quantization)
                ModelFactChip(icon: "externaldrive", text: model.formattedSize)
                ModelFactChip(icon: "text.alignleft", text: "\(model.runtimeContextLength) ctx")
            }
        }
        .padding(.vertical, 16)
    }
}

struct ModelFactChip: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
            Text(text)
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
        )
    }
}

@MainActor
struct DownloadedModelRow: View {
    @ObservedObject private var modelRunner = ModelRunner.shared
    let model: ModelSnapshot
    @ObservedObject var viewModel: ModelsViewModel
    @State private var showingOptions = false
    @State private var showingAgentCapabilities = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [.accentColor.opacity(0.26), .accentColor.opacity(0.08)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 48, height: 48)

                    Image(systemName: "cube.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(model.displayName)
                            .font(.system(size: 17, weight: .semibold))
                            .lineLimit(2)

                        if modelRunner.activeCatalogId == model.catalogId {
                            Text("ACTIVE")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.green)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(
                                    Capsule(style: .continuous)
                                        .fill(.green.opacity(0.16))
                                )
                        }
                    }

                    FlowLayout(spacing: 8) {
                        ModelBadge(text: model.importSourceLabel, systemImage: model.importSourceIcon)
                        ModelBadge(text: model.quantization, systemImage: model.backendKind == .coreMLPackage ? "shippingbox" : "cpu")
                        if model.size > 0 {
                            ModelBadge(text: model.formattedSize, systemImage: "externaldrive")
                        }
                        ModelBadge(text: "\(model.runtimeContextLength) ctx", systemImage: "text.alignleft")
                    }
                }
            }

            if let runtimeAvailabilityLabel = model.runtimeAvailabilityLabel {
                Label(runtimeAvailabilityLabel, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.orange)
            }

            HStack(spacing: 10) {
                if model.isRunnableInCurrentBuild {
                    Button("Load") {
                        loadModel()
                    }
                    .buttonStyle(.borderedProminent)
                }

                if AppSettings.shared.defaultModelId != model.persistentReference, model.isRunnableInCurrentBuild {
                    Button("Set Default") {
                        AppSettings.shared.defaultModelId = model.persistentReference
                    }
                    .buttonStyle(.bordered)
                }

                Spacer()

                Button {
                    showingOptions = true
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 21))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(.white.opacity(0.12), lineWidth: 0.6)
                )
        )
        .contextMenu {
            if model.isRunnableInCurrentBuild {
                Button {
                    loadModel()
                } label: {
                    Label("Load Model", systemImage: "play.circle")
                }
            }

            if model.backendKind == .ggufLlama {
                Button {
                    revalidateModel()
                } label: {
                    Label("Revalidate", systemImage: "checkmark.shield")
                }
            }

            Button {
                presentModelInfo()
            } label: {
                Label("View Info", systemImage: "info.circle")
            }

            Button(role: .destructive) {
                deleteModel()
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .confirmationDialog("Model Options", isPresented: $showingOptions, titleVisibility: .visible) {
            if model.isRunnableInCurrentBuild {
                Button("Load Model") {
                    loadModel()
                }
            }

            if model.backendKind == .ggufLlama {
                Button("Revalidate") {
                    revalidateModel()
                }
            }

            if model.isRunnableInCurrentBuild {
                Button("Set as Default") {
                    AppSettings.shared.defaultModelId = model.persistentReference
                    viewModel.alertTitle = "Default Model"
                    viewModel.errorMessage = "\(model.displayName) will be preselected for new chats."
                    viewModel.showError = true
                    Task { @MainActor in
                        HapticManager.selectionChanged()
                    }
                }
            }

            Button("View Info") {
                presentModelInfo()
            }

            Button("Agent Tool Access") {
                showingAgentCapabilities = true
            }

            Button("Delete", role: .destructive) {
                deleteModel()
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showingAgentCapabilities) {
            ModelAgentCapabilitiesSheet(model: model)
        }
    }

    private func loadModel() {
        Task {
            do {
                try await ModelRunner.shared.loadModel(
                    catalogId: model.catalogId,
                    contextLength: model.runtimeContextLength,
                    gpuLayers: AppSettings.shared.gpuLayers
                )
                await MainActor.run {
                    HapticManager.notification(.success)
                }
            } catch {
                viewModel.errorMessage = error.localizedDescription
                viewModel.showError = true
                await MainActor.run {
                    HapticManager.notification(.error)
                }
            }
        }
    }

    private func presentModelInfo() {
        let effectiveCapabilities = AgentToolRuntime.shared.effectiveCapabilitiesPreview(for: model) ?? model.effectiveAgentCapabilities
        var details = [
            "Model: \(model.displayName)",
            "Backend: \(model.backendDisplayName)",
            "Quantization: \(model.quantization)",
            "Context: \(model.runtimeContextLength)",
            "Identifier: \(model.catalogId)",
            "Build Variant: \(AppSettings.shared.buildVariant.title)"
        ]

        if model.backendKind == .ggufLlama {
            details.append("Validation: \(model.effectiveValidationStatus.rawValue)")
        }

        details.append("Agent Override: \(model.hasAgentCapabilityOverride ? "Manual" : "Default")")
        details.append("Agent Browser Read: \(effectiveCapabilities.browserRead ? "On" : "Off")")
        details.append("Agent Workspace Write: \(effectiveCapabilities.workspaceWrite ? "On" : "Off")")
        details.append("Agent GitHub Access: \(effectiveCapabilities.githubAccess ? "On" : "Off")")
        details.append("Agent Swift Runtime: \(effectiveCapabilities.swiftRuntime ? "On" : "Off")")
        details.append("Agent Managed Relay: \(effectiveCapabilities.managedRelayAccess ? "On" : "Off")")
        details.append("Agent Bundle Edits: \(effectiveCapabilities.bundleEdits ? "On" : "Off")")

        if let runtimeAvailabilityMessage = model.runtimeAvailabilityMessage {
            details.append(runtimeAvailabilityMessage)
        }

        viewModel.alertTitle = "Model Info"
        viewModel.errorMessage = details.joined(separator: "\n")
        viewModel.showError = true
    }

    private func revalidateModel() {
        Task {
            let validatedSnapshot = await ModelRunner.shared.validateModel(catalogId: model.catalogId)
            viewModel.alertTitle = "Validation"
            viewModel.errorMessage = validatedSnapshot?.validationSummary
                ?? "Validation finished with no additional details."
            viewModel.showError = true

            await MainActor.run {
                HapticManager.notification(validatedSnapshot?.isValidatedRunnable == true ? .success : .error)
            }
        }
    }

    private func deleteModel() {
        Task {
            let didDelete = await ModelStorage.shared.deleteModel(catalogId: model.catalogId)
            if didDelete {
                await MainActor.run {
                    HapticManager.notification(.warning)
                }
            }
        }
    }
}

private struct ModelBadge: View {
    let text: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
            Text(text)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous)
                .fill(.thinMaterial)
        )
    }
}

private struct FlowLayout<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder var content: Content

    init(spacing: CGFloat = 8, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        HStack(spacing: spacing) {
            content
            Spacer(minLength: 0)
        }
    }
}

@MainActor
struct ModelAgentCapabilitiesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var settings = AppSettings.shared

    let model: ModelSnapshot

    private var runtimeCapabilities: AgentCapabilityProfile {
        AgentToolRuntime.shared.runtimeCapabilityPreview()
    }

    private var runtimePackages: [String: RuntimePackageRecord] {
        Dictionary(
            uniqueKeysWithValues: AgentToolRuntime.shared
                .runtimePackagePreview(for: model)
                .map { ($0.id, $0) }
        )
    }

    private var effectiveCapabilities: ModelAgentCapabilityProfile {
        AgentToolRuntime.shared.effectiveCapabilitiesPreview(for: model) ?? model.effectiveAgentCapabilities
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Model") {
                    capabilityInfoRow(title: "Name", value: model.displayName)
                    capabilityInfoRow(title: "Backend", value: model.backendDisplayName)
                    capabilityInfoRow(title: "Validation", value: model.effectiveValidationStatus.rawValue)
                    capabilityInfoRow(title: "Override", value: model.hasAgentCapabilityOverride ? "Manual" : "Default")
                }

                Section("Runtime") {
                    capabilityInfoRow(title: "Build Variant", value: settings.buildVariant.title)
                    capabilityInfoRow(title: "Runtime Tier", value: runtimeCapabilities.runtimeTier.title)
                    capabilityInfoRow(title: "Embedded Browser", value: runtimePackages["browser"]?.statusTitle ?? "Unknown")
                    capabilityInfoRow(title: "JavaScript", value: runtimePackages["javascriptcore"]?.statusTitle ?? "Unknown")
                    capabilityInfoRow(title: "Python", value: runtimePackages["python"]?.statusTitle ?? "Unknown")
                    capabilityInfoRow(title: "Node", value: runtimePackages["node"]?.statusTitle ?? "Unknown")
                    capabilityInfoRow(title: "Swift", value: runtimePackages["swift"]?.statusTitle ?? "Unknown")
                    capabilityInfoRow(title: "Managed Relay", value: runtimeCapabilities.supportsManagedRelay ? "Available" : "Unavailable")
                    capabilityInfoRow(title: "Live Bundle Editing", value: runtimeCapabilities.supportsLiveBundleEditing ? "Available" : "Unavailable")
                }

                Section("Effective Access") {
                    capabilityInfoRow(title: "Browser Read", value: effectiveCapabilities.browserRead ? "On" : "Off")
                    capabilityInfoRow(title: "Browser Actions", value: effectiveCapabilities.browserActions ? "On" : "Off")
                    capabilityInfoRow(title: "Workspace Write", value: effectiveCapabilities.workspaceWrite ? "On" : "Off")
                    capabilityInfoRow(title: "GitHub Access", value: effectiveCapabilities.githubAccess ? "On" : "Off")
                    capabilityInfoRow(title: "Swift Runtime", value: effectiveCapabilities.swiftRuntime ? "On" : "Off")
                    capabilityInfoRow(title: "Managed Relay", value: effectiveCapabilities.managedRelayAccess ? "On" : "Off")
                    capabilityInfoRow(title: "Remote CI", value: effectiveCapabilities.remoteCI ? "On" : "Off")
                    capabilityInfoRow(title: "Bundle Edits", value: effectiveCapabilities.bundleEdits ? "On" : "Off")
                }

                Section("Overrides") {
                    ForEach(agentCapabilityDefinitions) { definition in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(definition.title)
                                .font(.system(size: 15, weight: .semibold))
                            Text(definition.detail)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            Picker(definition.title, selection: overrideBinding(for: definition.capability)) {
                                ForEach(AgentCapabilityOverrideChoice.allCases) { choice in
                                    Text(choice.title).tag(choice)
                                }
                            }
                            .pickerStyle(.segmented)
                            Text("Policy Default: \(model.conservativeAgentCapabilities.supports(definition.capability) ? "On" : "Off")")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle("Agent Tool Access")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Reset") {
                        settings.setAgentCapabilityOverride(nil, for: model.catalogId)
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func overrideBinding(for capability: AgentToolCapabilityKey) -> Binding<AgentCapabilityOverrideChoice> {
        Binding(
            get: {
                let override = settings.agentCapabilityOverride(for: model.catalogId)
                return AgentCapabilityOverrideChoice(value: override?.value(for: capability))
            },
            set: { newValue in
                var override = settings.agentCapabilityOverride(for: model.catalogId) ?? ModelAgentCapabilityOverride()
                override = override.setting(newValue.optionalBool, for: capability)
                settings.setAgentCapabilityOverride(override, for: model.catalogId)
            }
        )
    }

    @ViewBuilder
    private func capabilityInfoRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }
}

struct EmptyModelsView: View {
    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: 80, height: 80)
                
                Image(systemName: "cube.box")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
            }
            
            Text("No Models Yet")
                .font(.system(size: 20, weight: .bold))
            
            Text("Download GGUF models or import a CoreML package to get started")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, minHeight: 180)
        .padding(.vertical, 18)
    }
}

struct BuiltInAppleModelCard: View {
    @ObservedObject private var settings = AppSettings.shared
    @StateObject private var modelStore = ModelStorage.shared
    @State private var compatibility = CompatibilityReport(
        backendKind: .appleFoundation,
        level: .unknown,
        title: "Checking",
        message: "Checking Apple Intelligence availability on this device."
    )
    @State private var showingAgentCapabilities = false

    private var model: ModelSnapshot {
        modelStore.selectionSnapshots.first(where: \.isBuiltInAppleModel)
            ?? BuiltInModelCatalog.appleOnDeviceModel()
    }

    private var isDefault: Bool {
        model.matchesStoredReference(settings.defaultModelId)
    }

    var body: some View {
        SurfaceSectionCard(
            title: "Apple On-Device AI",
            footer: compatibility.message
        ) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(compatibility.level.tint.opacity(0.16))
                            .frame(width: 46, height: 46)

                        Image(systemName: "apple.logo")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(compatibility.level.tint)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.displayName)
                            .font(.system(size: 18, weight: .semibold))

                        Text("Built into iOS through Apple's Foundation Models framework")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Text(compatibility.title)
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(compatibility.level.tint.opacity(0.18))
                        )
                        .foregroundStyle(compatibility.level.tint)
                }

                HStack(spacing: 10) {
                    ModelFactChip(icon: "apple.logo", text: "Built In")
                    ModelFactChip(icon: "bolt.fill", text: "On Device")
                    ModelFactChip(icon: "sparkles", text: "Apple AI")
                }

                HStack(spacing: 12) {
                    Button(isDefault ? "Default for New Chats" : "Set as Default") {
                        AppSettings.shared.defaultModelId = model.persistentReference
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!compatibility.isUsable || isDefault)

                    if isDefault {
                        Button("Clear Default") {
                            AppSettings.shared.defaultModelId = ""
                        }
                        .buttonStyle(.bordered)
                    }

                    Button("Agent Tools") {
                        showingAgentCapabilities = true
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.vertical, 16)
        }
        .task {
            compatibility = await DeviceCapabilityService.shared.appleFoundationAvailability()
        }
        .sheet(isPresented: $showingAgentCapabilities) {
            ModelAgentCapabilitiesSheet(model: model)
        }
    }
}

struct BrowseMoreCard: View {
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(
                            LinearGradient(
                                colors: [.purple.opacity(0.3), .blue.opacity(0.3)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 60, height: 60)
                    
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.white)
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("Browse Hugging Face")
                        .font(.system(size: 17, weight: .semibold))
                    
                    Text("Find and download GGUF models")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 20)
                            .stroke(.white.opacity(0.1), lineWidth: 0.5)
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

struct ImportLocalModelCard: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(
                            LinearGradient(
                                colors: [.green.opacity(0.28), .cyan.opacity(0.24)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 60, height: 60)

                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Import Local Model")
                        .font(.system(size: 17, weight: .semibold))

                    Text("Bring an existing GGUF file or CoreML package into the app")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 20)
                            .stroke(.white.opacity(0.1), lineWidth: 0.5)
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

struct ModelSearchSheet: View {
    @Environment(\.dismiss) private var dismiss
    
    @StateObject private var searchVM = ModelSearchViewModel()
    @State private var searchText = ""
    
    var body: some View {
        NavigationStack {
            ZStack {
                AnimatedMeshBackground()
                
                List {
                    if searchVM.isSearching {
                        Section {
                            HStack {
                                Spacer()
                                ProgressView()
                                    .scaleEffect(1.2)
                                Spacer()
                            }
                            .padding(.vertical, 40)
                            .listRowBackground(Color.clear)
                        }
                    } else if searchText.isEmpty {
                        Section {
                            DeviceCapabilityCard(profile: searchVM.deviceProfile)
                                .listRowBackground(Color.clear)
                        } header: {
                            Text("This Device")
                        }

                        Section {
                            if searchVM.isLoadingRecommendations {
                                HStack {
                                    Spacer()
                                    ProgressView()
                                    Spacer()
                                }
                                .padding(.vertical, 24)
                                .listRowBackground(Color.clear)
                            } else if searchVM.recommendations.isEmpty {
                                VStack(spacing: 12) {
                                    Image(systemName: "sparkles")
                                        .font(.system(size: 42))
                                        .foregroundStyle(.secondary)

                                    Text("No tailored suggestions yet")
                                        .font(.system(size: 19, weight: .bold))

                                    Text("Search any GGUF model below. Compatibility badges in model details will still tell you what is realistic for this phone.")
                                        .font(.system(size: 14))
                                        .foregroundStyle(.secondary)
                                        .multilineTextAlignment(.center)
                                }
                                .frame(maxWidth: .infinity, minHeight: 180)
                                .padding(.vertical, 20)
                                .listRowBackground(Color.clear)
                            } else {
                                ForEach(searchVM.recommendations) { recommendation in
                                    RecommendedModelRow(recommendation: recommendation, viewModel: searchVM)
                                }
                            }
                        } header: {
                            Text("Recommended Downloads")
                        } footer: {
                            Text("These suggestions use the live device profile on this iPhone or iPad, including RAM budget and runtime availability. You can still search for and download any model.")
                        }
                    } else if searchVM.results.isEmpty {
                        Section {
                            VStack(spacing: 12) {
                                Spacer()
                                
                                Image(systemName: "magnifyingglass.circle")
                                    .font(.system(size: 50))
                                    .foregroundStyle(.secondary)
                                
                                Text("No Results")
                                    .font(.system(size: 20, weight: .bold))
                                
                                Text("Try a different search term")
                                    .font(.system(size: 15))
                                    .foregroundStyle(.secondary)
                                
                                Spacer()
                            }
                            .frame(maxWidth: .infinity, minHeight: 300)
                            .listRowBackground(Color.clear)
                        }
                    } else {
                        Section {
                            ForEach(searchVM.results) { model in
                                SearchResultRow(model: model, viewModel: searchVM)
                            }
                        } header: {
                            Text("Search Results")
                        }
                        .listRowBackground(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(.ultraThinMaterial)
                        )
                        .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Find Models")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Search models (e.g., llama, mistral)")
            .onSubmit(of: .search) {
                Task {
                    await searchVM.search(query: searchText)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(searchVM.isDownloading)
                }
            }
            .task {
                await searchVM.loadRecommendationsIfNeeded()
            }
            .alert(searchVM.downloadErrorTitle, isPresented: Binding(
                get: { searchVM.downloadError != nil },
                set: { if !$0 { searchVM.downloadError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(searchVM.downloadError ?? "")
            }
            .sheet(item: $searchVM.selectedModel) { model in
                ModelDetailSheet(model: model, viewModel: searchVM)
            }
        }
        .interactiveDismissDisabled(searchVM.isDownloading)
    }
}

struct SearchResultRow: View {
    let model: HuggingFaceModel
    @ObservedObject var viewModel: ModelSearchViewModel
    
    var body: some View {
        Button {
            viewModel.selectedModel = model
        } label: {
            HStack(spacing: 14) {
                HuggingFaceAvatarView(model: model, size: 52, cornerRadius: 14)

                VStack(alignment: .leading, spacing: 6) {
                    Text(model.displayName)
                        .font(.system(size: 16, weight: .semibold))
                        .lineLimit(1)

                    Text(model.organization)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)

                    HStack(spacing: 8) {
                        if let downloads = model.downloads {
                            SearchRowChip(text: formatNumber(downloads), icon: "arrow.down.circle.fill")
                        }

                        if let likes = model.likes {
                            SearchRowChip(text: formatNumber(likes), icon: "heart.fill")
                        }

                        SearchRowChip(text: "GGUF", icon: "shippingbox.fill", tint: .blue)
                    }

                    if !model.repositoryAssessment.warningBadges.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(model.repositoryAssessment.warningBadges, id: \.self) { badge in
                                SearchRowChip(text: badge, icon: "exclamationmark.triangle.fill", tint: .orange)
                            }
                        }
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(.thickMaterial))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.white.opacity(0.18), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.10), radius: 10, x: 0, y: 5)
        }
        .buttonStyle(.plain)
        .padding(.vertical, 6)
        .disabled(viewModel.isDownloading)
    }
    
    func formatNumber(_ num: Int) -> String {
        if num >= 1_000_000 {
            return String(format: "%.1fM", Double(num) / 1_000_000)
        } else if num >= 1_000 {
            return String(format: "%.1fk", Double(num) / 1_000)
        }
        return "\(num)"
    }
}

struct ModelDetailSheet: View {
    let model: HuggingFaceModel
    @ObservedObject var viewModel: ModelSearchViewModel
    @Environment(\.dismiss) private var dismiss
    private var modelURL: URL? { URL(string: "https://huggingface.co/\(model.modelId)") }
    
    var body: some View {
        NavigationStack {
            ZStack {
                AnimatedMeshBackground()
                
                List {
                    // Model Info
                    Section {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 12) {
                                HuggingFaceAvatarView(model: model, size: 58, cornerRadius: 16)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(model.displayName)
                                        .font(.system(size: 24, weight: .bold))

                                    Text(model.organization)
                                        .font(.system(size: 17))
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()
                            }

                            if let description = model.description {
                                Text(description)
                                    .font(.system(size: 15))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(4)
                            }

                            if !model.repositoryAssessment.warningBadges.isEmpty {
                                HStack(spacing: 8) {
                                    ForEach(model.repositoryAssessment.warningBadges, id: \.self) { badge in
                                        Text(badge)
                                            .font(.system(size: 11, weight: .semibold))
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                            .background(
                                                Capsule()
                                                    .fill(Color.orange.opacity(0.16))
                                            )
                                            .foregroundStyle(.orange)
                                    }
                                }
                            }

                            Text(model.repositoryAssessment.reason)
                                .font(.system(size: 13))
                                .foregroundStyle(
                                    model.repositoryAssessment.warningBadges.isEmpty
                                        ? Color.secondary
                                        : Color.orange
                                )
                            
                            HStack(spacing: 16) {
                                if let downloads = model.downloads {
                                    StatBadge(value: formatNumber(downloads), label: "Downloads", icon: "arrow.down")
                                }
                                
                                if let likes = model.likes {
                                    StatBadge(value: formatNumber(likes), label: "Likes", icon: "heart")
                                }
                            }

                            if let modelURL {
                                Link(destination: modelURL) {
                                    Label("View on Hugging Face", systemImage: "safari")
                                        .font(.system(size: 14, weight: .semibold))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 10)
                                        .background(
                                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                                .fill(Color.accentColor.opacity(0.14))
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 8)
                    }
                    .listRowBackground(Color.clear)
                    
                    // GGUF Files
                    Section {
                        if viewModel.isLoadingFiles {
                            HStack {
                                Spacer()
                                ProgressView()
                                Spacer()
                            }
                            .padding(.vertical, 20)
                        } else if viewModel.availableFiles.isEmpty {
                            Text("No GGUF files found")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 20)
                        } else {
                            ForEach(viewModel.availableFiles) { file in
                                GGUFFileRow(
                                    file: file,
                                    compatibility: viewModel.deviceProfile.compatibility(for: file.size),
                                    viewModel: viewModel
                                ) {
                                    viewModel.requestDownload(file, modelId: model.modelId)
                                }
                            }
                        }
                    } header: {
                        Text("Available Files")
                    }
                    .listRowBackground(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(.ultraThinMaterial)
                    )
                    .listRowSeparator(.hidden)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Model Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .disabled(viewModel.isDownloading)
                }
            }
            .task {
                await viewModel.loadFiles(for: model.modelId)
            }
            .alert(item: $viewModel.pendingDownloadWarning) { warning in
                Alert(
                    title: Text(warning.title),
                    message: Text(warning.message),
                    primaryButton: .default(Text("Download Anyway")) {
                        viewModel.confirmPendingDownload()
                    },
                    secondaryButton: .cancel {
                        viewModel.cancelPendingDownload()
                    }
                )
            }
        }
        .interactiveDismissDisabled(viewModel.isDownloading)
    }
    
    func formatNumber(_ num: Int) -> String {
        if num >= 1_000_000 {
            return String(format: "%.1fM", Double(num) / 1_000_000)
        } else if num >= 1_000 {
            return String(format: "%.1fk", Double(num) / 1_000)
        }
        return "\(num)"
    }
}

private struct SearchRowChip: View {
    let text: String
    let icon: String
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
            Text(text)
                .font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(tint.opacity(0.12))
        )
    }
}

private struct HuggingFaceAvatarView: View {
    let model: HuggingFaceModel
    let size: CGFloat
    let cornerRadius: CGFloat

    private var organizationHandle: String? {
        let base = model.author?.nonEmpty ?? model.organization.nonEmpty
        guard let base else { return nil }
        return base
            .split(separator: "/")
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var avatarURL: URL? {
        guard let handle = organizationHandle?.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            return nil
        }
        return URL(string: "https://huggingface.co/\(handle)/avatar")
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(.ultraThinMaterial)
                .frame(width: size, height: size)

            AsyncImage(url: avatarURL) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                        .frame(width: size, height: size)
                        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                default:
                    Image(systemName: "cube")
                        .font(.system(size: size * 0.4, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
        .frame(width: size, height: size)
    }
}

struct StatBadge: View {
    let value: String
    let label: String
    let icon: String
    
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 12))
            
            VStack(alignment: .leading, spacing: 0) {
                Text(value)
                    .font(.system(size: 14, weight: .semibold))
                Text(label)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.ultraThinMaterial)
        )
    }
}

struct GGUFFileRow: View {
    let file: GGUFInfo
    let compatibility: ModelFileCompatibility
    @ObservedObject var viewModel: ModelSearchViewModel
    let downloadAction: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(file.displayName)
                        .font(.system(size: 16, weight: .semibold))
                        .lineLimit(2)

                    HStack(spacing: 8) {
                        if let quant = file.quantization {
                            ModelBadge(text: quant, systemImage: "cpu")
                        }

                        if let size = file.size {
                            ModelBadge(
                                text: ByteCountFormatter.string(fromByteCount: size, countStyle: .file),
                                systemImage: "externaldrive"
                            )
                        }
                    }
                }

                Spacer(minLength: 8)

                CompatibilityBadge(compatibility: compatibility)
            }

            if viewModel.isDownloading && viewModel.downloadingFile?.url == file.url {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Downloading…")
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                        Text("\(viewModel.downloadProgress)%")
                            .font(.system(size: 13, weight: .semibold))
                    }

                    ProgressView(value: Double(viewModel.downloadProgress) / 100.0)

                    HStack {
                        Text(viewModel.downloadBytes)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Spacer()
                        if !viewModel.downloadSpeed.isEmpty {
                            Text(viewModel.downloadSpeed)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        if !viewModel.downloadEta.isEmpty {
                            Text(viewModel.downloadEta)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }

                    Button {
                        viewModel.cancelCurrentDownload()
                    } label: {
                        Label("Cancel Download", systemImage: "xmark.circle.fill")
                            .font(.system(size: 14, weight: .medium))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            } else {
                Button(action: downloadAction) {
                    Label("Download", systemImage: "arrow.down.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isDownloading)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(.white.opacity(0.12), lineWidth: 0.5)
                )
        )
        .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }
}

@MainActor
class ModelsViewModel: ObservableObject {
    @Published var showError = false
    @Published var alertTitle = "Error"
    @Published var errorMessage = ""

    func importLocalModel(from sourceURL: URL) async {
        let startedAccessing = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if startedAccessing {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let importedModel: ModelSnapshot
            let isDirectory = sourceURL.hasDirectoryPath
            let fileExtension = sourceURL.pathExtension.lowercased()

            if fileExtension == "gguf" {
                importedModel = try await ModelStorage.shared.importGGUFModel(from: sourceURL)
            } else if isDirectory || fileExtension == "mlpackage" || fileExtension == "mlmodelc" {
                importedModel = try await ModelStorage.shared.importCoreMLPackage(from: sourceURL)
            } else {
                throw InferenceError.importFailed("Choose a GGUF file or a CoreML package folder.")
            }

            alertTitle = "Model Imported"
            if importedModel.backendKind == .coreMLPackage {
                if importedModel.hasRunnableCoreMLPayload {
                    errorMessage = "\(importedModel.displayName) is ready to load as a CoreML chat model."
                } else {
                    errorMessage = "\(importedModel.displayName) was imported, but it is missing runnable ANEMLL/CoreML metadata. Import the full model folder, not only a compiled bundle."
                }
            } else if importedModel.backendKind == .ggufLlama {
                if importedModel.isValidatedRunnable {
                    errorMessage = "\(importedModel.displayName) is ready to use."
                } else {
                    alertTitle = "Validation Failed"
                    errorMessage = importedModel.validationSummary
                        ?? "\(importedModel.displayName) imported successfully, but it failed validation on this device."
                }
            } else {
                errorMessage = "\(importedModel.displayName) is ready to use."
            }
            showError = true
            HapticManager.notification(
                importedModel.backendKind == .ggufLlama && !importedModel.isValidatedRunnable
                    ? .error
                    : .success
            )
        } catch {
            alertTitle = "Import Failed"
            errorMessage = error.localizedDescription
            showError = true
            HapticManager.notification(.error)
        }
    }
}

@MainActor
class ModelSearchViewModel: ObservableObject {
    @Published var deviceProfile = DeviceCapabilityProfile.placeholder
    @Published var results: [HuggingFaceModel] = []
    @Published var isSearching = false
    @Published var selectedModel: HuggingFaceModel?
    
    @Published var availableFiles: [GGUFInfo] = []
    @Published var isLoadingFiles = false

    @Published var recommendations: [ModelRecommendation] = []
    @Published var isLoadingRecommendations = false
    
    @Published var isDownloading = false
    @Published var downloadingFile: GGUFInfo?
    @Published var downloadStartTime = Date()
    @Published var downloadProgress = 0
    @Published var downloadSpeed: String = ""
    @Published var downloadEta: String = ""
    @Published var downloadBytes: String = ""
    @Published var downloadErrorTitle = "Download Failed"
    @Published var downloadError: String?
    @Published var pendingDownloadWarning: ModelDownloadWarning?

    private var searchRequestID = UUID()
    private var filesRequestID = UUID()
    private var recommendationsRequestID = UUID()
    private var runtimeProfile = DeviceCapabilityProfile.placeholder.runtimeProfile

    init() {
        Task {
            await refreshDeviceProfile()
            await loadRecommendationsIfNeeded()
        }
    }
    
    func search(query: String) async {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestID = UUID()
        searchRequestID = requestID

        guard !trimmedQuery.isEmpty else {
            results = []
            isSearching = false
            return
        }

        isSearching = true
        
        do {
            let fetchedResults = try await HuggingFaceService.shared.searchModelsDetailed(query: trimmedQuery)
            guard searchRequestID == requestID else { return }
            results = fetchedResults
        } catch {
            guard searchRequestID == requestID else { return }
            results = []
        }

        guard searchRequestID == requestID else { return }
        isSearching = false
    }
    
    func loadFiles(for modelId: String) async {
        let requestID = UUID()
        filesRequestID = requestID
        availableFiles = []
        isLoadingFiles = true
        
        do {
            let files = try await HuggingFaceService.shared.getModelFiles(modelId: modelId)
            guard filesRequestID == requestID else { return }
            availableFiles = files
        } catch {
            guard filesRequestID == requestID else { return }
            availableFiles = []
        }

        guard filesRequestID == requestID else { return }
        isLoadingFiles = false
    }

    func loadRecommendationsIfNeeded() async {
        guard recommendations.isEmpty, !isLoadingRecommendations else { return }

        let requestID = UUID()
        recommendationsRequestID = requestID
        isLoadingRecommendations = true
        defer {
            if recommendationsRequestID == requestID {
                isLoadingRecommendations = false
            }
        }

        do {
            let suggestedCandidates = try await HuggingFaceService.shared.recommendedModels(
                runtimeProfile: runtimeProfile,
                limit: 6,
                sourceLimit: 18
            )
            guard recommendationsRequestID == requestID else { return }

            recommendations = suggestedCandidates.map(ModelRecommendation.init(candidate:))
        } catch {
            guard recommendationsRequestID == requestID else { return }
            recommendations = []
        }
    }
    
    func downloadFile(_ file: GGUFInfo, modelId: String) async {
        downloadErrorTitle = "Download Failed"
        downloadError = nil
        isDownloading = true
        downloadingFile = file
        downloadProgress = 0
        downloadSpeed = ""
        downloadEta = ""
        downloadBytes = ""
        downloadStartTime = Date()

        defer {
            isDownloading = false
            downloadingFile = nil
        }

        do {
            let model = try await HuggingFaceService.shared.downloadModel(
                from: file.url,
                filename: file.filename,
                modelId: modelId
            ) { progress in
                Task { @MainActor in
                    self.downloadProgress = progress.percentage
                    self.downloadBytes = "\(progress.formattedDownloaded) / \(progress.formattedTotal)"
                    if progress.speed > 0 {
                        self.downloadSpeed = ByteCountFormatter.string(fromByteCount: Int64(progress.speed), countStyle: .file) + "/s"
                        let remaining = Int64((1.0 - progress.progress) / progress.progress * (Double(Date().timeIntervalSince1970) - self.downloadStartTime.timeIntervalSince1970))
                        if remaining > 0 && remaining < 86400 {
                            let mins = Int(remaining) / 60
                            let secs = Int(remaining) % 60
                            self.downloadEta = "\(mins)m \(secs)s remaining"
                        } else {
                            self.downloadEta = ""
                        }
                    }
                }
            }

            await ModelStorage.shared.upsertDownloadedModel(model.registrySeed)
            if let snapshot = ModelStorage.shared.snapshot(name: model.apiIdentifier),
               snapshot.backendKind == .ggufLlama,
               !snapshot.isValidatedRunnable
            {
                downloadErrorTitle = "Validation Failed"
                downloadError = snapshot.validationSummary
                    ?? "\(snapshot.displayName) downloaded, but it failed validation on this device."
                HapticManager.notification(.error)
                return
            }
            downloadProgress = 100
            HapticManager.notification(.success)
        } catch {
            if isCancellationError(error) {
                downloadProgress = 0
                HapticManager.impact(.medium)
                return
            }

            downloadError = error.localizedDescription
            HapticManager.notification(.error)
        }
    }

    func requestDownload(_ file: GGUFInfo, modelId: String) {
        let compatibility = deviceProfile.compatibility(for: file.size)

        switch compatibility {
        case .recommended, .unknown:
            Task {
                await downloadFile(file, modelId: modelId)
            }
        case .supported, .tooLarge:
            pendingDownloadWarning = ModelDownloadWarning(
                file: file,
                modelId: modelId,
                compatibility: compatibility,
                profile: deviceProfile
            )
        }
    }

    func confirmPendingDownload() {
        guard let pendingDownloadWarning else { return }
        self.pendingDownloadWarning = nil

        Task {
            await downloadFile(pendingDownloadWarning.file, modelId: pendingDownloadWarning.modelId)
        }
    }

    func cancelPendingDownload() {
        pendingDownloadWarning = nil
    }

    func cancelCurrentDownload() {
        guard let downloadingFile else { return }
        Task {
            await HuggingFaceService.shared.cancelDownload(id: downloadingFile.id)
        }
    }

    private func isCancellationError(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }

        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    private func refreshDeviceProfile() async {
        let profile = await DeviceCapabilityService.shared.currentRuntimeProfile()
        let appleAvailability = await DeviceCapabilityService.shared.appleFoundationAvailability()
        runtimeProfile = profile
        deviceProfile = DeviceCapabilityProfile(runtimeProfile: profile, appleAvailability: appleAvailability)
    }
}

struct DeviceCapabilityCard: View {
    let profile: DeviceCapabilityProfile

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(profile.deviceLabel)
                        .font(.system(size: 18, weight: .semibold))

                    Text("\(profile.chipFamily) • \(profile.formattedPhysicalMemory) RAM • iOS \(profile.systemVersion)")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)

                    Text(profile.metalSummary)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: profile.deviceIconName)
                    .font(.system(size: 28))
                    .foregroundStyle(Color.accentColor)
            }

            Text("Suggested models are filtered against this device profile. GGUF files up to \(profile.formattedRecommendedBudget) are preferred, and files up to \(profile.formattedSupportedBudget) may still load with more risk.")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)

            Text(profile.appleFoundationSummary)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(.white.opacity(0.1), lineWidth: 0.5)
                )
        )
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

struct RecommendedModelRow: View {
    let recommendation: ModelRecommendation
    @ObservedObject var viewModel: ModelSearchViewModel

    var body: some View {
        Button {
            viewModel.selectedModel = recommendation.model
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.ultraThinMaterial)
                        .frame(width: 50, height: 50)

                    Image(systemName: "sparkles")
                        .font(.system(size: 20))
                        .foregroundStyle(Color.accentColor)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(recommendation.model.displayName)
                        .font(.system(size: 16, weight: .medium))
                        .lineLimit(1)

                    Text(recommendation.suggestedFile.filename)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    HStack(spacing: 8) {
                        if let quantization = recommendation.suggestedFile.quantization {
                            Label(quantization, systemImage: "cpu")
                                .font(.system(size: 12))
                        }

                        if let size = recommendation.suggestedFile.size {
                            Text("•")
                            Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                                .font(.system(size: 12))
                        }

                        CompatibilityBadge(compatibility: recommendation.compatibility)
                    }
                    .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
        .padding(.vertical, 4)
        .disabled(viewModel.isDownloading)
    }
}

struct CompatibilityBadge: View {
    let compatibility: ModelFileCompatibility

    var body: some View {
        Text(compatibility.title)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(compatibility.tint.opacity(0.18))
            )
            .foregroundStyle(compatibility.tint)
    }
}

struct ModelRecommendation: Identifiable {
    let candidate: HuggingFaceCandidate

    init(candidate: HuggingFaceCandidate) {
        self.candidate = candidate
    }

    var model: HuggingFaceModel {
        candidate.model
    }

    var suggestedFile: GGUFInfo {
        candidate.file
    }

    var compatibility: ModelFileCompatibility {
        ModelFileCompatibility(level: candidate.compatibility.level)
    }

    var assessment: HuggingFaceRepositoryAssessment {
        candidate.assessment
    }

    var id: String {
        candidate.id
    }
}

struct ModelDownloadWarning: Identifiable {
    let file: GGUFInfo
    let modelId: String
    let compatibility: ModelFileCompatibility
    let profile: DeviceCapabilityProfile

    var id: String {
        "\(modelId)#\(file.id)"
    }

    var title: String {
        switch compatibility {
        case .supported:
            return "Large Model Download"
        case .tooLarge:
            return "Model May Not Fit"
        case .recommended, .unknown:
            return "Download Model"
        }
    }

    var message: String {
        let filename = file.filename
        let recommendedBudget = profile.formattedRecommendedBudget
        let supportedBudget = profile.formattedSupportedBudget
        let fileSize = file.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "unknown size"

        switch compatibility {
        case .supported:
            return "\(filename) (\(fileSize)) is larger than the recommended budget for \(profile.deviceLabel). It may still run, but it can be slower and unload more often.\n\nRecommended: up to \(recommendedBudget)\nMay run: up to \(supportedBudget)"
        case .tooLarge:
            return "\(filename) (\(fileSize)) is above the likely working size for \(profile.deviceLabel). You can still download it, but it may fail to load or run poorly.\n\nRecommended: up to \(recommendedBudget)\nMay run: up to \(supportedBudget)"
        case .recommended, .unknown:
            return "Download \(filename)?"
        }
    }
}

enum ModelFileCompatibility {
    case recommended
    case supported
    case tooLarge
    case unknown

    var title: String {
        switch self {
        case .recommended:
            return "Recommended"
        case .supported:
            return "May Run"
        case .tooLarge:
            return "Too Large"
        case .unknown:
            return "Unknown"
        }
    }

    var tint: Color {
        switch self {
        case .recommended:
            return .green
        case .supported:
            return .orange
        case .tooLarge:
            return .red
        case .unknown:
            return .secondary
        }
    }

    var sortRank: Int {
        switch self {
        case .recommended:
            return 0
        case .supported:
            return 1
        case .unknown:
            return 2
        case .tooLarge:
            return 3
        }
    }

    init(level: ModelCompatibilityLevel) {
        switch level {
        case .recommended:
            self = .recommended
        case .supported:
            self = .supported
        case .unavailable:
            self = .tooLarge
        case .unknown:
            self = .unknown
        }
    }
}

struct DeviceCapabilityProfile {
    let runtimeProfile: DeviceRuntimeProfile
    let appleFoundationTitle: String
    let appleFoundationMessage: String

    init(runtimeProfile: DeviceRuntimeProfile, appleAvailability: CompatibilityReport) {
        self.runtimeProfile = runtimeProfile
        self.appleFoundationTitle = appleAvailability.title
        self.appleFoundationMessage = appleAvailability.message
    }

    static let placeholder = DeviceCapabilityProfile(
        runtimeProfile: DeviceRuntimeProfile(
            machineIdentifier: "unknown",
            chipFamily: "Apple Silicon",
            systemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            physicalMemoryBytes: Int64(ProcessInfo.processInfo.physicalMemory),
            interfaceKind: .other,
            recommendedGGUFBudgetBytes: 2_000_000_000,
            supportedGGUFBudgetBytes: 3_000_000_000,
            hasMetalDevice: true,
            metalDeviceName: nil
        ),
        appleAvailability: CompatibilityReport(
            backendKind: .appleFoundation,
            level: .unknown,
            title: "Checking",
            message: "Checking Apple Intelligence availability on this device."
        )
    )

    var deviceLabel: String {
        runtimeProfile.deviceLabel
    }

    var machineIdentifier: String {
        runtimeProfile.machineIdentifier
    }

    var chipFamily: String {
        runtimeProfile.chipFamily
    }

    var systemVersion: String {
        runtimeProfile.systemVersion
    }

    var physicalMemoryBytes: Int64 {
        runtimeProfile.physicalMemoryBytes
    }

    var recommendedModelBudgetBytes: Int64 {
        runtimeProfile.recommendedGGUFBudgetBytes
    }

    var supportedModelBudgetBytes: Int64 {
        runtimeProfile.supportedGGUFBudgetBytes
    }

    var formattedPhysicalMemory: String {
        ByteCountFormatter.string(fromByteCount: physicalMemoryBytes, countStyle: .memory)
    }

    var formattedRecommendedBudget: String {
        ByteCountFormatter.string(fromByteCount: recommendedModelBudgetBytes, countStyle: .file)
    }

    var formattedSupportedBudget: String {
        ByteCountFormatter.string(fromByteCount: supportedModelBudgetBytes, countStyle: .file)
    }

    var appleFoundationSummary: String {
        "\(appleFoundationTitle): \(appleFoundationMessage)"
    }

    var metalSummary: String {
        if let metalDeviceName = runtimeProfile.metalDeviceName {
            return "Metal: \(metalDeviceName)"
        }

        return runtimeProfile.hasMetalDevice ? "Metal available" : "Metal unavailable"
    }

    var deviceIconName: String {
        switch runtimeProfile.interfaceKind {
        case .pad:
            return "ipad"
        case .mac:
            return "laptopcomputer"
        case .phone:
            return "iphone.gen3"
        case .other:
            return "cpu"
        }
    }

    func compatibility(for fileSize: Int64?) -> ModelFileCompatibility {
        guard let fileSize else { return .unknown }

        if fileSize <= recommendedModelBudgetBytes {
            return .recommended
        }

        if fileSize <= supportedModelBudgetBytes {
            return .supported
        }

        return .tooLarge
    }
}


private func formatBytes(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useKB, .useMB, .useGB]
    formatter.countStyle = .file
    return formatter.string(fromByteCount: bytes)
}

#Preview {
    ModelsView()
}
