import SwiftUI
import SwiftData
import OllamaCore

struct ChatView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Bindable var session: ChatSession
    
    @StateObject private var modelStore = ModelStorage.shared
    @StateObject private var viewModel = ChatViewModel()
    @State private var messageText = ""
    @State private var showingModelSelector = false
    @State private var showingRenameDialog = false
    @State private var pendingTitle = ""
    @State private var showingParameters = false
    @State private var paramTemperature: Double = 0.7
    @State private var paramTopP: Double = 0.9
    @State private var paramTopK: Int = 40
    @State private var paramRepeatPenalty: Double = 1.1
    @State private var paramMaxTokens: Int = 2048
    
    @Namespace private var bottomID

    private var trimmedMessageText: String {
        messageText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var downloadedModelRevision: [String] {
        modelStore.selectionSnapshots.map {
            "\($0.catalogId)|\($0.modelId)|\($0.localPath)|\($0.packageRootPath)|\($0.effectiveValidationStatus.rawValue)|\($0.isValidatedRunnable)|\($0.canBeSelectedForChat)"
        } + ["apple:\(BuiltInModelCatalog.availability().isAvailable)"]
    }

    private var selectableModels: [ModelSnapshot] {
        BuiltInModelCatalog.selectionModels(downloadedModels: modelStore.selectionSnapshots)
    }

    var body: some View {
        ZStack {
            AnimatedMeshBackground()
            
            VStack(spacing: 0) {
                // Messages List
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 16) {
                            ForEach(session.orderedMessages, id: \.id) { message in
                                MessageBubble(message: message)
                                    .id(message.id)
                            }
                            
                            if viewModel.isGenerating {
                                TypingIndicator()
                                    .id("typing")
                            }
                            
                            Color.clear
                                .frame(height: 1)
                                .id(bottomID)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 16)
                    }
                    .onChange(of: session.orderedMessages.count) {
                        withAnimation {
                            proxy.scrollTo(bottomID, anchor: .bottom)
                        }
                    }
                    .onChange(of: viewModel.isGenerating) {
                        withAnimation {
                            proxy.scrollTo(bottomID, anchor: .bottom)
                        }
                    }
                    .onChange(of: viewModel.streamRevision) {
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo(bottomID, anchor: .bottom)
                        }
                    }
                }
                
                // Input Area
                VStack(spacing: 0) {
                    Divider()
                    
                    HStack(spacing: 12) {
                        // Model selector button
                        Button(action: { showingModelSelector = true }) {
                            HStack(spacing: 6) {
                                Image(systemName: "cube.fill")
                                    .font(.system(size: 12))
                                Text(viewModel.currentModel?.displayName ?? "Select Model")
                                    .font(.system(size: 13, weight: .medium))
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                Capsule()
                                    .fill(.ultraThinMaterial)
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(viewModel.isGenerating)
                        
                        Spacer()
                        
                        if viewModel.isGenerating {
                            Button(action: { viewModel.stopGeneration() }) {
                                Image(systemName: "stop.circle.fill")
                                    .font(.system(size: 24))
                                    .foregroundStyle(.red)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                    HStack(spacing: 12) {
                        TextField("Message", text: $messageText, axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(.system(size: 16))
                            .lineLimit(1...5)
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
                        
                        Button(action: sendMessage) {
                            Image(systemName: trimmedMessageText.isEmpty ? "waveform" : "arrow.up.circle.fill")
                                .font(.system(size: 32))
                                .foregroundStyle(trimmedMessageText.isEmpty ? Color.secondary : Color.accentColor)
                        }
                        .disabled(trimmedMessageText.isEmpty || viewModel.isGenerating)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
                .background(.ultraThinMaterial)
            }
        }
        .navigationTitle(session.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 16) {
                    Button {
                        showingParameters = true
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    
                    Menu {
                        Button {
                            pendingTitle = session.title
                            showingRenameDialog = true
                        } label: {
                            Label("Rename", systemImage: "pencil")
                        }
                        
                        Button {
                            exportChat()
                        } label: {
                            Label("Export as Markdown", systemImage: "square.and.arrow.up")
                        }
                        
                        Button {
                            clearMessages()
                        } label: {
                            Label("Clear Messages", systemImage: "trash")
                        }
                        .disabled(viewModel.isGenerating)
                        
                        Button(role: .destructive) {
                            deleteChat()
                        } label: {
                            Label("Delete Chat", systemImage: "trash")
                        }
                        .disabled(viewModel.isGenerating)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .sheet(isPresented: $showingModelSelector) {
            ModelSelectorSheet(selectedModel: $viewModel.currentModel)
        }
        .sheet(isPresented: $showingParameters) {
            NavigationStack {
                Form {
                    Section("Generation Parameters") {
                        VStack(alignment: .leading) {
                            Text("Temperature: \(paramTemperature, specifier: "%.2f")")
                            Slider(value: $paramTemperature, in: 0...2)
                        }
                        VStack(alignment: .leading) {
                            Text("Top P: \(paramTopP, specifier: "%.2f")")
                            Slider(value: $paramTopP, in: 0...1)
                        }
                        VStack(alignment: .leading) {
                            Text("Top K: \(paramTopK)")
                            Stepper("\(paramTopK)", value: $paramTopK, in: 1...100)
                        }
                        VStack(alignment: .leading) {
                            Text("Repeat Penalty: \(paramRepeatPenalty, specifier: "%.2f")")
                            Slider(value: $paramRepeatPenalty, in: 0...2)
                        }
                        VStack(alignment: .leading) {
                            Text("Max Tokens: \(paramMaxTokens)")
                            Stepper("\(paramMaxTokens)", value: $paramMaxTokens, in: 64...8192, step: 64)
                        }
                    }
                }
                .navigationTitle("Parameters")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { showingParameters = false }
                    }
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Reset") {
                            paramTemperature = 0.7
                            paramTopP = 0.9
                            paramTopK = 40
                            paramRepeatPenalty = 1.1
                            paramMaxTokens = 2048
                        }
                    }
                }
            }
            .presentationDetents([.medium])
        }
        .task {
            await modelStore.refresh()
            syncCurrentModelSelection()
        }
        .onChange(of: downloadedModelRevision) {
            syncCurrentModelSelection()
        }
        .onChange(of: viewModel.currentModel?.id) {
            if let selectedModel = viewModel.currentModel {
                session.modelId = selectedModel.persistentReference
                session.updatedAt = Date()
                try? modelContext.save()
            } else if !session.modelId.isEmpty {
                session.modelId = ""
                session.updatedAt = Date()
                try? modelContext.save()
            }
        }
        .alert("Chat Error", isPresented: Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )) {
            Button("Retry") {
                let lastMsg = viewModel.lastSentMessage
                viewModel.errorMessage = nil
                if !lastMsg.isEmpty {
                    Task { await viewModel.sendMessage(lastMsg, in: session, context: modelContext) }
                }
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .alert("Rename Chat", isPresented: $showingRenameDialog) {
            TextField("Chat Title", text: $pendingTitle)
            Button("Save") {
                let trimmed = pendingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    session.title = trimmed
                    session.updatedAt = Date()
                    try? modelContext.save()
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func clearMessages() {
        AppLogStore.shared.record(
            .chat,
            title: "Chat Cleared",
            message: "Deleted all messages in chat session.",
            metadata: [
                "session_id": session.id.uuidString,
                "message_count": "\(session.orderedMessages.count)"
            ]
        )
        for message in session.orderedMessages {
            modelContext.delete(message)
        }
        session.messages = []
        session.updatedAt = Date()
        try? modelContext.save()
        Task { @MainActor in
            HapticManager.notification(.success)
        }
    }

    private func deleteChat() {
        AppLogStore.shared.record(
            .chat,
            level: .warning,
            title: "Chat Deleted",
            message: "Deleted chat session from local storage.",
            metadata: [
                "session_id": session.id.uuidString,
                "title": session.title
            ]
        )
        modelContext.delete(session)
        try? modelContext.save()
        Task { @MainActor in
            HapticManager.notification(.warning)
        }
        dismiss()
    }
    
    private func sendMessage() {
        let content = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }

        AppLogStore.shared.record(
            .chat,
            title: "User Message Queued",
            message: "Queued a new user message for generation.",
            metadata: [
                "session_id": session.id.uuidString,
                "chars": "\(content.count)"
            ],
            body: content
        )
        messageText = ""

        Task { @MainActor in
            HapticManager.impact(.light)
        }
        
        Task {
            await viewModel.sendMessage(
            content,
            in: session,
            context: modelContext,
            parameters: ModelParameters(
                temperature: Float(paramTemperature),
                topP: Float(paramTopP),
                topK: Int32(paramTopK),
                repeatPenalty: Float(paramRepeatPenalty),
                maxTokens: paramMaxTokens
            )
        )
        }
    }

    private func exportChat() {
        var markdown = "# Chat Export\n\n"
        markdown += "**Date:** \(DateFormatter.localizedString(from: session.createdAt, dateStyle: .long, timeStyle: .short))\n"
        markdown += "**Model ID:** \(session.modelId)\n\n"
        for message in session.orderedMessages {
            let role = message.role == .user ? "**User**" : "**Assistant**"
            markdown += "\(role): \(message.content)\n\n"
        }
        UIPasteboard.general.string = markdown
        Task { @MainActor in
            HapticManager.notification(.success)
        }
    }

    private func syncCurrentModelSelection() {
        if let matchingModel = BuiltInModelCatalog.resolveStoredReference(session.modelId, in: modelStore.selectionSnapshots) {
            if viewModel.currentModel?.id != matchingModel.id {
                viewModel.currentModel = matchingModel
            }
            return
        }

        if !AppSettings.shared.defaultModelId.isEmpty,
           let defaultModel = BuiltInModelCatalog.resolveStoredReference(
                AppSettings.shared.defaultModelId,
                in: modelStore.selectionSnapshots
           ) {
            if viewModel.currentModel?.id != defaultModel.id {
                viewModel.currentModel = defaultModel
            }
            return
        }

        if let fallbackModel = selectableModels.first {
            if viewModel.currentModel?.id != fallbackModel.id {
                viewModel.currentModel = fallbackModel
            }
            return
        }

        if viewModel.currentModel != nil {
            viewModel.currentModel = nil
        }
    }
}

struct MessageBubble: View {
    let message: ChatMessage
    @ObservedObject private var settings = AppSettings.shared
    
    var isUser: Bool {
        message.role == .user
    }

    private var bubbleFillStyle: AnyShapeStyle {
        if isUser {
            return AnyShapeStyle(Color.accentColor)
        }

        return AnyShapeStyle(.ultraThinMaterial)
    }
    
    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 60) }
            
            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                HStack(spacing: 8) {
                    if !isUser {
                        Image(systemName: "cpu")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    
                    Text(isUser ? "You" : "Assistant")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    
                    if isUser {
                        Image(systemName: "person.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                
                if settings.markdownRendering && !isUser {
                    MarkdownText(message.content)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 18)
                                .fill(bubbleFillStyle)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 18)
                                        .stroke(.white.opacity(0.1), lineWidth: 0.5)
                                )
                        )
                        .foregroundStyle(isUser ? .white : .primary)
                } else {
                    Text(message.content)
                        .font(.system(size: 16))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 18)
                                .fill(bubbleFillStyle)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 18)
                                        .stroke(.white.opacity(0.1), lineWidth: 0.5)
                                )
                        )
                        .foregroundStyle(isUser ? .white : .primary)
                }
                
                if (settings.showTokenCount || settings.showGenerationSpeed) && message.tokenCount > 0 {
                    HStack(spacing: 4) {
                        if settings.showTokenCount {
                            Text("\(message.tokenCount) tokens")
                                .font(.system(size: 10))
                        }

                        if settings.showGenerationSpeed && message.generationTime > 0 {
                            if settings.showTokenCount {
                                Text("•")
                            }
                            Text(String(format: "%.1f t/s", Double(message.tokenCount) / message.generationTime))
                                .font(.system(size: 10))
                        }
                    }
                    .foregroundStyle(.tertiary)
                }
            }
            
            if !isUser { Spacer(minLength: 60) }
        }
    }
}

struct MarkdownText: View {
    let text: String
    
    init(_ text: String) {
        self.text = text
    }
    
    var body: some View {
        Text(attributedString)
            .font(.system(size: 16))
    }
    
    private var attributedString: AttributedString {
        if let parsed = try? AttributedString(markdown: text) {
            return parsed
        }

        return AttributedString(text)
    }
}

struct TypingIndicator: View {
    @State private var phase = 0.0
    
    var body: some View {
        HStack {
            HStack(spacing: 4) {
                ForEach(0..<3) { i in
                    Circle()
                        .fill(.secondary)
                        .frame(width: 6, height: 6)
                        .offset(y: sin(phase + Double(i) * 0.5) * 3)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 18)
                    .fill(.ultraThinMaterial)
            )
            
            Spacer(minLength: 60)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.5).repeatForever()) {
                phase = .pi * 2
            }
        }
    }
}

struct ModelSelectorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var modelStore = ModelStorage.shared
    @Binding var selectedModel: ModelSnapshot?

    private var availableModels: [ModelSnapshot] {
        BuiltInModelCatalog.selectionModels(downloadedModels: modelStore.selectionSnapshots)
    }

    private var appleAvailability: BuiltInModelAvailability {
        BuiltInModelCatalog.availability()
    }
    
    var body: some View {
        NavigationStack {
            ZStack {
                AnimatedMeshBackground()
                
                List {
                    if availableModels.isEmpty {
                        Section {
                            VStack(spacing: 12) {
                                Image(systemName: "exclamationmark.triangle")
                                    .font(.system(size: 36))
                                    .foregroundStyle(.secondary)

                                Text("No Runnable Models")
                                    .font(.headline)

                                Text("Download a GGUF model, import a full ANEMLL/CoreML model package, or use Apple On-Device AI if available.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                            .listRowBackground(Color.clear)
                        }
                    } else {
                        ForEach(availableModels) { model in
                            Button {
                                selectedModel = model
                                dismiss()
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(model.displayName)
                                            .font(.system(size: 16, weight: .medium))
                                        
                                        HStack(spacing: 8) {
                                            if model.isBuiltInAppleModel {
                                                Label("Built In", systemImage: "apple.logo")
                                                    .font(.system(size: 12))

                                                Text("•")

                                                Label(appleAvailability.isAvailable ? "On Device" : "Unavailable", systemImage: appleAvailability.isAvailable ? "bolt.fill" : "exclamationmark.triangle.fill")
                                                    .font(.system(size: 12))
                                            } else {
                                                Label(model.quantization, systemImage: "cpu")
                                                    .font(.system(size: 12))
                                                
                                                Text("•")
                                                
                                                Label(model.formattedSize, systemImage: "externaldrive")
                                                    .font(.system(size: 12))
                                            }
                                        }
                                        .foregroundStyle(.secondary)
                                    }
                                    
                                    Spacer()
                                    
                                    if selectedModel?.id == model.id {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(Color.accentColor)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(.ultraThinMaterial)
                            )
                            .listRowSeparator(.hidden)
                            .disabled(model.isBuiltInAppleModel && !appleAvailability.isAvailable)
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Select Model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .task {
            await modelStore.refresh()
        }
    }
}

@MainActor
class ChatViewModel: ObservableObject {
    @Published var isGenerating = false
    @Published var currentModel: ModelSnapshot?
    @Published var errorMessage: String?
    @Published var lastSentMessage: String = ""
    @Published var streamRevision = 0
    
    func sendMessage(_ content: String, in session: ChatSession, context: ModelContext, parameters: ModelParameters = .appDefault) async {
        lastSentMessage = content
        guard let model = currentModel else {
            AppLogStore.shared.record(
                .chat,
                level: .error,
                title: "Message Rejected",
                message: "No runnable model is selected."
            )
            errorMessage = "No runnable model is selected. Pick another validated model or re-download the missing one."
            Task { @MainActor in
                HapticManager.notification(.error)
            }
            return
        }

        let conversationTurns = session.orderedMessages
            .filter { !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { ConversationTurn(role: $0.roleValue, content: $0.content) }
        
        let userMessage = ChatMessage(role: .user, content: content)
        userMessage.session = session
        context.insert(userMessage)
        session.updatedAt = Date()

        try? context.save()

        let assistantMessage = ChatMessage(role: .assistant, content: "", isGenerating: true)
        assistantMessage.session = session
        context.insert(assistantMessage)
        try? context.save()

        isGenerating = true
        streamRevision = 0
        AppLogStore.shared.record(
            .chat,
            title: "Generation Started",
            message: "Started model generation for chat session.",
            metadata: [
                "session_id": session.id.uuidString,
                "model_id": model.catalogId,
                "streaming": "\(AppSettings.shared.streamingEnabled)"
            ]
        )
        defer {
            isGenerating = false
        }

        let parameters = ModelParameters(
            temperature: Float(paramTemperature),
            topP: Float(paramTopP),
            topK: Int32(paramTopK),
            repeatPenalty: Float(paramRepeatPenalty),
            maxTokens: paramMaxTokens
        )
        
        do {
            try await ModelRunner.shared.loadModel(
                catalogId: model.catalogId,
                contextLength: model.runtimeContextLength,
                gpuLayers: AppSettings.shared.gpuLayers
            )

            var generatedText = ""
            let shouldStreamInUI = AppSettings.shared.streamingEnabled

            let result = try await ModelRunner.shared.generate(
                prompt: "",
                systemPrompt: session.systemPrompt,
                conversationTurns: conversationTurns + [ConversationTurn(role: userMessage.roleValue, content: userMessage.content)],
                parameters: parameters
            ) { token in
                guard shouldStreamInUI else { return }
                generatedText += token
                Task { @MainActor in
                    assistantMessage.content = generatedText
                    self.streamRevision += 1
                }
            }
            
            assistantMessage.content = result.text
            assistantMessage.isGenerating = false
            assistantMessage.tokenCount = result.tokensGenerated
            assistantMessage.generationTime = result.generationTime
            streamRevision += 1
            AppLogStore.shared.record(
                .chat,
                title: "Generation Completed",
                message: "Model generation completed.",
                metadata: [
                    "session_id": session.id.uuidString,
                    "model_id": model.catalogId,
                    "tokens": "\(result.tokensGenerated)",
                    "seconds": String(format: "%.2f", result.generationTime),
                    "cancelled": "\(result.wasCancelled)"
                ],
                body: result.text
            )
            
            session.updatedAt = Date()
            try? context.save()
            Task { @MainActor in
                if result.wasCancelled {
                    HapticManager.impact(.medium)
                } else {
                    HapticManager.notification(.success)
                }
            }
            
        } catch {
            if isGenerationCancelled(error) {
                AppLogStore.shared.record(
                    .chat,
                    level: .warning,
                    title: "Generation Cancelled",
                    message: "Generation was cancelled before completion.",
                    metadata: [
                        "session_id": session.id.uuidString,
                        "model_id": model.catalogId
                    ]
                )
                assistantMessage.isGenerating = false
                if assistantMessage.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    context.delete(assistantMessage)
                }
                try? context.save()
                Task { @MainActor in
                    HapticManager.impact(.medium)
                }
                return
            }

            AppLogStore.shared.record(
                .chat,
                level: .error,
                title: "Generation Failed",
                message: error.localizedDescription,
                metadata: [
                    "session_id": session.id.uuidString,
                    "model_id": model.catalogId
                ]
            )
            errorMessage = error.localizedDescription
            assistantMessage.content = "Error: \(error.localizedDescription)"
            assistantMessage.isGenerating = false
            try? context.save()
            Task { @MainActor in
                HapticManager.notification(.error)
            }
        }
    }
    
    func stopGeneration() {
        AppLogStore.shared.record(
            .chat,
            level: .warning,
            title: "Stop Requested",
            message: "User requested generation stop."
        )
        ModelRunner.shared.stopGeneration()
        Task { @MainActor in
            HapticManager.impact(.medium)
        }
    }

    private func isGenerationCancelled(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }

        if let modelError = error as? ModelError, case .generationCancelled = modelError {
            return true
        }

        return false
    }
}

#Preview {
    let session = ChatSession(modelId: "test")
    ChatView(session: session)
        .modelContainer(for: [ChatSession.self, ChatMessage.self, DownloadedModel.self], inMemory: true)
}
