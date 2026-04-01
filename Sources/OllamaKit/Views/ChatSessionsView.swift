import SwiftUI
import SwiftData

struct ChatSessionsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ChatSession.updatedAt, order: .reverse) private var sessions: [ChatSession]
    
    @State private var showingNewChat = false
    @State private var searchText = ""
    
    var filteredSessions: [ChatSession] {
        if searchText.isEmpty {
            return sessions
        }
        return sessions.filter { session in
            session.title.localizedCaseInsensitiveContains(searchText) ||
            session.orderedMessages.contains { $0.content.localizedCaseInsensitiveContains(searchText) }
        }
    }
    
    var body: some View {
        ZStack {
            AnimatedMeshBackground()
            
            List {
                if filteredSessions.isEmpty {
                    Section {
                        EmptyChatsView()
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                } else {
                    ForEach(filteredSessions) { session in
                        NavigationLink(value: session) {
                            ChatSessionRow(session: session)
                        }
                        .listRowBackground(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(.ultraThinMaterial)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 16)
                                        .stroke(.white.opacity(0.1), lineWidth: 0.5)
                                )
                        )
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    }
                    .onDelete(perform: deleteSessions)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Chats")
        .navigationDestination(for: ChatSession.self) { session in
            ChatView(session: session)
        }
        .searchable(text: $searchText, prompt: "Search chats")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: { showingNewChat = true }) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 17, weight: .semibold))
                }
            }
        }
        .sheet(isPresented: $showingNewChat) {
            NewChatSheet()
        }
    }
    
    private func deleteSessions(at offsets: IndexSet) {
        let sessionsToDelete = offsets.compactMap { index in
            filteredSessions.indices.contains(index) ? filteredSessions[index] : nil
        }

        for session in sessionsToDelete {
            modelContext.delete(session)
        }
        try? modelContext.save()
    }
}

struct ChatSessionRow: View {
    private static let relativeTimeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    let session: ChatSession
    
    var lastMessage: String {
        session.orderedMessages.last?.content ?? "No messages yet"
    }
    
    var lastMessageTime: String {
        Self.relativeTimeFormatter.localizedString(for: session.updatedAt, relativeTo: Date())
    }
    
    var body: some View {
        HStack(spacing: 12) {
            // Avatar with liquid glass
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: 48, height: 48)
                
                Image(systemName: "bubble.left.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text(session.title)
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(1)
                
                Text(lastMessage)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            
            Spacer()
            
            Text(lastMessageTime)
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 8)
    }
}

struct EmptyChatsView: View {
    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: 100, height: 100)
                
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
            }
            
            Text("No Chats Yet")
                .font(.system(size: 22, weight: .bold))
            
            Text("Start a new conversation with your local AI models")
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            
            Spacer()
        }
        .frame(maxWidth: .infinity, minHeight: 400)
    }
}

struct NewChatSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @StateObject private var modelStore = ModelStorage.shared
    
    @State private var selectedModel: ModelSnapshot?
    @State private var systemPrompt = ""
    @State private var showingCustomPrompt = false

    private var availableModels: [ModelSnapshot] {
        BuiltInModelCatalog.selectionModels(downloadedModels: modelStore.selectionSnapshots)
    }

    private var appleAvailability: BuiltInModelAvailability {
        BuiltInModelCatalog.availability()
    }
    
    let defaultPrompts = [
        ("Default Assistant", "You are a helpful assistant."),
        ("Code Expert", "You are an expert programmer. Help with coding questions and provide clean, well-documented code."),
        ("Creative Writer", "You are a creative writing assistant. Help with storytelling, poetry, and creative projects."),
        ("Research Assistant", "You are a research assistant. Provide detailed, accurate information and cite sources when possible."),
        ("Custom", "")
    ]
    
    var body: some View {
        NavigationStack {
            ZStack {
                AnimatedMeshBackground()
                
                List {
                    Section {
                        if availableModels.isEmpty {
                            VStack(spacing: 12) {
                                Image(systemName: "cube.box")
                                    .font(.system(size: 40))
                                    .foregroundStyle(.secondary)
                                
                                Text("No Runnable Models")
                                    .font(.headline)
                                
                                Text("Download a GGUF model, import a full ANEMLL/CoreML model package, or use Apple On-Device AI if it is available on this device.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                            .listRowBackground(Color.clear)
                        } else {
                            ForEach(availableModels) { model in
                                ModelSelectionRow(
                                    model: model,
                                    isSelected: selectedModel?.id == model.id
                                )
                                .contentShape(Rectangle())
                                .opacity(model.isBuiltInAppleModel && !appleAvailability.isAvailable ? 0.55 : 1)
                                .onTapGesture {
                                    guard !model.isBuiltInAppleModel || appleAvailability.isAvailable else { return }
                                    selectedModel = model
                                    Task { @MainActor in
                                        HapticManager.selectionChanged()
                                    }
                                }
                            }
                        }
                    } header: {
                        Text("Select Model")
                    }
                    .listRowBackground(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(.ultraThinMaterial)
                    )
                    .listRowSeparator(.hidden)
                    
                    Section {
                        ForEach(defaultPrompts, id: \.0) { prompt in
                            PromptRow(
                                title: prompt.0,
                                prompt: prompt.1,
                                isSelected: systemPrompt == prompt.1 || (prompt.0 == "Custom" && showingCustomPrompt)
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if prompt.0 == "Custom" {
                                    showingCustomPrompt = true
                                    systemPrompt = ""
                                } else {
                                    showingCustomPrompt = false
                                    systemPrompt = prompt.1
                                }
                                Task { @MainActor in
                                    HapticManager.selectionChanged()
                                }
                            }
                        }
                        
                        if showingCustomPrompt {
                            TextEditor(text: $systemPrompt)
                                .frame(minHeight: 100)
                                .padding(8)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(.ultraThinMaterial)
                                )
                        }
                    } header: {
                        Text("System Prompt")
                    }
                    .listRowBackground(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(.ultraThinMaterial)
                    )
                    .listRowSeparator(.hidden)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("New Chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        createChat()
                    }
                    .disabled(selectedModel == nil)
                }
            }
        }
        .onAppear {
            syncInitialSelection()
            if systemPrompt.isEmpty {
                systemPrompt = "You are a helpful assistant."
            }
        }
        .task {
            await modelStore.refresh()
            syncInitialSelection()
        }
    }
    
    private func createChat() {
        guard let model = selectedModel else { return }
        
        let session = ChatSession(
            title: "Chat with \(model.displayName)",
            modelId: model.persistentReference,
            systemPrompt: systemPrompt.isEmpty ? "You are a helpful assistant." : systemPrompt
        )
        
        modelContext.insert(session)
        try? modelContext.save()
        Task { @MainActor in
            HapticManager.notification(.success)
        }
        
        dismiss()
    }

    private func syncInitialSelection() {
        if let selectedModel,
           availableModels.contains(where: { $0.id == selectedModel.id }) {
            return
        }

        if !AppSettings.shared.defaultModelId.isEmpty,
           let defaultModel = BuiltInModelCatalog.resolveStoredReference(
                AppSettings.shared.defaultModelId,
                in: modelStore.selectionSnapshots
           ),
           availableModels.contains(where: { $0.id == defaultModel.id }) {
            selectedModel = defaultModel
            return
        }

        selectedModel = availableModels.first
    }
}

struct ModelSelectionRow: View {
    let model: ModelSnapshot
    let isSelected: Bool

    private var appleAvailability: BuiltInModelAvailability {
        BuiltInModelCatalog.availability()
    }
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.displayName)
                    .font(.system(size: 16, weight: .medium))
                
                HStack(spacing: 8) {
                    if model.isBuiltInAppleModel {
                        Label("Built In", systemImage: "apple.logo")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)

                        Text("•")
                            .foregroundStyle(.tertiary)

                        Label(appleAvailability.isAvailable ? "On Device" : "Unavailable", systemImage: appleAvailability.isAvailable ? "bolt.fill" : "exclamationmark.triangle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    } else {
                        Label(model.quantization, systemImage: "cpu")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        
                        Text("•")
                            .foregroundStyle(.tertiary)
                        
                        Label(model.formattedSize, systemImage: "externaldrive")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            
            Spacer()
            
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.accentColor)
                    .font(.system(size: 22))
            }
        }
        .padding(.vertical, 4)
    }
}

struct PromptRow: View {
    let title: String
    let prompt: String
    let isSelected: Bool
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 16, weight: .medium))
                
                if !prompt.isEmpty {
                    Text(prompt)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            
            Spacer()
            
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.accentColor)
                    .font(.system(size: 22))
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    ChatSessionsView()
        .modelContainer(for: [ChatSession.self, ChatMessage.self, DownloadedModel.self], inMemory: true)
}
