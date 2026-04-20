import SwiftUI
import SwiftData
import OllamaCore
import AVFoundation
import Speech
import PhotosUI

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

