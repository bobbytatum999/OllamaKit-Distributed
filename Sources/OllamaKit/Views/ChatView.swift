import SwiftUI
import SwiftData
import OllamaCore
import AVFoundation
import Speech
import PhotosUI

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
    @StateObject private var voiceInput = VoiceInputController()
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
    // FIX: Store recognition Task so it can be cancelled on view disappear.
    // Previously no onDisappear cleanup existed, so the Task ran indefinitely.
    @State private var recognitionTask: Task<Void, Never>?
    @State private var speechRequest: SFSpeechAudioBufferRecognitionRequest?
    @State private var speechAudioEngine: AVAudioEngine?
    
    @Namespace private var scrollID

    init(session: ChatSession) {
        self.session = session
    }

    private let bottomID = "bottom"

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

    private var parametersFormContent: some View {
        Form {
            Section("Temperature") {
                Slider(value: $paramTemperature, in: 0...2, step: 0.1) {
                    Text(String(format: "%.1f", paramTemperature))
                }
            }
            Section("Top P") {
                Slider(value: $paramTopP, in: 0...1, step: 0.05) {
                    Text(String(format: "%.2f", paramTopP))
                }
            }
            Section("Top K") {
                Stepper(value: $paramTopK, in: 1...100) {
                    Text("\(paramTopK)")
                }
            }
            Section("Repeat Penalty") {
                Slider(value: $paramRepeatPenalty, in: 1...2, step: 0.05) {
                    Text(String(format: "%.2f", paramRepeatPenalty))
                }
            }
            Section("Max Tokens") {
                Stepper(value: $paramMaxTokens, in: 256...8192, step: 256) {
                    Text("\(paramMaxTokens)")
                }
            }
        }
        .navigationTitle("Parameters")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var messagesListView: some View {
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
    }

    private var inputAreaView: some View {
        VStack(spacing: 0) {
            Divider()

            HStack(spacing: 12) {
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
                    Image(systemName: sendButtonSystemImage)
                        .font(.system(size: 32))
                        .foregroundStyle(sendButtonColor)
                }
                .disabled((trimmedMessageText.isEmpty && !canStartOrStopVoiceInput) || viewModel.isGenerating)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(.ultraThinMaterial)
    }

    private var chatErrorBinding: Binding<Bool> {
        Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )
    }

    private var voiceErrorBinding: Binding<Bool> {
        Binding(
            get: { voiceInput.errorMessage != nil },
            set: { if !$0 { voiceInput.errorMessage = nil } }
        )
    }

    var body: some View {
        mainContent
            .sheet(isPresented: $showingModelSelector) {
                ModelSelectorSheet(selectedModel: $viewModel.currentModel)
            }
            .sheet(isPresented: $showingCompareSheet) {
                ComparisonSheetContent(selectedModel: $viewModel.currentModel)
            }
            .sheet(isPresented: $showingParameters) {
                NavigationStack {
                    parametersFormContent
                }
            }
            .task {
                await modelStore.refresh()
                syncCurrentModelSelection()
                let settings = AppSettings.shared
                paramTemperature = settings.defaultTemperature
                paramTopP = settings.defaultTopP
                paramTopK = settings.defaultTopK
                paramRepeatPenalty = settings.defaultRepeatPenalty
                paramMaxTokens = settings.maxTokens
            }
            .onDisappear {
                if isRecording {
                    isRecording = false
                }
                recognitionTask?.cancel()
                recognitionTask = nil
                speechAudioEngine?.stop()
                speechAudioEngine = nil
                speechRequest?.endAudio()
                speechRequest = nil
                voiceInput.stopRecording()
            }
            .onChange(of: downloadedModelRevision) { _, _ in
                syncCurrentModelSelection()
            }
            .onChange(of: viewModel.currentModel?.id) { _, _ in
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
            .alert("Chat Error", isPresented: chatErrorBinding) {
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
            .alert("Voice Input Error", isPresented: voiceErrorBinding) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(voiceInput.errorMessage ?? "")
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

    private var mainContent: some View {
        ZStack {
            AnimatedMeshBackground()
            VStack(spacing: 0) {
                messagesListView
                inputAreaView
            }
        }
        .navigationTitle(session.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private struct ComparisonSheetContent: View {
        @Binding var selectedModel: ModelSnapshot?

        var body: some View {
            NavigationStack {
                ModelComparisonSheet(primaryModel: $selectedModel)
            }
            .presentationDetents([.medium, .large])
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
        // Note: session navigation handled by parent view
        _ = branchSession
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
        if trimmedMessageText.isEmpty {
            toggleVoiceInput()
            return
        }

        voiceInput.stopRecording()
        let content = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty || !selectedImages.isEmpty else { return }

        AppLogStore.shared.record(
            .chat,
            title: "User Message Queued",
            message: "User submitted a chat message.",
            metadata: [
                "chars": String(content.count),
                "has_system_prompt": String(!session.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            ]
        )

        // Encode selected images as base64 data
        let imageDataArray = selectedImages.compactMap { $0.jpegData(compressionQuality: 0.8) }


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
        speechRequest = request

        let audioEngine = AVAudioEngine()
        speechAudioEngine = audioEngine
        let inputNode = audioEngine.inputNode

        isRecording = true
        Task { @MainActor in
            HapticManager.impact(.light)
        }

        // FIX: Store Task so it can be cancelled on view disappear.
        // Previously no cleanup existed — Task ran indefinitely after view disappeared.
        recognitionTask = Task {
            var lastTranscription = ""
            let stream = recognizer.recognitionTask(with: request) { [self] result, error in
                if Task.isCancelled { return }
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

            // Wait for isRecording to become false (user stopped or view disappeared)
            while isRecording && !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }

            if !Task.isCancelled {
                audioEngine.stop()
                inputNode.removeTap(onBus: 0)
                stream.cancel()
                request.endAudio()
            }

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

    private var canStartOrStopVoiceInput: Bool {
        voiceInput.isRecording || voiceInput.isAvailable
    }

    private var sendButtonSystemImage: String {
        if !trimmedMessageText.isEmpty {
            return "arrow.up.circle.fill"
        }

        return voiceInput.isRecording ? "stop.circle.fill" : "mic.circle.fill"
    }

    private var sendButtonColor: Color {
        if !trimmedMessageText.isEmpty {
            return .accentColor
        }

        return voiceInput.isRecording ? .red : .secondary
    }
    private func toggleVoiceInput() {
        if voiceInput.isRecording {
            voiceInput.stopRecording()
            return
        }

        voiceInput.startRecording { transcript, isFinal in
            messageText = transcript
            if isFinal {
                Task { @MainActor in
                    HapticManager.impact(.light)
                }
            }
        }
    }
}

