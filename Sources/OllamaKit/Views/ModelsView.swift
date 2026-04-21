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

                    FeaturedModelsSection()

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

    var canAttemptLoadInCurrentBuild: Bool {
        switch backendKind {
        case .ggufLlama:
            return fileExists
        case .coreMLPackage:
            return hasRunnableCoreMLPayload
        case .appleFoundation:
            return true
        }
    }

    var loadActionTitle: String {
        if backendKind == .ggufLlama && !isValidatedRunnable {
            return "Load Anyway"
        }

        return "Load"
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
                return "Not Yet Validated"
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
                ?? (fileExists && !isValidatedRunnable
                    ? "This model has not been confirmed by the app's conservative validation pass yet, but you can still try loading it manually."
                    : nil)
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
                if model.canAttemptLoadInCurrentBuild {
                    Button(model.loadActionTitle) {
                        loadModel()
                    }
                    .buttonStyle(.borderedProminent)
                }

                if AppSettings.shared.defaultModelId != model.persistentReference, model.canAttemptLoadInCurrentBuild {
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
            if model.canAttemptLoadInCurrentBuild {
                Button {
                    loadModel()
                } label: {
                    Label(model.backendKind == .ggufLlama && !model.isValidatedRunnable ? "Load Anyway" : "Load Model", systemImage: "play.circle")
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
            if model.canAttemptLoadInCurrentBuild {
                Button(model.backendKind == .ggufLlama && !model.isValidatedRunnable ? "Load Anyway" : "Load Model") {
                    loadModel()
                }
            }

            if model.backendKind == .ggufLlama {
                Button("Revalidate") {
                    revalidateModel()
                }
            }

            if model.canAttemptLoadInCurrentBuild {
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

            Button("Delete", role: .destructive) {
                deleteModel()
            }
            Button("Cancel", role: .cancel) {}
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

        if let runtimeAvailabilityMessage = model.runtimeAvailabilityMessage {
            details.append(runtimeAvailabilityMessage)
        }

        viewModel.alertTitle = "Model Info"
        viewModel.errorMessage = details.joined(separator: "\n")
        viewModel.showError = true
    }

    private func revalidateModel() {
        if model.importSource == .localImport || model.importSource == .coreMLImport {
            viewModel.alertTitle = "Validation Temporarily Disabled"
            viewModel.errorMessage = "Imported models can currently crash during recalibration on some builds. Remove and re-import the model instead."
            viewModel.showError = true
            HapticManager.notification(.warning)
            return
        }

        Task {
            let validatedSnapshot = await ModelRunner.shared.validateModel(catalogId: model.catalogId)
            viewModel.alertTitle = "Validation"
            viewModel.errorMessage = validatedSnapshot?.validationSummary
                ?? "Validation finished with no additional details."
            viewModel.showError = true

            await MainActor.run {
                switch validatedSnapshot?.effectiveValidationStatus {
                case .validated:
                    HapticManager.notification(.success)
                case .unknown, .pending:
                    HapticManager.notification(.warning)
                default:
                    HapticManager.notification(.error)
                }
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

                }
            }
            .padding(.vertical, 16)
        }
        .task {
            compatibility = await DeviceCapabilityService.shared.appleFoundationAvailability()
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
                                    compatibility: viewModel.deviceProfile.compatibility(for: file),
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
                        // FIX: Capture warning data directly before dismissing alert.
                        // SwiftUI's .alert(item:) can nil out the bound item concurrently
                        // with the button action, causing confirmPendingDownload()'s
                        // guard-let to fail silently and the download never starts.
                        let file = warning.file
                        let modelId = warning.modelId
                        viewModel.pendingDownloadWarning = nil
                        Task {
                            await viewModel.downloadFile(file, modelId: modelId)
                        }
                    },
                    secondaryButton: .cancel {
                        viewModel.pendingDownloadWarning = nil
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
                if importedModel.effectiveValidationStatus == .failed {
                    alertTitle = "Validation Failed"
                    errorMessage = importedModel.validationSummary
                        ?? "\(importedModel.displayName) imported successfully, but it failed validation on this device."
                } else if importedModel.isValidatedRunnable {
                    errorMessage = "\(importedModel.displayName) is ready to use."
                } else {
                    errorMessage = "\(importedModel.displayName) imported successfully. Validation will run when you load the model."
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
            let seed = try await HuggingFaceService.shared.downloadModel(
                from: file.url,
                filename: file.filename,
                modelId: modelId
            ) { progress in
                Task { @MainActor in
                    self.downloadProgress = progress.percentage
                    self.downloadBytes = "\(progress.formattedDownloaded) / \(progress.formattedTotal)"
                    if progress.speed > 0 {
                        self.downloadSpeed = progress.formattedSpeed
                        // FIX: Use speed-based ETA calculation instead of broken ratio formula.
                        // Old formula used elapsed * (1-progress)/progress which gives wildly wrong
                        // results at low progress values. Speed-based is accurate from the start.
                        let remainingBytes = Double(progress.totalBytes - progress.downloadedBytes)
                        let remainingSeconds = Int64(remainingBytes / progress.speed)
                        if remainingSeconds > 0 && remainingSeconds < 86400 {
                            let hours = Int(remainingSeconds) / 3600
                            let mins = (Int(remainingSeconds) % 3600) / 60
                            let secs = Int(remainingSeconds) % 60
                            if hours > 0 {
                                self.downloadEta = "\(hours)h \(mins)m remaining"
                            } else {
                                self.downloadEta = "\(mins)m \(secs)s remaining"
                            }
                        } else {
                            self.downloadEta = ""
                        }
                    }
                }
            }

            // FIX: downloadModel now returns DownloadedModelSeed directly
            // (not a @Model DownloadedModel that would crash off MainActor)
            await ModelStorage.shared.upsertDownloadedModel(seed)
            if let snapshot = ModelStorage.shared.snapshot(name: seed.name),
               snapshot.backendKind == .ggufLlama,
               snapshot.effectiveValidationStatus == .failed
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
        let compatibility = deviceProfile.compatibility(for: file)

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
        guard let pending = pendingDownloadWarning else { return }
        // Capture values before nil-ing to avoid races with SwiftUI's .alert(item:)
        let file = pending.file
        let modelId = pending.modelId
        self.pendingDownloadWarning = nil

        Task {
            await downloadFile(file, modelId: modelId)
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
            return "Download With Caution"
        case .recommended, .unknown:
            return "Download Model"
        }
    }

    var message: String {
        let filename = file.filename
        let recommendedBudget = profile.formattedRecommendedBudget
        let supportedBudget = profile.formattedSupportedBudget
        let fileSize = file.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "unknown size"
        let estimatedWorkingSet = profile.estimatedWorkingSetBytes(for: file)
            .map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .memory) }
            ?? "unknown"

        switch compatibility {
        case .supported:
            return "\(filename) (\(fileSize)) may still run on \(profile.deviceLabel), but the estimated runtime working set is \(estimatedWorkingSet), so expect slower generation or frequent unload/reload cycles.\n\nRecommended file budget: up to \(recommendedBudget)\nMay run file budget: up to \(supportedBudget)"
        case .tooLarge:
            return "\(filename) (\(fileSize)) is above the app's estimated comfort budget for \(profile.deviceLabel), but it may still load depending on current memory pressure and runtime settings. Estimated runtime working set: \(estimatedWorkingSet).\n\nRecommended file budget: up to \(recommendedBudget)\nMay run file budget: up to \(supportedBudget)"
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
            return "Use Caution"
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
            return .orange
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

    func compatibility(for file: GGUFInfo) -> ModelFileCompatibility {
        guard let fileSize = file.size else { return .unknown }

        if let estimatedWorkingSet = estimatedWorkingSetBytes(for: file) {
            let recommendedWorkingSetBudget = Int64(Double(physicalMemoryBytes) * 0.55)
            let supportedWorkingSetBudget = Int64(Double(physicalMemoryBytes) * 0.72)

            if estimatedWorkingSet <= recommendedWorkingSetBudget {
                return .recommended
            }

            if estimatedWorkingSet <= supportedWorkingSetBudget {
                return .supported
            }
        }

        if fileSize <= recommendedModelBudgetBytes {
            return .recommended
        }

        if fileSize <= supportedModelBudgetBytes {
            return .supported
        }

        return .tooLarge
    }

    func estimatedWorkingSetBytes(for file: GGUFInfo) -> Int64? {
        guard let fileSize = file.size else { return nil }

        let quantizationToken = file.quantization?.uppercased() ?? file.filename.uppercased()
        let bytesPerWeight = approximateBytesPerWeight(for: quantizationToken)
        let parameterCountB = inferredParameterCountB(from: file.filename)

        let inferredWeightsBytes: Double
        if let parameterCountB {
            inferredWeightsBytes = parameterCountB * 1_000_000_000 * bytesPerWeight
        } else {
            inferredWeightsBytes = Double(fileSize)
        }

        let loadedWeightsBytes = max(Double(fileSize) * 1.15, inferredWeightsBytes * 1.08)
        let runtimeOverheadBytes = min(max(loadedWeightsBytes * 0.18, 350_000_000), 1_800_000_000)
        let kvCacheBytes: Double
        if let parameterCountB {
            kvCacheBytes = min(max(parameterCountB * 1_000_000_000 * 0.015, 120_000_000), 1_200_000_000)
        } else {
            kvCacheBytes = 350_000_000
        }

        return Int64(loadedWeightsBytes + runtimeOverheadBytes + kvCacheBytes)
    }

    private func inferredParameterCountB(from filename: String) -> Double? {
        let lower = filename.lowercased()
        let patterns = ["([0-9]+(?:\\.[0-9]+)?)b", "([0-9]+(?:\\.[0-9]+)?)m"]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(lower.startIndex..<lower.endIndex, in: lower)
            guard let match = regex.firstMatch(in: lower, range: range),
                  let valueRange = Range(match.range(at: 1), in: lower),
                  let rawValue = Double(lower[valueRange]) else {
                continue
            }

            if pattern.contains("m") {
                return rawValue / 1_000.0
            }
            return rawValue
        }

        return nil
    }

    private func approximateBytesPerWeight(for quantization: String) -> Double {
        switch quantization {
        case let token where token.contains("Q2"):
            return 0.35
        case let token where token.contains("Q3"):
            return 0.45
        case let token where token.contains("Q4"):
            return 0.60
        case let token where token.contains("Q5"):
            return 0.75
        case let token where token.contains("Q6"):
            return 0.90
        case let token where token.contains("Q8"):
            return 1.05
        case let token where token.contains("F16") || token.contains("FP16"):
            return 2.0
        case let token where token.contains("F32") || token.contains("FP32"):
            return 4.0
        default:
            return 1.0
        }
    }
}


private func formatBytes(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useKB, .useMB, .useGB]
    formatter.countStyle = .file
    return formatter.string(fromByteCount: bytes)
}

struct FeaturedModelsSection: View {
    @State private var showingTooltip = false
    // FIX: Single shared ViewModel for all FeaturedModelCards instead of one per card.
    // Previously each card created its own ModelSearchViewModel, causing N concurrent
    // HF API calls (N = number of cards). Now shares one ViewModel.
    @StateObject private var sharedSearchVM = ModelSearchViewModel()

    private let featuredModels: [FeaturedModelInfo] = [
        FeaturedModelInfo(id: "bartowski/Llama-3.2-1B-Instruct-GGUF", displayName: "Llama 3.2 1B", size: "1.3 GB", description: "Ultra-fast, great for everyday tasks"),
        FeaturedModelInfo(id: "bartowski/Llama-3.2-3B-Instruct-GGUF", displayName: "Llama 3.2 3B", size: "2.0 GB", description: "Balanced speed and quality"),
        FeaturedModelInfo(id: "Qwen/Qwen2.5-1.5B-Instruct-GGUF", displayName: "Qwen 2.5 1.5B", size: "1.0 GB", description: "Excellent multilingual support"),
        FeaturedModelInfo(id: "bartowski/Phi-3.5-mini-instruct-GGUF", displayName: "Phi-3.5 Mini", size: "2.3 GB", description: "Strong reasoning in a small package"),
        FeaturedModelInfo(id: "MaziyarPanahi/Mistral-7B-Instruct-v0.3-GGUF", displayName: "Mistral 7B", size: "4.4 GB", description: "Popular open-source model"),
    ]

    var body: some View {
        SurfaceSectionCard(
            title: "Featured Models",
            footer: "Handpicked models that run well on iPhone. Small size, fast inference, great results."
        ) {
            VStack(spacing: 14) {
                // Header with tooltip
                HStack {
                    Text("Recommended for iPhone")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button {
                        showingTooltip.toggle()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "questionmark.circle")
                                .font(.system(size: 12))
                            Text("Why these?")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundStyle(Color.accentColor)
                    }
                }

                if showingTooltip {
                    VStack(alignment: .leading, spacing: 8) {
                        FeatureRow(icon: "smallcircle.fill.circle", text: "Small models (1B–7B parameters)")
                        FeatureRow(icon: "bolt.fill", text: "Fast inference on mobile CPU/GPU")
                        FeatureRow(icon: "iphone", text: "Fits in iPhone RAM budget")
                        FeatureRow(icon: "checkmark.seal.fill", text: "Tested and proven on iOS")
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.accentColor.opacity(0.08))
                    )
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                // Featured model cards
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(featuredModels) { model in
                            FeaturedModelCard(model: model, searchVM: sharedSearchVM)
                        }
                    }
                }
            }
        }
    }
}

struct FeaturedModelInfo: Identifiable {
    let id: String
    let displayName: String
    let size: String
    let description: String

    var modelId: String { id }
}

struct FeatureRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(Color.accentColor)
                .frame(width: 16)
            Text(text)
                .font(.system(size: 13))
        }
    }
}

struct FeaturedModelCard: View {
    let model: FeaturedModelInfo
    // FIX: Injected shared ViewModel instead of creating one per card.
    // Previously each card created @StateObject private var searchVM = ModelSearchViewModel()
    // which caused N concurrent HF API calls for N cards.
    @ObservedObject var searchVM: ModelSearchViewModel
    @State private var isDownloading = false
    @State private var downloadProgress = 0
    @State private var downloadError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(
                            LinearGradient(
                                colors: [.accentColor.opacity(0.3), .purple.opacity(0.2)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 44, height: 44)

                    Image(systemName: "sparkles")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                }

                Spacer()

                // Size badge
                Text(model.size)
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(Color.accentColor.opacity(0.2))
                    )
                    .foregroundStyle(Color.accentColor)
            }

            Text(model.displayName)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(2)

            Text(model.description)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(2)

            if isDownloading {
                VStack(spacing: 6) {
                    ProgressView(value: Double(downloadProgress) / 100.0)
                    Text("\(downloadProgress)%")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            } else if let error = downloadError {
                VStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                    Button("Retry") {
                        downloadError = nil
                        downloadModel()
                    }
                    .font(.system(size: 11, weight: .medium))
                    .controlSize(.small)
                }
            } else {
                Button {
                    downloadModel()
                } label: {
                    Label("Download", systemImage: "arrow.down.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(14)
        .frame(width: 160)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(.white.opacity(0.12), lineWidth: 0.6)
                )
        )
    }

    private func downloadModel() {
        isDownloading = true
        downloadProgress = 0
        downloadError = nil

        Task { @MainActor in
            do {
                // Resolve the GGUF candidate for this featured model
                let runtimeProfile = await DeviceCapabilityService.shared.currentRuntimeProfile()
                let candidate = try await HuggingFaceService.shared.resolvePullCandidate(
                    requestedName: model.id,
                    requestedFilename: nil,
                    runtimeProfile: runtimeProfile
                )

                // Real download with progress
                let seed = try await HuggingFaceService.shared.downloadModel(
                    from: candidate.file.url,
                    filename: candidate.file.filename,
                    modelId: candidate.model.modelId
                ) { progress in
                    Task { @MainActor in
                        self.downloadProgress = progress.percentage
                    }
                }

                // FIX: downloadModel now returns DownloadedModelSeed directly, use it as-is
                await ModelStorage.shared.upsertDownloadedModel(seed)

                HapticManager.notification(.success)
                downloadError = nil
            } catch {
                HapticManager.notification(.error)
                // Show the error so the user knows what went wrong
                let msg = error.localizedDescription
                downloadError = msg.count > 40 ? String(msg.prefix(40)) + "…" : msg
            }

            isDownloading = false
        }
    }
}

#Preview {
    ModelsView()
}
