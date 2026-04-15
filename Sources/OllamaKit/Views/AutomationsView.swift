import SwiftUI
import SwiftData

struct AutomationsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var automations: [SavedAutomation]
    @State private var showingCreateSheet = false
    @State private var runningAutomationId: UUID?

    var body: some View {
        ZStack {
            AnimatedMeshBackground()

            ScrollView {
                LazyVStack(spacing: 16) {
                    if automations.isEmpty {
                        EmptyAutomationsView()
                    } else {
                        ForEach(automations, id: \.id) { automation in
                            AutomationCard(
                                automation: automation,
                                isRunning: runningAutomationId == automation.id,
                                onRun: { await runAutomation(automation) },
                                onDelete: { deleteAutomation(automation) }
                            )
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            }
            .scrollIndicators(.hidden)
        }
        .navigationTitle("Automate")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingCreateSheet = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 22))
                }
            }
        }
        .sheet(isPresented: $showingCreateSheet) {
            CreateAutomationView()
        }
    }

    private func runAutomation(_ automation: SavedAutomation) async {
        runningAutomationId = automation.id
        defer { runningAutomationId = nil }

        do {
            let result = try await AutomationRunner.shared.run(automation)
            automation.lastRunAt = Date()
            automation.lastRunResult = result
            try? modelContext.save()
            await MainActor.run {
                HapticManager.notification(.success)
            }
        } catch {
            automation.lastRunAt = Date()
            automation.lastRunResult = "Error: \(error.localizedDescription)"
            try? modelContext.save()
            await MainActor.run {
                HapticManager.notification(.error)
            }
        }
    }

    private func deleteAutomation(_ automation: SavedAutomation) {
        modelContext.delete(automation)
        try? modelContext.save()
        Task { @MainActor in
            HapticManager.notification(.warning)
        }
    }
}

struct EmptyAutomationsView: View {
    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: 80, height: 80)

                Image(systemName: "wand.and.stars")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
            }

            Text("No Automations Yet")
                .font(.system(size: 20, weight: .bold))

            Text("Create automations that run LLM tasks, HTTP requests, or send notifications on a schedule.")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, minHeight: 280)
        .padding(.vertical, 40)
    }
}

struct AutomationCard: View {
    @Bindable var automation: SavedAutomation
    let isRunning: Bool
    let onRun: () async -> Void
    let onDelete: () -> Void

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

                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(automation.name.isEmpty ? "Untitled" : automation.name)
                            .font(.system(size: 17, weight: .semibold))
                            .lineLimit(2)

                        TriggerBadge(type: automation.triggerType)
                    }

                    if let lastRunAt = automation.lastRunAt {
                        Text("Last run: \(lastRunAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Never run")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Toggle("", isOn: Binding(
                    get: { automation.isEnabled },
                    set: { automation.isEnabled = $0 }
                ))
                .labelsHidden()
                .tint(.accentColor)
            }

            if let result = automation.lastRunResult, !result.isEmpty {
                Text(result.prefix(150) + (result.count > 150 ? "…" : ""))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(.ultraThinMaterial)
                    )
            }

            HStack(spacing: 10) {
                Button {
                    Task { await onRun() }
                } label: {
                    Label(isRunning ? "Running…" : "Run Now", systemImage: isRunning ? "circle.dotted" : "play.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isRunning)

                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 14))
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(.white.opacity(0.12), lineWidth: 0.6)
                )
        )
    }
}

struct TriggerBadge: View {
    let type: String

    private var displayText: String {
        switch type {
        case "manual": return "Manual"
        case "cron": return "Scheduled"
        case "webhook": return "Webhook"
        default: return type.capitalized
        }
    }

    private var icon: String {
        switch type {
        case "manual": return "hand.tap"
        case "cron": return "clock"
        case "webhook": return "antenna.radiowaves.left.and.right"
        default: return "questionmark"
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10))
            Text(displayText)
                .font(.system(size: 11, weight: .medium))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous)
                .fill(Color.accentColor.opacity(0.18))
        )
        .foregroundStyle(Color.accentColor)
    }
}

#Preview {
    NavigationStack {
        AutomationsView()
    }
    .modelContainer(for: [SavedAutomation.self], inMemory: true)
}
