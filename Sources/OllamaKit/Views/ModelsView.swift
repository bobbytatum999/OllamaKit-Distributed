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

                    SurfaceSectionCard(
                        title: "Installed Models",
                        footer: installedModels.isEmpty
                            ? "Download GGUF models or import a local GGUF/CoreML package to get started."
                            : "\(installedModels.count) model\(installedModels.count == 1 ? "" : "s") available on this device."
                    ) {
                        if installedModels.isEmpty {
                            EmptyModelsView()
                        } else {
                            VStack(spacing: 0) {
                                ForEach(Array(installedModels.enumerated()), id: \.element.id) { index, model in
                                    DownloadedModelRow(model: model, viewModel: viewModel)

                                    if index < installedModels.count - 1 {
                                        Divider()
                                    }
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
        HStack(spacing: 16) {
            // Model icon
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.ultraThinMaterial)
                    .frame(width: 56, height: 56)
                
                Image(systemName: "cube.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(Color.accentColor)
            }
            
            VStack(alignment: .leading, spacing: 6) {
                Text(model.displayName)
                    .font(.system(size: 17, weight: .semibold))
                
                HStack(spacing: 12) {
                    Label(model.importSourceLabel, systemImage: model.importSourceIcon)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                    Label(model.quantization, systemImage: model.backendKind == .coreMLPackage ? "shippingbox" : "cpu")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                    if model.size > 0 {
                        Text("•")
                            .foregroundStyle(.tertiary)

                        Label(model.formattedSize, systemImage: "externaldrive")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                
                HStack(spacing: 12) {
                    Label("\(model.runtimeContextLength) ctx", systemImage: "text.alignleft")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                    if let runtimeAvailabilityLabel = model.runtimeAvailabilityLabel {
                        Text("•")
                            .foregroundStyle(.tertiary)

                        Label(runtimeAvailabilityLabel, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 12))
                            .foregroundStyle(.orange)
                    }
                }
            }
            
            Spacer()
            
            // Status indicator
            if modelRunner.activeCatalogId == model.catalogId {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.system(size: 22))
            }
            
            Button {
                showingOptions = true
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8)
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
            HStack(spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.ultraThinMaterial)
                        .frame(width: 50, height: 50)
                    
                    Image(systemName: "cube")
                        .font(.system(size: 20))
                        .foregroundStyle(Color.accentColor)
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.displayName)
                        .font(.system(size: 16, weight: .medium))
                        .lineLimit(1)
                    
                    Text(model.organization)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    
                    HStack(spacing: 12) {
                        if let downloads = model.downloads {
                            Label(formatNumber(downloads), systemImage: "arrow.down.circle")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        
                        if let likes = model.likes {
                            Label(formatNumber(likes), systemImage: "heart")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                    }

                    if !model.repositoryAssessment.warningBadges.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(model.repositoryAssessment.warningBadges, id: \.self) { badge in
                                Text(badge)
                                    .font(.system(size: 10, weight: .semibold))
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(
                                        Capsule()
                                            .fill(Color.orange.opacity(0.16))
                                    )
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
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
    
    var body: some View {
        NavigationStack {
            ZStack {
                AnimatedMeshBackground()
                
                List {
                    // Model Info
                    Section {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(model.displayName)
                                .font(.system(size: 24, weight: .bold))
                            
                            Text(model.organization)
                                .font(.system(size: 17))
                                .foregroundStyle(.secondary)
                            
                            if let description = model.description {
                                Text(description)
                                    .font(.system(size: 15))
                                    .foregroundStyle(.secondary)
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
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(file.displayName)
                    .font(.system(size: 15, weight: .medium))
                    .lineLimit(1)
                
                HStack(spacing: 8) {
                    if let quant = file.quantization {
                        Label(quant, systemImage: "cpu")
                            .font(.system(size: 12))
                    }
                    
                    if let size = file.size {
                        Text("•")
                        Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                            .font(.system(size: 12))
                    }

                    CompatibilityBadge(compatibility: compatibility)
                }
                .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            if viewModel.isDownloading && viewModel.downloadingFile?.url == file.url {
                HStack(spacing: 8) {
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("\(viewModel.downloadProgress)%")
                            .font(.system(size: 12, weight: .medium))
                        
                        ProgressView(value: Double(viewModel.downloadProgress) / 100.0)
                            .frame(width: 60)
                    }

                    Button {
                        viewModel.cancelCurrentDownload()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Button(action: downloadAction) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(Color.accentColor)
                }
                .disabled(viewModel.isDownloading)
            }
        }
        .padding(.vertical, 4)
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
    @Published var downloadProgress = 0
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
        HuggingFaceService.shared.cancelDownload(id: downloadingFile.id)
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
        let estimatedWorkingSet = profile.estimatedWorkingSetBytes(for: file)
            .map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .memory) }
            ?? "unknown"

        switch compatibility {
        case .supported:
            return "\(filename) (\(fileSize)) may still run on \(profile.deviceLabel), but the estimated runtime working set is \(estimatedWorkingSet), so expect slower generation or frequent unload/reload cycles.\n\nRecommended file budget: up to \(recommendedBudget)\nMay run file budget: up to \(supportedBudget)"
        case .tooLarge:
            return "\(filename) (\(fileSize)) is likely to fail on \(profile.deviceLabel). Estimated runtime working set: \(estimatedWorkingSet).\n\nRecommended file budget: up to \(recommendedBudget)\nMay run file budget: up to \(supportedBudget)"
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

#Preview {
    ModelsView()
}
