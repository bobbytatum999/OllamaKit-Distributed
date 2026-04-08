import SwiftUI
import SwiftData
import OllamaCore
import PhotosUI
import Speech
import AVFoundation

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
    @State private var selectedImages: [UIImage] = []
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var showingCompareMode = false
    @State private var compareModel: ModelSnapshot?
    @State private var compareInput = ""
    @State private var compareResponse1 = ""
    @State private var compareResponse2 = ""
    @State private var isComparing = false
    @State private var showingCompareSheet = false
    @State private var isRecording = false
    @State private var speechRecognizer: SFSpeechRecognizer? = SFSpeechRecognizer(locale: .current)
    
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
                                MessageBubble(message: message, onBranch: message.role == .assistant ? { msg in branchFromHere(msg) } : nil)
                                    .id(message.id)
                            }
                            
                            if viewModel.isGenerating {
                                HStack(spacing: 8) {
                                    TypingIndicator()
                                    if viewModel.tokensPerSecond > 0 {
                                        Text(String(format: "%.1f tok/s", viewModel.tokensPerSecond))
                                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                            .background(Capsule().fill(.ultraThinMaterial))
                                    }
                                }
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
                    
                    // Image thumbnails strip
                    if !selectedImages.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(Array(selectedImages.enumerated()), id: \.offset) { index, image in
                                    ZStack(alignment: .topTrailing) {
                                        Image(uiImage: image)
                                            .resizable()
                                            .scaledToFill()
                                            .frame(width: 60, height: 60)
                                            .clipShape(RoundedRectangle(cornerRadius: 8))
                                        Button {
                                            selectedImages.remove(at: index)
                                            if index < selectedPhotoItems.count {
                                                selectedPhotoItems.remove(at: index)
                                            }
                                        } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .font(.system(size: 18))
                                                .foregroundStyle(.white)
                                                .background(Circle().fill(.black.opacity(0.5)))
                                        }
                                        .offset(x: 4, y: -4)
                                    }
                                }
                                
                                // Add more photos button
                                PhotosPicker(selection: $selectedPhotoItems, maxSelectionCount: 4, matching: .images) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(.ultraThinMaterial)
                                            .frame(width: 60, height: 60)
                                        Image(systemName: "plus")
                                            .font(.system(size: 20))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .onChange(of: selectedPhotoItems) { _, newItems in
                                    Task {
                                        var newImages: [UIImage] = []
                                        for item in newItems {
                                            if let data = try? await item.loadTransferable(type: Data.self),
                                               let image = UIImage(data: data) {
                                                newImages.append(image)
                                            }
                                        }
                                        selectedImages = newImages
                                    }
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                        .padding(.vertical, 8)
                    }
                    
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

                    HStack(spacing: 8) {
                        // Photos picker button
                        PhotosPicker(selection: $selectedPhotoItems, maxSelectionCount: 4, matching: .images) {
                            Image(systemName: selectedImages.isEmpty ? "photo" : "photo.fill")
                                .font(.system(size: 22))
                                .foregroundStyle(selectedImages.isEmpty ? Color.secondary : Color.accentColor)
                        }
                        .onChange(of: selectedPhotoItems) { _, newItems in
                            Task {
                                var newImages: [UIImage] = []
                                for item in newItems {
                                    if let data = try? await item.loadTransferable(type: Data.self),
                                       let image = UIImage(data: data) {
                                        newImages.append(image)
                                    }
                                }
                                // Append new images, avoid duplicates
                                for img in newImages {
                                    if !selectedImages.contains(where: { $0.pngData() == img.pngData() }) {
                                        selectedImages.append(img)
                                    }
                                }
                            }
                        }
                        
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

                        Button(action: toggleRecording) {
                            Image(systemName: isRecording ? "mic.slash.fill" : "mic.fill")
                                .font(.system(size: 22))
                                .foregroundStyle(isRecording ? Color.red : Color.secondary)
                        }
                        .disabled(viewModel.isGenerating)
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
                            showingCompareSheet = true
                        } label: {
                            Label("Compare Models", systemImage: "rectangle.split.2x1")
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
        .sheet(isPresented: $showingCompareSheet) {
            NavigationStack {
                ModelComparisonSheet(primaryModel: $viewModel.currentModel)
            }
            .presentationDetents([.medium, .large])
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

    @MainActor
    @MainActor
    private func branchFromHere(_ message: ChatMessage) {
        // Mark the current message as a branch point
        message.branchPoint = true
        
        // Create a new session for the branch
        let branchSession = ChatSession(
            title: session.title + " (branch)",
            modelId: session.modelId,
            systemPrompt: session.systemPrompt
        )
        branchSession.parentMessageId = message.id
        modelContext.insert(branchSession)
        
        // Copy all messages up to and including the branch point message
        for msg in session.orderedMessages {
            if msg.id == message.id {
                // Mark the branch point message in the new session
                let msgCopy = ChatMessage(role: msg.role, content: msg.content)
                msgCopy.createdAt = msg.createdAt
                msgCopy.tokenCount = msg.tokenCount
                msgCopy.generationTime = msg.generationTime
                msgCopy.imageData = msg.imageData
                msgCopy.branchPoint = true
                msgCopy.parentMessageId = nil
                msgCopy.session = branchSession
                modelContext.insert(msgCopy)
                break
            } else {
                let msgCopy = ChatMessage(role: msg.role, content: msg.content)
                msgCopy.createdAt = msg.createdAt
                msgCopy.tokenCount = msg.tokenCount
                msgCopy.generationTime = msg.generationTime
                msgCopy.imageData = msg.imageData
                msgCopy.branchPoint = false
                msgCopy.parentMessageId = nil
                msgCopy.session = branchSession
                modelContext.insert(msgCopy)
            }
        }
        
        try? modelContext.save()
        
        AppLogStore.shared.record(
            .chat,
            title: "Branch Created",
            message: "Created a branch from message.",
            metadata: [
                "original_session": session.id.uuidString,
                "branch_session": branchSession.id.uuidString,
                "branch_point": message.id.uuidString
            ]
        )
        
        Task { @MainActor in
            HapticManager.notification(.success)
        }
        
        // Navigate to the branch session
        session = branchSession
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
        guard !content.isEmpty || !selectedImages.isEmpty else { return }

        // Encode selected images as base64 data
        let imageDataArray = selectedImages.compactMap { $0.jpegData(compressionQuality: 0.8) }

        AppLogStore.shared.record(
            .chat,
            title: "User Message Queued",
            message: "Queued a new user message for generation.",
            metadata: [
                "session_id": session.id.uuidString,
                "chars": "\(content.count)",
                "images": "\(imageDataArray.count)"
            ],
            body: content
        )
        messageText = ""
        selectedImages = []
        selectedPhotoItems = []

        Task { @MainActor in
            HapticManager.impact(.light)
        }
        
        Task {
            await viewModel.sendMessage(
                content,
                in: session,
                context: modelContext,
                parameters: ModelParameters(
                    temperature: paramTemperature,
                    topP: paramTopP,
                    topK: paramTopK,
                    repeatPenalty: paramRepeatPenalty,
                    maxTokens: paramMaxTokens
                ),
                imageData: imageDataArray.isEmpty ? nil : imageDataArray
            )
        }
    }

    private func toggleRecording() {
        if isRecording {
            isRecording = false
            Task { @MainActor in
                HapticManager.impact(.medium)
            }
        } else {
            requestSpeechPermission()
        }
    }

    private func requestSpeechPermission() {
        SFSpeechRecognizer.requestAuthorization { [self] status in
            Task { @MainActor in
                switch status {
                case .authorized:
                    startSpeechRecognition()
                case .denied, .restricted:
                    HapticManager.notification(.error)
                case .notDetermined:
                    HapticManager.notification(.warning)
                @unknown default:
                    break
                }
            }
        }
    }

    private func startSpeechRecognition() {
        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            Task { @MainActor in
                HapticManager.notification(.error)
            }
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true

        let audioEngine = AVAudioEngine()
        let inputNode = audioEngine.inputNode

        isRecording = true
        Task { @MainActor in
            HapticManager.impact(.light)
        }

        Task {
            var lastTranscription = ""
            let stream = recognizer.recognitionTask(with: request) { [self] result, error in
                if let result = result {
                    let transcription = result.bestTranscription.formattedString
                    Task { @MainActor in
                        messageText = lastTranscription + transcription
                    }
                }
                if error != nil || result?.isFinal == true {
                    lastTranscription = messageText + " "
                }
            }

            let recordingFormat = inputNode.outputFormat(forBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
                request.append(buffer)
            }

            audioEngine.prepare()
            try? audioEngine.start()

            // Wait for isRecording to become false (user stopped)
            while isRecording {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }

            audioEngine.stop()
            inputNode.removeTap(onBus: 0)
            stream.cancel()
            request.endAudio()

            Task { @MainActor in
                HapticManager.impact(.medium)
            }
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
    let onBranch: ((ChatMessage) -> Void)?
    @ObservedObject private var settings = AppSettings.shared
    
    init(message: ChatMessage, onBranch: ((ChatMessage) -> Void)? = nil) {
        self.message = message
        self.onBranch = onBranch
    }
    
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
        .contextMenu {
            if !isUser, let onBranch = onBranch {
                Button {
                    onBranch(message)
                } label: {
                    Label("Branch from Here", systemImage: "arrow.branch")
                }
            }
            
            Button {
                UIPasteboard.general.string = message.content
                Task { @MainActor in
                    HapticManager.notification(.success)
                }
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
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
    @Published var tokensPerSecond: Double = 0
    @Published var generationStartTime: Date?

    func sendMessage(_ content: String, in session: ChatSession, context: ModelContext, parameters: ModelParameters = .appDefault, imageData: [Data]? = nil) async {
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
        userMessage.imageData = imageData?.first
        context.insert(userMessage)
        session.updatedAt = Date()

        try? context.save()

        let assistantMessage = ChatMessage(role: .assistant, content: "", isGenerating: true)
        assistantMessage.session = session
        context.insert(assistantMessage)
        try? context.save()

        isGenerating = true
        streamRevision = 0
        tokensPerSecond = 0
        generationStartTime = Date()
        AppLogStore.shared.record(
            .chat,
            title: "Generation Started",
            message: "Started model generation for chat session.",
            metadata: [
                "session_id": session.id.uuidString,
                "model_id": model.catalogId,
                "streaming": "\(AppSettings.shared.streamingEnabled)",
                "has_images": "\(imageData?.isEmpty == false)"
            ]
        )
        defer {
            isGenerating = false
            tokensPerSecond = 0
            generationStartTime = nil
        }

        // parameters passed from ChatView

        do {
            try await ModelRunner.shared.loadModel(
                catalogId: model.catalogId,
                contextLength: model.runtimeContextLength,
                gpuLayers: AppSettings.shared.gpuLayers
            )

            var generatedText = ""
            var tokensGenerated = 0
            let shouldStreamInUI = AppSettings.shared.streamingEnabled
            let startTime = Date()

            // Build conversation turns with image data
            var userTurn = ConversationTurn(role: userMessage.roleValue, content: userMessage.content)
            if let imageData = imageData, !imageData.isEmpty {
                // For image support: create content parts with image URLs (base64 data URLs)
                let imageParts = imageData.map { data -> ConversationContentPart in
                    let base64 = data.base64EncodedString()
                    return ConversationContentPart(kind: .imageURL, url: "data:image/jpeg;base64,\(base64)")
                }
                userTurn = ConversationTurn(role: userMessage.roleValue, parts: imageParts + [.text(userMessage.content)])
            }

            let result = try await ModelRunner.shared.generate(
                prompt: "",
                systemPrompt: session.systemPrompt,
                conversationTurns: conversationTurns + [userTurn],
                parameters: parameters
            ) { token in
                guard shouldStreamInUI else { return }
                tokensGenerated += 1
                generatedText += token
                let elapsed = Date().timeIntervalSince(startTime)
                let tps = elapsed > 0 ? Double(tokensGenerated) / elapsed : 0
                Task { @MainActor in
                    assistantMessage.content = generatedText
                    self.tokensPerSecond = tps
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

struct ModelComparisonSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var primaryModel: ModelSnapshot?
    @StateObject private var modelStore = ModelStorage.shared
    @State private var selectedModel2: ModelSnapshot?
    @State private var compareInput = ""
    @State private var response1 = ""
    @State private var response2 = ""
    @State private var isRunning1 = false
    @State private var isRunning2 = false
    @State private var errorMessage: String?

    private var availableModels: [ModelSnapshot] {
        BuiltInModelCatalog.selectionModels(downloadedModels: modelStore.selectionSnapshots)
    }

    var body: some View {
        VStack(spacing: 16) {
            if availableModels.count < 2 {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 40))
                        .foregroundStyle(.orange)
                    Text("Need at least 2 models")
                        .font(.headline)
                    Text("Download at least 2 models to use comparison mode")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 16) {
                        // Model selectors
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Model 1")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Menu {
                                    ForEach(availableModels.filter { $0.id != selectedModel2?.id }) { model in
                                        Button(model.displayName) {
                                            primaryModel = model
                                        }
                                    }
                                } label: {
                                    HStack {
                                        Text(primaryModel?.displayName ?? "Select")
                                        Spacer()
                                        Image(systemName: "chevron.down")
                                    }
                                    .padding(10)
                                    .background(Capsule().fill(.ultraThinMaterial))
                                }
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                Text("Model 2")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Menu {
                                    ForEach(availableModels.filter { $0.id != primaryModel?.id }) { model in
                                        Button(model.displayName) {
                                            selectedModel2 = model
                                        }
                                    }
                                } label: {
                                    HStack {
                                        Text(selectedModel2?.displayName ?? "Select")
                                        Spacer()
                                        Image(systemName: "chevron.down")
                                    }
                                    .padding(10)
                                    .background(Capsule().fill(.ultraThinMaterial))
                                }
                            }
                        }

                        // Input
                        TextField("Enter a prompt to compare...", text: $compareInput, axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(.system(size: 16))
                            .lineLimit(3...6)
                            .padding(12)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(.ultraThinMaterial)
                            )

                        Button {
                            runComparison()
                        } label: {
                            Label(
                                (isRunning1 || isRunning2) ? "Running..." : "Compare",
                                systemImage: "rectangle.split.2x1"
                            )
                            .font(.headline)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill((primaryModel != nil && selectedModel2 != nil && !compareInput.isEmpty && !isRunning1 && !isRunning2) ? Color(hex: "8B5CF6") : Color.gray)
                            )
                        }
                        .disabled(primaryModel == nil || selectedModel2 == nil || compareInput.isEmpty || isRunning1 || isRunning2)

                        // Results
                        if !response1.isEmpty || !response2.isEmpty || isRunning1 || isRunning2 {
                            HStack(alignment: .top, spacing: 12) {
                                // Model 1 response
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Text(primaryModel?.displayName ?? "Model 1")
                                            .font(.caption)
                                            .fontWeight(.semibold)
                                        if isRunning1 {
                                            ProgressView()
                                                .scaleEffect(0.7)
                                        }
                                    }
                                    ScrollView {
                                        Text(response1.isEmpty ? "..." : response1)
                                            .font(.system(size: 14))
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .frame(minHeight: 80)
                                    .padding(10)
                                    .background(
                                        RoundedRectangle(cornerRadius: 12)
                                            .fill(Color.gray.opacity(0.08))
                                    )
                                }

                                // Model 2 response
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Text(selectedModel2?.displayName ?? "Model 2")
                                            .font(.caption)
                                            .fontWeight(.semibold)
                                        if isRunning2 {
                                            ProgressView()
                                                .scaleEffect(0.7)
                                        }
                                    }
                                    ScrollView {
                                        Text(response2.isEmpty ? "..." : response2)
                                            .font(.system(size: 14))
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .frame(minHeight: 80)
                                    .padding(10)
                                    .background(
                                        RoundedRectangle(cornerRadius: 12)
                                            .fill(Color.gray.opacity(0.08))
                                    )
                                }
                            }
                        }
                    }
                    .padding()
                }
            }
        }
        .navigationTitle("Compare Models")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { dismiss() }
            }
        }
    }

    private func runComparison() {
        guard let model1 = primaryModel, let model2 = selectedModel2 else { return }
        let prompt = compareInput

        // Run model 1
        isRunning1 = true
        response1 = ""
        Task {
            do {
                try await ModelRunner.shared.loadModel(
                    catalogId: model1.catalogId,
                    contextLength: model1.runtimeContextLength,
                    gpuLayers: AppSettings.shared.gpuLayers
                )
                let result = try await ModelRunner.shared.generate(
                    prompt: "",
                    systemPrompt: nil,
                    conversationTurns: [ConversationTurn(role: "user", content: prompt)],
                    parameters: .appDefault
                ) { _ in }
                await MainActor.run {
                    response1 = result.text ?? ""
                    isRunning1 = false
                }
            } catch {
                await MainActor.run {
                    response1 = "Error: \(error.localizedDescription)"
                    isRunning1 = false
                }
            }
        }

        // Run model 2
        isRunning2 = true
        response2 = ""
        Task {
            do {
                try await ModelRunner.shared.loadModel(
                    catalogId: model2.catalogId,
                    contextLength: model2.runtimeContextLength,
                    gpuLayers: AppSettings.shared.gpuLayers
                )
                let result = try await ModelRunner.shared.generate(
                    prompt: "",
                    systemPrompt: nil,
                    conversationTurns: [ConversationTurn(role: "user", content: prompt)],
                    parameters: .appDefault
                ) { _ in }
                await MainActor.run {
                    response2 = result.text ?? ""
                    isRunning2 = false
                }
            } catch {
                await MainActor.run {
                    response2 = "Error: \(error.localizedDescription)"
                    isRunning2 = false
                }
            }
        }
    }
}

#Preview {
    let session = ChatSession(modelId: "test")
    ChatView(session: session)
        .modelContainer(for: [ChatSession.self, ChatMessage.self, DownloadedModel.self], inMemory: true)
}
