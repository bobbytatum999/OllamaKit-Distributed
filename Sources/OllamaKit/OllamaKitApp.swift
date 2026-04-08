import SwiftUI
import SwiftData
import UIKit
import OllamaCore

@main
struct OllamaKitApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var showingShareBanner = false
    @State private var pendingShareContent: [String: Any]?
    @Environment(\.scenePhase) private var scenePhase

    let container: ModelContainer

    @MainActor
    init() {
        container = Self.makeModelContainer()
        ModelStorage.shared.configure(container: container)
        LocalFilesScanner.shared.configure(container: container)
        // Initialize thermal monitoring
        _ = ThermalMonitorService.shared
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                ContentView()
                    .environment(\.scenePhase, scenePhase)
                    .modelContainer(container)
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active {
                    checkForPendingShares()
                }
            }
            .overlay(alignment: .top) {
                if showingShareBanner {
                    SharePendingBanner(
                        content: pendingShareContent,
                        onPaste: { pasteShareContent() },
                        onDismiss: { dismissShareBanner() }
                    )
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                }
            }
            .fullScreenCover(isPresented: Binding(
                get: { !hasCompletedOnboarding },
                set: { hasCompletedOnboarding = !$0 }
            )) {
                OnboardingView(hasCompletedOnboarding: $hasCompletedOnboarding)
            }
        }
    }

    private func checkForPendingShares() {
        guard let sharedItems = UserDefaults(suiteName: "group.com.ollamakit.app")?.array(forKey: "pendingShare") as? [[String: Any]],
              let firstItem = sharedItems.first else {
            return
        }

        pendingShareContent = firstItem
        showingShareBanner = true

        // Clear pending share so it doesn't show again
        UserDefaults(suiteName: "group.com.ollamakit.app")?.removeObject(forKey: "pendingShare")
    }

    private func pasteShareContent() {
        guard let content = pendingShareContent else { return }

        if let text = content["content"] as? String {
            UIPasteboard.general.string = text
        }

        showingShareBanner = false
        pendingShareContent = nil
        Task { @MainActor in
            HapticManager.notification(.success)
        }
    }

    private func dismissShareBanner() {
        showingShareBanner = false
        pendingShareContent = nil
    }

    @MainActor
    private static func makeModelContainer() -> ModelContainer {
        let schema = Schema([
            DownloadedModel.self,
            ChatSession.self,
            ChatMessage.self,
            FileSource.self,
            IndexedFile.self,
            SavedAutomation.self
        ])

        do {
            let persistentConfig = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
            return try ModelContainer(for: schema, configurations: [persistentConfig])
        } catch {
            AppLogStore.shared.record(
                .app,
                level: .warning,
                title: "SwiftData Persistent Store Failed",
                message: "Falling back to in-memory store: \(error.localizedDescription)",
                metadata: ["error": error.localizedDescription]
            )
        }

        do {
            let inMemoryConfig = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            return try ModelContainer(for: schema, configurations: [inMemoryConfig])
        } catch {
            fatalError("Failed to create any ModelContainer: \(error)")
        }
    }
}

struct SharePendingBanner: View {
    let content: [String: Any]?
    let onPaste: () -> Void
    let onDismiss: () -> Void

    private var previewText: String {
        if let text = content?["content"] as? String {
            return String(text.prefix(80)) + (text.count > 80 ? "…" : "")
        }
        if content?["data"] != nil {
            return "[Image shared]"
        }
        return "Shared content"
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.and.arrow.down.fill")
                .font(.system(size: 20))
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text("Shared to OllamaKit")
                    .font(.system(size: 14, weight: .semibold))
                Text(previewText)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button(action: onPaste) {
                Text("Paste")
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        Capsule()
                            .fill(Color.accentColor)
                    )
                    .foregroundStyle(.white)
            }

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(.ultraThinMaterial))
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(.white.opacity(0.15), lineWidth: 0.6)
                )
        )
        .shadow(color: .black.opacity(0.15), radius: 10, x: 0, y: 4)
    }
}

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        _ = BackgroundTaskManager.shared
        // Start background server if enabled
        Task {
            await ServerManager.shared.startServerIfEnabled()
        }
        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        guard ServerManager.shared.isServerRunning else { return }
        // Keep server running in background
        BackgroundTaskManager.shared.scheduleBackgroundTask()
    }
}

struct OnboardingView: View {
    @Binding var hasCompletedOnboarding: Bool
    @State private var currentPage = 0
    @State private var selectedOnboardingModel: String?
    @StateObject private var modelStore = ModelStorage.shared

    private let recommendedModels: [(id: String, displayName: String, description: String, size: String)] = [
        ("llama3.2:1b", "Llama 3.2 1B", "Fast & lightweight, great for everyday use", "1.3 GB"),
        ("llama3.2:3b", "Llama 3.2 3B", "Balanced performance and quality", "2.0 GB"),
        ("qwen2.5:1.5b", "Qwen 2.5 1.5B", "Excellent multilingual support", "1.0 GB"),
        ("phi3.5:3b", "Phi-3.5 Mini 3B", "Strong reasoning in a small package", "2.3 GB"),
        ("mistral:7b", "Mistral 7B", "Popular open-source model", "4.4 GB")
    ]

    var body: some View {
        ZStack {
            Color(hex: "0F0F23").ignoresSafeArea()

            TabView(selection: $currentPage) {
                OnboardingPage(
                    icon: "cpu",
                    title: "Welcome to OllamaKit",
                    subtitle: "Run local AI models directly on your iPhone",
                    selectedModel: $selectedOnboardingModel
                )
                .tag(0)

                OnboardingPage(
                    icon: "arrow.down.circle",
                    title: "Download Models",
                    subtitle: "Browse thousands of GGUF models from HuggingFace. Downloads stay on your device.",
                    selectedModel: $selectedOnboardingModel
                )
                .tag(1)

                OnboardingPage(
                    icon: "server.rack",
                    title: "API Server",
                    subtitle: "Expose a local API server and use OllamaKit as a backend for any app",
                    selectedModel: $selectedOnboardingModel
                )
                .tag(2)

                OnboardingPage(
                    icon: "checkmark.circle",
                    title: "Ready to Go",
                    subtitle: "Pick a model to get started — we recommend smaller models for your first download",
                    showModelPicker: true,
                    onModelSelected: { modelId in
                        selectedOnboardingModel = modelId
                    },
                    recommendedModels: recommendedModels,
                    selectedModel: $selectedOnboardingModel
                )
                .tag(3)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))

            VStack {
                Spacer()
                if currentPage < 3 {
                    Button("Skip") {
                        hasCompletedOnboarding = false
                    }
                    .font(.caption)
                    .foregroundStyle(.gray)
                    .padding(.bottom, 20)
                } else {
                    Button(selectedOnboardingModel != nil ? "Download \(recommendedModels.first(where: { $0.id == selectedOnboardingModel })?.displayName ?? "Model")" : "Get Started") {
                        hasCompletedOnboarding = true
                    }
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 14)
                    .background(Color(hex: "8B5CF6"))
                    .clipShape(Capsule())
                    .padding(.bottom, 40)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

struct OnboardingPage: View {
    let icon: String
    let title: String
    let subtitle: String
    var showModelPicker: Bool = false
    var onModelSelected: ((String?) -> Void)?
    var recommendedModels: [(id: String, displayName: String, description: String, size: String)] = []
    @Binding var selectedModel: String?

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 80))
                .foregroundStyle(Color(hex: "8B5CF6"))
            Text(title)
                .font(.title).fontWeight(.bold)
                .foregroundStyle(.white)
            Text(subtitle)
                .font(.body)
                .foregroundStyle(.gray)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            if showModelPicker {
                VStack(spacing: 12) {
                    ForEach(recommendedModels, id: \.id) { model in
                        Button {
                            if selectedModel == model.id {
                                selectedModel = nil
                                onModelSelected?(nil)
                            } else {
                                selectedModel = model.id
                                onModelSelected?(model.id)
                            }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(model.displayName)
                                        .font(.system(size: 15, weight: .semibold))
                                    Text(model.description)
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(model.size)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.secondary)
                                if selectedModel == model.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(Color(hex: "8B5CF6"))
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(selectedModel == model.id ? Color(hex: "8B5CF6").opacity(0.15) : Color.white.opacity(0.05))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 12)
                                            .stroke(selectedModel == model.id ? Color(hex: "8B5CF6").opacity(0.5) : Color.white.opacity(0.1), lineWidth: 1)
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 32)
            }

            Spacer()
            Spacer()
        }
    }
}

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b: UInt64
        (r, g, b) = ((int >> 16) & 0xFF, (int >> 8) & 0xFF, int & 0xFF)
        self.init(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
    }
}
