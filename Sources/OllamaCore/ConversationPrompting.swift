import Foundation

/// Composes and normalizes conversation prompts for various model backends.
/// Used by AppleFoundationBackend and CoreMLPackageBackend.
public enum ConversationPrompting: Sendable {

    // MARK: - Chat Prompt Composer

    /// Builds a full prompt string from a system prompt and conversation turns.
    public static func promptForAssistant(
        systemPrompt: String?,
        turns: [ConversationTurn]
    ) -> String {
        var lines: [String] = []

        if let system = systemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines), !system.isEmpty {
            lines.append("System:\n\(system)")
        }

        for turn in turns {
            let roleLabel: String
            switch turn.role.lowercased() {
            case "user", "human":
                roleLabel = "User"
            case "assistant", "bot":
                roleLabel = "Assistant"
            case "system":
                roleLabel = "System"
            default:
                roleLabel = turn.role.capitalized
            }
            lines.append("\(roleLabel):\n\(turn.content.trimmingCharacters(in: .whitespacesAndNewlines))")
        }

        lines.append("Assistant:")
        return lines.joined(separator: "\n\n")
    }

    /// Wraps a system prompt with guard rails for assistant-only responses.
    public static func guardedSystemPrompt(
        _ systemPrompt: String?,
        includeGuard: Bool
    ) -> String? {
        let guardInstruction = "Reply with only the assistant's next message. Do not continue the conversation as the user. Do not include speaker labels such as User:, Assistant:, Human:, or Me:."

        let parts: [String] = [
            systemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines),
            guardInstruction
        ].compactMap { $0?.nonEmpty }

        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    // MARK: - Stop Sequences

    /// Merges caller-provided stop sequences with default chat stop sequences.
    public static func mergedStopSequences(
        _ callerSequences: [String],
        includeDefaultChatStops: Bool
    ) -> [String] {
        var result = callerSequences
        if includeDefaultChatStops {
            result.append(contentsOf: defaultChatStopSequences)
        }
        return result.filter { !$0.isEmpty }
    }

    /// Default stop sequences that mark the end of assistant output in chat mode.
    public static let defaultChatStopSequences: [String] = [
        "\nUser:",
        "\nHuman:",
        "\nMe:",
        "\nSystem:",
        "\nAssistant:\n",
        "User:\n"
    ]

    // MARK: - Text Extraction

    /// Extracts visible assistant text from accumulated output, stopping at stop sequences.
    public static func visibleAssistantText(
        from accumulated: String,
        stopSequences: [String]
    ) -> (visibleText: String, shouldStop: Bool) {
        var effectiveStops = stopSequences
        effectiveStops.append(contentsOf: defaultChatStopSequences)

        var earliestRange: Range<String.Index>?

        for stop in effectiveStops {
            guard !stop.isEmpty else { continue }
            guard let range = accumulated.range(of: stop) else { continue }
            if let current = earliestRange {
                if range.lowerBound < current.lowerBound {
                    earliestRange = range
                }
            } else {
                earliestRange = range
            }
        }

        guard let earliest = earliestRange else {
            return (accumulated, false)
        }

        return (String(accumulated[..<earliest.lowerBound]), true)
    }

    /// Finalizes assistant output by trimming stop sequences and formatting.
    public static func finalizedAssistantText(
        from text: String,
        stopSequences: [String]
    ) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)

        for stop in stopSequences + defaultChatStopSequences {
            if result.hasSuffix(stop.trimmingCharacters(in: .whitespacesAndNewlines)) {
                result = String(result.dropLast(stop.trimmingCharacters(in: .whitespacesAndNewlines).count))
            }
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Turn Normalization

    /// Normalizes mixed-format turn data (from API requests, legacy formats, etc.)
    /// into a consistent [role: String, content: String] array.
    public static func normalizedTurns(_ turns: [ConversationTurn]) -> [ConversationTurn] {
        turns.map { turn in
            ConversationTurn(
                role: normalizedRole(turn.role),
                content: turn.content.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        .filter { !$0.content.isEmpty }
    }

    private static func normalizedRole(_ role: String) -> String {
        let lower = role.lowercased()
        switch lower {
        case "user", "human", "me":
            return "user"
        case "assistant", "bot", "ai":
            return "assistant"
        case "system":
            return "system"
        default:
            return lower
        }
    }
}
