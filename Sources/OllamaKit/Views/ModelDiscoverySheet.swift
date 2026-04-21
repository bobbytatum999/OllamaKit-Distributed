import SwiftUI
import Foundation

struct ModelDiscoverySheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var searchVM = ModelSearchViewModel()
    @State private var searchText = ""
    @State private var selectedFilter: ModelMenuFilter = .tools
    @FocusState private var isSearchFocused: Bool
    @State private var debouncedSearchTask: Task<Void, Never>?

    private var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isShowingSearchResults: Bool {
        !trimmedSearchText.isEmpty
    }

    private var discoverCards: [DiscoverModelCardViewModel] {
        searchVM.recommendations
            .map { DiscoverModelCardViewModel(recommendation: $0, profile: searchVM.deviceProfile) }
            .filter { selectedFilter.includes(cardsCapabilities: $0.capabilities) }
            .sorted { lhs, rhs in
                if lhs.tier.sortRank != rhs.tier.sortRank {
                    return lhs.tier.sortRank < rhs.tier.sortRank
                }
                if lhs.recommendation.compatibility.sortRank != rhs.recommendation.compatibility.sortRank {
                    return lhs.recommendation.compatibility.sortRank < rhs.recommendation.compatibility.sortRank
                }
                let lhsSize = lhs.recommendation.suggestedFile.size ?? .max
                let rhsSize = rhs.recommendation.suggestedFile.size ?? .max
                if lhsSize != rhsSize {
                    return lhsSize < rhsSize
                }
                return lhs.recommendation.model.displayName.localizedCaseInsensitiveCompare(rhs.recommendation.model.displayName) == .orderedAscending
            }
    }

    private var discoverSections: [DiscoverSectionModel] {
        DiscoverPerformanceTier.allCases.compactMap { tier in
            let cards = discoverCards.filter { $0.tier == tier }
            guard !cards.isEmpty else { return nil }
            return DiscoverSectionModel(tier: tier, cards: cards)
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AnimatedMeshBackground()

                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        DiscoverHeader(
                            selectedFilter: $selectedFilter,
                            dismissAction: { dismiss() }
                        )

                        if isShowingSearchResults {
                            SearchResultsPanel(
                                query: trimmedSearchText,
                                isSearching: searchVM.isSearching,
                                results: searchVM.results,
                                viewModel: searchVM
                            )
                        } else {
                            ForEach(discoverSections) { section in
                                DiscoverSection(section: section, viewModel: searchVM)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 94)
                }
                .scrollIndicators(.hidden)
            }
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .bottom) {
                DiscoverSearchBar(
                    text: $searchText,
                    isFocused: $isSearchFocused,
                    onClear: {
                        debouncedSearchTask?.cancel()
                        searchText = ""
                        searchVM.results = []
                    },
                    onSubmit: {
                        debouncedSearchTask?.cancel()
                        Task {
                            await searchVM.search(query: trimmedSearchText)
                        }
                    }
                )
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color.clear)
            }
            .onChange(of: searchText) { _, newValue in
                debouncedSearchTask?.cancel()
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    searchVM.results = []
                    return
                }
                debouncedSearchTask = Task {
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    guard !Task.isCancelled else { return }
                    await searchVM.search(query: trimmed)
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
            .alert(item: $searchVM.pendingDownloadWarning) { warning in
                Alert(
                    title: Text(warning.title),
                    message: Text(warning.message),
                    primaryButton: .default(Text("Download Anyway")) {
                        let file = warning.file
                        let modelId = warning.modelId
                        searchVM.pendingDownloadWarning = nil
                        Task {
                            await searchVM.downloadFile(file, modelId: modelId)
                        }
                    },
                    secondaryButton: .cancel {
                        searchVM.pendingDownloadWarning = nil
                    }
                )
            }
        }
        .interactiveDismissDisabled(searchVM.isDownloading)
    }
}

private struct DiscoverHeader: View {
    @Binding var selectedFilter: ModelMenuFilter
    let dismissAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                Button(action: dismissAction) {
                    Text("Cancel")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 14)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(
                            Capsule()
                                .stroke(Color.white.opacity(0.14), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)

                Spacer()
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Add an AI model")
                    .font(.system(size: 38, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)

                Text("Based on our recommendations")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.64))
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(ModelMenuFilter.allCases) { filter in
                        Button {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                                selectedFilter = filter
                            }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: filter.icon)
                                    .font(.system(size: 18, weight: .semibold))
                                Text(filter.title)
                                    .font(.system(size: 18, weight: .semibold))
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 12)
                            .background(
                                Capsule()
                                    .fill(selectedFilter == filter ? Color.white.opacity(0.14) : Color.black.opacity(0.22))
                            )
                            .overlay(
                                Capsule()
                                    .stroke(Color.white.opacity(selectedFilter == filter ? 0.22 : 0.08), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
    }
}

private struct DiscoverSearchBar: View {
    @Binding var text: String
    let isFocused: FocusState<Bool>.Binding
    let onClear: () -> Void
    let onSubmit: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(.white.opacity(0.78))

            TextField("Search for a model", text: $text)
                .focused(isFocused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .foregroundStyle(.white)
                .font(.system(size: 21, weight: .medium))
                .onSubmit(onSubmit)

            if !text.isEmpty {
                Button(action: onClear) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.72))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .background(
            Capsule(style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
        )
    }
}

private struct SearchResultsPanel: View {
    let query: String
    let isSearching: Bool
    let results: [HuggingFaceModel]
    @ObservedObject var viewModel: ModelSearchViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Search results")
                .font(.system(size: 28, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)

            Text(query)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white.opacity(0.64))

            if isSearching {
                VStack(spacing: 12) {
                    ProgressView()
                        .scaleEffect(1.2)
                    Text("Looking for the best matches…")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white.opacity(0.68))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 42)
                .background(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(.ultraThinMaterial)
                )
            } else if results.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "magnifyingglass.circle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.white.opacity(0.58))
                    Text("No models matched that search")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                    Text("Try a shorter query or search by model family, like Llama, Gemma, Qwen, or Mistral.")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.68))
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 34)
                .padding(.horizontal, 20)
                .background(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(.ultraThinMaterial)
                )
            } else {
                VStack(spacing: 12) {
                    ForEach(results) { model in
                        SearchResultRow(model: model, viewModel: viewModel)
                    }
                }
            }
        }
    }
}

private struct DiscoverSection: View {
    let section: DiscoverSectionModel
    @ObservedObject var viewModel: ModelSearchViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(section.tier.title)
                .font(.system(size: 28, weight: .heavy, design: .rounded))
                .foregroundStyle(section.tier.headerColor)

            VStack(spacing: 16) {
                ForEach(section.cards) { card in
                    DiscoverModelCard(card: card, viewModel: viewModel)
                }
            }
        }
    }
}

private struct DiscoverModelCard: View {
    let card: DiscoverModelCardViewModel
    @ObservedObject var viewModel: ModelSearchViewModel

    private var isDownloadingThisCard: Bool {
        viewModel.isDownloading && viewModel.downloadingFile?.url == card.recommendation.suggestedFile.url
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                HuggingFaceAvatarView(model: card.recommendation.model, size: 52, cornerRadius: 14)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .center, spacing: 8) {
                        Text(card.title)
                            .font(.system(size: 22, weight: .heavy, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(2)

                        Text(card.sizeLabel)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white.opacity(0.85))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(Color.white.opacity(0.16))
                            )
                    }

                    Text(card.provider)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.white.opacity(0.88))
                }

                Spacer()
            }

            Text(card.subtitle)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(5)

            CapabilityBullets(capabilities: card.capabilities)

            HStack(alignment: .center) {
                if let badge = card.badge {
                    Text(badge.title)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            Capsule(style: .continuous)
                                .fill(badge.color)
                        )
                }

                Spacer(minLength: 12)

                if isDownloadingThisCard {
                    VStack(alignment: .trailing, spacing: 6) {
                        Text("Downloading \(viewModel.downloadProgress)%")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                        ProgressView(value: Double(viewModel.downloadProgress) / 100.0)
                            .tint(.white)
                            .frame(width: 180)
                    }
                } else {
                    Button {
                        viewModel.requestDownload(card.recommendation.suggestedFile, modelId: card.recommendation.model.modelId)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.system(size: 20, weight: .bold))
                            Text("Download (\(card.downloadSizeLabel))")
                                .font(.system(size: 18, weight: .bold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 14)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color.black.opacity(0.28))
                                .overlay(
                                    Capsule(style: .continuous)
                                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                                )
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.isDownloading)
                }
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: card.tier.gradientColors,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(Color.white.opacity(0.10), lineWidth: 1)
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .onTapGesture {
            viewModel.selectedModel = card.recommendation.model
        }
    }
}

private struct CapabilityBullets: View {
    let capabilities: [ModelCardCapability]

    var rows: [[ModelCardCapability]] {
        stride(from: 0, to: min(capabilities.count, 4), by: 2).map { start in
            Array(capabilities[start..<min(start + 2, capabilities.count)])
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 18) {
                    ForEach(row) { capability in
                        HStack(spacing: 8) {
                            Text("•")
                            Text(capability.title)
                                .lineLimit(1)
                        }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }
}

private struct DiscoverSectionModel: Identifiable {
    let tier: DiscoverPerformanceTier
    let cards: [DiscoverModelCardViewModel]

    var id: DiscoverPerformanceTier { tier }
}

private struct DiscoverModelCardViewModel: Identifiable {
    let recommendation: ModelRecommendation
    let tier: DiscoverPerformanceTier
    let capabilities: [ModelCardCapability]

    init(recommendation: ModelRecommendation, profile: DeviceCapabilityProfile) {
        self.recommendation = recommendation
        self.tier = DiscoverPerformanceTier(recommendation: recommendation, profile: profile)
        self.capabilities = ModelCardCapability.infer(from: recommendation)
    }

    var id: String { recommendation.id }

    var title: String {
        recommendation.model.displayName
            .replacingOccurrences(of: "-GGUF", with: "")
            .replacingOccurrences(of: "_", with: " ")
    }

    var provider: String {
        recommendation.model.organization
    }

    var subtitle: String {
        if let description = recommendation.model.description?.trimmingCharacters(in: .whitespacesAndNewlines), !description.isEmpty {
            return description
        }
        return recommendation.assessment.reason
    }

    var sizeLabel: String {
        Self.inferredModelSize(from: [recommendation.model.displayName, recommendation.suggestedFile.filename, recommendation.model.modelId])
            ?? recommendation.suggestedFile.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
            ?? recommendation.model.repositoryMetadata.ggufContextLength.map { "\($0) ctx" }
            ?? "GGUF"
    }

    var downloadSizeLabel: String {
        recommendation.suggestedFile.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "GGUF"
    }

    var badge: DiscoverCardBadge? {
        switch tier {
        case .veryFast, .fast:
            return DiscoverCardBadge(title: "Recommended", color: Color.purple.opacity(0.9))
        case .worksWell, .edge:
            return nil
        case .unsupported:
            return DiscoverCardBadge(title: "Large", color: Color.red.opacity(0.82))
        }
    }

    private static func inferredModelSize(from values: [String]) -> String? {
        for value in values {
            let lower = value.lowercased()
            if let match = capture(lower, pattern: "([0-9]+(?:\\.[0-9]+)?e[0-9]+b)") {
                return match.uppercased()
            }
            if let match = capture(lower, pattern: "([0-9]+(?:\\.[0-9]+)?b)") {
                return match.uppercased()
            }
            if let match = capture(lower, pattern: "([0-9]+(?:\\.[0-9]+)?m)") {
                return match.uppercased()
            }
        }
        return nil
    }

    private static func capture(_ source: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        guard let match = regex.firstMatch(in: source, range: range),
              let captureRange = Range(match.range(at: 1), in: source) else {
            return nil
        }
        return String(source[captureRange])
    }
}

private struct DiscoverCardBadge {
    let title: String
    let color: Color
}

private enum ModelMenuFilter: String, CaseIterable, Identifiable {
    case tools
    case reasoning
    case vision
    case multilingual

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tools: return "Tools"
        case .reasoning: return "Reasoning"
        case .vision: return "Vision"
        case .multilingual: return "Multilingual"
        }
    }

    var icon: String {
        switch self {
        case .tools: return "wrench.and.screwdriver"
        case .reasoning: return "lightbulb"
        case .vision: return "camera.viewfinder"
        case .multilingual: return "globe"
        }
    }

    func includes(cardsCapabilities capabilities: [ModelCardCapability]) -> Bool {
        switch self {
        case .tools:
            return true
        case .reasoning:
            return capabilities.contains { $0.kind == .reasoning }
        case .vision:
            return capabilities.contains { $0.kind == .vision }
        case .multilingual:
            return capabilities.contains { $0.kind == .multilingual }
        }
    }
}

private enum DiscoverPerformanceTier: String, CaseIterable, Identifiable {
    case veryFast
    case fast
    case worksWell
    case edge
    case unsupported

    var id: String { rawValue }

    var sortRank: Int {
        switch self {
        case .veryFast: return 0
        case .fast: return 1
        case .worksWell: return 2
        case .edge: return 3
        case .unsupported: return 4
        }
    }

    var title: String {
        switch self {
        case .veryFast: return "Very fast on this device"
        case .fast: return "Fast on this device"
        case .worksWell: return "Works well on this device"
        case .edge: return "Works at the edge on this device"
        case .unsupported: return "Not supported on this device"
        }
    }

    var headerColor: Color {
        switch self {
        case .veryFast: return Color(red: 0.17, green: 0.92, blue: 0.35)
        case .fast: return Color(red: 0.20, green: 0.56, blue: 1.0)
        case .worksWell: return Color(red: 1.0, green: 0.28, blue: 0.88)
        case .edge: return Color(red: 1.0, green: 0.35, blue: 0.30)
        case .unsupported: return Color(red: 1.0, green: 0.35, blue: 0.35)
        }
    }

    var gradientColors: [Color] {
        switch self {
        case .veryFast:
            return [Color(red: 0.12, green: 0.42, blue: 0.18), Color(red: 0.16, green: 0.92, blue: 0.34)]
        case .fast:
            return [Color(red: 0.15, green: 0.34, blue: 0.74), Color(red: 0.16, green: 0.68, blue: 1.0)]
        case .worksWell:
            return [Color(red: 0.45, green: 0.12, blue: 0.54), Color(red: 0.90, green: 0.22, blue: 0.94)]
        case .edge:
            return [Color(red: 0.60, green: 0.16, blue: 0.14), Color(red: 0.94, green: 0.25, blue: 0.30)]
        case .unsupported:
            return [Color(red: 0.38, green: 0.10, blue: 0.10), Color(red: 0.72, green: 0.16, blue: 0.18)]
        }
    }

    init(recommendation: ModelRecommendation, profile: DeviceCapabilityProfile) {
        let fileSize = recommendation.suggestedFile.size ?? 0
        switch recommendation.compatibility {
        case .recommended:
            let recommendedBudget = max(profile.recommendedModelBudgetBytes, 1)
            if fileSize > 0 && fileSize <= Int64(Double(recommendedBudget) * 0.40) {
                self = .veryFast
            } else if fileSize > 0 && fileSize <= Int64(Double(recommendedBudget) * 0.80) {
                self = .fast
            } else {
                self = .worksWell
            }
        case .supported:
            self = .edge
        case .tooLarge:
            self = .unsupported
        case .unknown:
            self = .worksWell
        }
    }
}

private struct ModelCardCapability: Identifiable, Hashable {
    enum Kind {
        case tools
        case reasoning
        case vision
        case multilingual
        case summarization
        case rolePlay
        case longContext
        case text
    }

    let kind: Kind
    let title: String
    let icon: String

    var id: String { title }

    static func infer(from recommendation: ModelRecommendation) -> [ModelCardCapability] {
        let model = recommendation.model
        let haystack = [
            model.modelId,
            model.displayName,
            model.description ?? "",
            model.pipelineTag ?? "",
            model.libraryName ?? ""
        ]
        .joined(separator: " ")
        .lowercased()

        let tagText = (model.tags ?? []).joined(separator: " ").lowercased()
        var capabilities: [ModelCardCapability] = []

        func add(_ capability: ModelCardCapability) {
            if !capabilities.contains(capability) {
                capabilities.append(capability)
            }
        }

        if haystack.contains("tool") || haystack.contains("function call") || haystack.contains("agent") || tagText.contains("tool") {
            add(.init(kind: .tools, title: "Tool Calls", icon: "wrench.and.screwdriver"))
        }

        if haystack.contains("reason") || haystack.contains("r1") || haystack.contains("thinking") || haystack.contains("deepseek") || tagText.contains("reason") {
            add(.init(kind: .reasoning, title: "Reasoning", icon: "lightbulb"))
        }

        if haystack.contains("vision") || haystack.contains("image") || haystack.contains("vl") || tagText.contains("vision") || tagText.contains("multimodal") {
            add(.init(kind: .vision, title: "Vision", icon: "camera.viewfinder"))
        }

        if haystack.contains("multilingual") || haystack.contains("translate") || tagText.contains("multilingual") {
            add(.init(kind: .multilingual, title: "Multilingual", icon: "globe"))
        }

        if recommendation.model.repositoryMetadata.ggufContextLength ?? 0 >= 32000 {
            add(.init(kind: .longContext, title: "Long Context", icon: "text.badge.plus"))
        }

        if capabilities.isEmpty || recommendation.assessment.isConversational {
            add(.init(kind: .summarization, title: "Summarization", icon: "text.alignleft"))
        }

        if capabilities.count < 4 && (recommendation.suggestedFile.size ?? 0) < 2_500_000_000 {
            add(.init(kind: .rolePlay, title: "Role Play", icon: "person.2"))
        }

        if capabilities.count < 4 {
            add(.init(kind: .text, title: "Text Structuring", icon: "textformat"))
        }

        return Array(capabilities.prefix(4))
    }
}
