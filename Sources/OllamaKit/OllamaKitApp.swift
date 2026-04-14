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
            AppLogStore.shared.record(
                .app,
                level: .error,
                title: "SwiftData In-Memory Store Also Failed",
                message: "Attempting recovery by resetting the persistent store: \(error.localizedDescription)",
                metadata: ["error": error.localizedDescription]
            )
        }

        // Last-resort recovery: delete the corrupted persistent store file and retry.
        // This loses persisted chat history and downloaded model records (the actual
        // GGUF files on disk are not deleted), but it prevents the app from being
        // permanently unlaunchable — which is what the previous fatalError() caused.
        do {
            let storeURL = ModelRegistryPath.documentsDirectoryURL
                .appendingPathComponent("default.store")
            let walURL = storeURL.appendingPathExtension("wal")
            let shmURL = storeURL.appendingPathExtension("shm")

            for url in [storeURL, walURL, shmURL] {
                try? FileManager.default.removeItem(at: url)
            }

            let recoveredConfig = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
            let container = try ModelContainer(for: schema, configurations: [recoveredConfig])
            AppLogStore.shared.record(
                .app,
                level: .warning,
                title: "SwiftData Store Recovered",
                message: "The corrupted persistent store was reset. Chat history has been cleared, but model files are intact.",
                metadata: [:]
            )
            return container
        } catch {
            // If we still cannot create any container, return an in-memory one
            // rather than crashing. The app will lose data this session but will
            // remain launchable so the user can investigate or reinstall.
            AppLogStore.shared.record(
                .app,
                level: .error,
                title: "SwiftData Recovery Failed — Using Emergency In-Memory Store",
                message: "All store creation attempts failed. The app will run without persistence this session: \(error.localizedDescription)",
                metadata: ["error": error.localizedDescription]
            )

            // Force-unwrap is intentional: an in-memory container with a valid schema
            // should never fail. If this throws, it indicates a schema-level bug that
            // must be fixed in development, not papered over at runtime.
            return try! ModelContainer(
                for: schema,
                configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
            )
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
    @State private var isDownloading = false
    @State private var downloadProgress = 0
    @State private var downloadSpeed = ""
    @State private var downloadEta = ""
    @State private var downloadError: String?
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
            AnimatedMeshBackground()

            VStack(spacing: 0) {
                // Top bar with Skip button (top-right, liquid glass style)
                HStack {
                    Spacer()
                    if currentPage < 3 && !isDownloading {
                        Button {
                            hasCompletedOnboarding = true
                        } label: {
                            Text("Skip")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(.white.opacity(0.8))
                                .padding(.horizontal, 20)
                                .padding(.vertical, 10)
                                .background(
                                    Capsule()
                                        .fill(.ultraThinMaterial)
                                        .overlay(
                                            Capsule()
                                                .stroke(.white.opacity(0.2), lineWidth: 0.6)
                                        )
                                )
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)

                TabView(selection: $currentPage) {
                    onboardingWelcomePage
                        .tag(0)

                    onboardingModelsPage
                        .tag(1)

                    onboardingServerPage
                        .tag(2)

                    onboardingReadyPage
                        .tag(3)
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .animation(.easeInOut(duration: 0.3), value: currentPage)

                // Bottom action area
                bottomActionArea
                    .padding(.horizontal, 24)
                    .padding(.bottom, 40)
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Pages

    private var onboardingWelcomePage: some View {
        VStack(spacing: 28) {
            Spacer()

            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color(hex: "8B5CF6").opacity(0.3), Color(hex: "8B5CF6").opacity(0.05)],
                            center: .center,
                            startRadius: 20,
                            endRadius: 80
                        )
                    )
                    .frame(width: 160, height: 160)

                Image(systemName: "cpu")
                    .font(.system(size: 64, weight: .thin))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color(hex: "A78BFA"), Color(hex: "8B5CF6")],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }

            VStack(spacing: 12) {
                Text("Welcome to")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))

                Text("OllamaKit")
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.white, Color(hex: "A78BFA")],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
            }

            Text("Run powerful AI models directly on your iPhone.\nPrivate, fast, and completely offline.")
                .font(.system(size: 17))
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .padding(.horizontal, 40)

            Spacer()
            Spacer()
        }
    }

    private var onboardingModelsPage: some View {
        VStack(spacing: 28) {
            Spacer()

            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color.cyan.opacity(0.25), Color.cyan.opacity(0.05)],
                            center: .center,
                            startRadius: 20,
                            endRadius: 80
                        )
                    )
                    .frame(width: 160, height: 160)

                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 64, weight: .thin))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.cyan, .blue],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }

            VStack(spacing: 12) {
                Text("Download Models")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(.white)

                Text("Browse thousands of GGUF models from HuggingFace.\nDownloads stay on your device — always private.")
                    .font(.system(size: 17))
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .padding(.horizontal, 36)
            }

            Spacer()
            Spacer()
        }
    }

    private var onboardingServerPage: some View {
        VStack(spacing: 28) {
            Spacer()

            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color.green.opacity(0.25), Color.green.opacity(0.05)],
                            center: .center,
                            startRadius: 20,
                            endRadius: 80
                        )
                    )
                    .frame(width: 160, height: 160)

                Image(systemName: "server.rack")
                    .font(.system(size: 64, weight: .thin))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.green, .mint],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }

            VStack(spacing: 12) {
                Text("API Server")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(.white)

                Text("Expose a local Ollama-compatible API server\nand use OllamaKit as a backend for any app.")
                    .font(.system(size: 17))
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .padding(.horizontal, 36)
            }

            Spacer()
            Spacer()
        }
    }

    private var onboardingReadyPage: some View {
        VStack(spacing: 20) {
            Spacer()

            VStack(spacing: 12) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 48, weight: .thin))
                    .foregroundStyle(Color(hex: "8B5CF6"))

                Text("Ready to Go")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(.white)

                Text("Pick a model to get started")
                    .font(.system(size: 17))
                    .foregroundStyle(.white.opacity(0.6))
            }

            // Model picker with liquid glass cards
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(recommendedModels, id: \.id) { model in
                        Button {
                            if selectedOnboardingModel == model.id {
                                selectedOnboardingModel = nil
                            } else {
                                selectedOnboardingModel = model.id
                            }
                        } label: {
                            HStack(spacing: 14) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(
                                            selectedOnboardingModel == model.id
                                                ? Color(hex: "8B5CF6").opacity(0.25)
                                                : Color.white.opacity(0.06)
                                        )
                                        .frame(width: 44, height: 44)

                                    Image(systemName: "cube.fill")
                                        .font(.system(size: 18, weight: .medium))
                                        .foregroundStyle(
                                            selectedOnboardingModel == model.id
                                                ? Color(hex: "A78BFA")
                                                : .white.opacity(0.4)
                                        )
                                }

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(model.displayName)
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundStyle(.white)
                                    Text(model.description)
                                        .font(.system(size: 13))
                                        .foregroundStyle(.white.opacity(0.5))
                                }

                                Spacer()

                                Text(model.size)
                                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.4))

                                if selectedOnboardingModel == model.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 22))
                                        .foregroundStyle(Color(hex: "8B5CF6"))
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                            .background(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(.ultraThinMaterial)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                                            .stroke(
                                                selectedOnboardingModel == model.id
                                                    ? Color(hex: "8B5CF6").opacity(0.5)
                                                    : Color.white.opacity(0.1),
                                                lineWidth: selectedOnboardingModel == model.id ? 1.5 : 0.6
                                            )
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(isDownloading)
                    }
                }
                .padding(.horizontal, 28)
            }
            .scrollIndicators(.hidden)

            // Download progress (shown inline during download)
            if isDownloading {
                VStack(spacing: 8) {
                    ProgressView(value: Double(downloadProgress) / 100.0)
                        .tint(Color(hex: "8B5CF6"))

                    HStack {
                        Text("Downloading… \(downloadProgress)%")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.7))
                        Spacer()
                        if !downloadSpeed.isEmpty {
                            Text(downloadSpeed)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                    }
                    if !downloadEta.isEmpty {
                        Text(downloadEta)
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                }
                .padding(.horizontal, 28)
            }

            if let error = downloadError {
                Text(error)
                    .font(.system(size: 13))
                    .foregroundStyle(.red.opacity(0.8))
                    .padding(.horizontal, 28)
            }

            Spacer()
        }
    }

    // MARK: - Bottom Action

    @ViewBuilder
    private var bottomActionArea: some View {
        if currentPage < 3 {
            // "Next" button for pages 0-2
            Button {
                withAnimation { currentPage += 1 }
            } label: {
                Text("Continue")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [Color(hex: "8B5CF6"), Color(hex: "7C3AED")],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                    )
            }
        } else if isDownloading {
            // During download: show skip option
            Button {
                hasCompletedOnboarding = true
            } label: {
                Text("Continue in Background")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(.ultraThinMaterial)
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .stroke(.white.opacity(0.15), lineWidth: 0.6)
                            )
                    )
            }
        } else {
            // Ready page: Get Started or Download & Start
            Button {
                if let modelId = selectedOnboardingModel {
                    startOnboardingDownload(modelId: modelId)
                } else {
                    hasCompletedOnboarding = true
                }
            } label: {
                HStack(spacing: 8) {
                    if selectedOnboardingModel != nil {
                        Image(systemName: "arrow.down.circle.fill")
                    }
                    Text(selectedOnboardingModel != nil
                        ? "Download \(recommendedModels.first(where: { $0.id == selectedOnboardingModel })?.displayName ?? "Model")"
                        : "Get Started")
                }
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color(hex: "8B5CF6"), Color(hex: "7C3AED")],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                )
            }

            if selectedOnboardingModel != nil {
                Button {
                    hasCompletedOnboarding = true
                } label: {
                    Text("Skip for Now")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .padding(.top, 8)
            }
        }
    }

    // MARK: - Download Logic

    private func startOnboardingDownload(modelId: String) {
        isDownloading = true
        downloadProgress = 0
        downloadSpeed = ""
        downloadEta = ""
        downloadError = nil

        Task { @MainActor in
            do {
                let runtimeProfile = await DeviceCapabilityService.shared.currentRuntimeProfile()
                let candidate = try await HuggingFaceService.shared.resolvePullCandidate(
                    requestedName: modelId,
                    requestedFilename: nil,
                    runtimeProfile: runtimeProfile
                )

                let seed = try await HuggingFaceService.shared.downloadModel(
                    from: candidate.file.url,
                    filename: candidate.file.filename,
                    modelId: candidate.model.modelId
                ) { progress in
                    Task { @MainActor in
                        self.downloadProgress = progress.percentage
                        if progress.speed > 0 {
                            self.downloadSpeed = progress.formattedSpeed
                            let remainingBytes = Double(progress.totalBytes - progress.downloadedBytes)
                            let remainingSeconds = Int(remainingBytes / progress.speed)
                            if remainingSeconds > 0 && remainingSeconds < 86400 {
                                let hours = remainingSeconds / 3600
                                let mins = (remainingSeconds % 3600) / 60
                                let secs = remainingSeconds % 60
                                if hours > 0 {
                                    self.downloadEta = "\(hours)h \(mins)m remaining"
                                } else {
                                    self.downloadEta = "\(mins)m \(secs)s remaining"
                                }
                            }
                        }
                    }
                }

                await ModelStorage.shared.upsertDownloadedModel(seed)
                HapticManager.notification(.success)
                isDownloading = false

                // Dismiss onboarding after successful download
                hasCompletedOnboarding = true
            } catch {
                isDownloading = false
                if (error as NSError).domain == NSURLErrorDomain && (error as NSError).code == NSURLErrorCancelled {
                    return
                }
                downloadError = error.localizedDescription
                HapticManager.notification(.error)
            }
        }
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
