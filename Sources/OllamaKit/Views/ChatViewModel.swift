import SwiftUI
import SwiftData
import OllamaCore
import AVFoundation
import Speech
import PhotosUI

class ChatViewModel: ObservableObject {
    @Published var isGenerating = false
    @Published var currentModel: ModelSnapshot?
    @Published var errorMessage: String?
    @Published var lastSentMessage: String = ""
    @Published var streamRevision = 0
    @Published var tokensPerSecond: Double = 0
    @Published var generationStartTime: Date?

    func sendMessage(_ content: String, in session: ChatSession, context: ModelContext, parameters: ModelParameters? = nil, imageData: [Data]? = nil) async {
        let actualParameters = if let parameters = parameters { parameters } else { await MainActor.run { ModelParameters.appDefault } }
        lastSentMessage = content
        guard let model = currentModel else {
            AppLogStore.shared.record(
                .chat,
                level: .error,
                title: "Message Rejected",
                message: "No runnable model is selected."
            )
            errorMessage = "No runnable model is selected. Pick another validated model or re-download the missing one."
            AppLogStore.shared.record(
                .app,
                level: .warning,
                title: "Chat Send Blocked",
                message: "No runnable model selected."
            )
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
            AppLogStore.shared.record(
                .chat,
                title: "Generation Started",
                message: "Starting generation for selected model.",
                metadata: [
                    "model": model.displayName,
                    "catalog_id": model.catalogId,
                    "turn_count": String(conversationTurns.count + 1)
                ]
            )

            let effectiveContextLength = max(
                min(model.runtimeContextLength, AppSettings.shared.defaultContextLength),
                512
            )

            try await ModelRunner.shared.loadModel(
                catalogId: model.catalogId,
                contextLength: effectiveContextLength,
                gpuLayers: AppSettings.shared.gpuLayers
            )

            var generatedText = ""
            var tokensGenerated = 0
            let shouldStreamInUI = AppSettings.shared.streamingEnabled
            let startTime = Date()
            // FIX: Wrap mutable accumulators in a lock because the @Sendable onToken closure
            // may be called from arbitrary threads. Lock ensures atomic read-modify-write.
            let accumLock = NSLock()

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
                parameters: actualParameters
            ) { token in
                guard shouldStreamInUI else { return }
                // Thread-safe accumulation: lock protects the read-modify-write of
                // tokensGenerated and generatedText from the @Sendable closure context.
                accumLock.lock()
                tokensGenerated += 1
                generatedText += token
                let currentText = generatedText
                let currentCount = tokensGenerated
                accumLock.unlock()
                let elapsed = Date().timeIntervalSince(startTime)
                let tps = elapsed > 0 ? Double(currentCount) / elapsed : 0
                Task { @MainActor in
                    assistantMessage.content = currentText
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
            AppLogStore.shared.record(
                .chat,
                title: "Generation Finished",
                message: result.wasCancelled ? "Generation cancelled." : "Assistant response completed.",
                metadata: [
                    "model": model.displayName,
                    "tokens": String(result.tokensGenerated),
                    "seconds": String(format: "%.2f", result.generationTime),
                    "cancelled": String(result.wasCancelled)
                ]
            )
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
            AppLogStore.shared.record(
                .app,
                level: .error,
                title: "Generation Failed",
                message: error.localizedDescription,
                metadata: ["model": model.displayName]
            )
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

