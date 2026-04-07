import SwiftUI
import SwiftData
import UIKit
import OllamaCore

@main
struct OllamaKitApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var thermalState: ProcessInfo.ThermalState = .nominal
    
    let container: ModelContainer
    
    @MainActor
    init() {
        container = Self.makeModelContainer()
        ModelStorage.shared.configure(container: container)
        LocalFilesScanner.shared.configure(container: container)
    }
    
    var body: some Scene {
        WindowGroup {
            ZStack {
                ContentView()
                    .modelContainer(container)
                
                if thermalState == .serious {
                    VStack {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                            Text("Device is warm — inference may slow down").font(.caption).foregroundStyle(.yellow)
                            Spacer()
                        }
                        .padding(12)
                        .background(Color.black.opacity(0.9))
                        Spacer()
                    }
                }
                if thermalState == .critical {
                    VStack {
                        HStack {
                            Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(.red)
                            Text("Device too hot — inference paused").font(.caption).foregroundStyle(.red)
                            Spacer()
                        }
                        .padding(12)
                        .background(Color.black.opacity(0.9))
                        Spacer()
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)) { _ in
                thermalState = ProcessInfo.processInfo.thermalState
            }
            .fullScreenCover(isPresented: Binding(
                get: { !hasCompletedOnboarding },
                set: { hasCompletedOnboarding = !$0 }
            )) {
                OnboardingView(hasCompletedOnboarding: $hasCompletedOnboarding)
            }
        }
    }

    @MainActor
    private static func makeModelContainer() -> ModelContainer {
        let schema = Schema([
            DownloadedModel.self,
            ChatSession.self,
            ChatMessage.self,
            FileSource.self,
            IndexedFile.self
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
    
    var body: some View {
        ZStack {
            Color(hex: "0F0F23").ignoresSafeArea()
            
            TabView(selection: $currentPage) {
                OnboardingPage(
                    icon: "cpu",
                    title: "Welcome to OllamaKit",
                    subtitle: "Run local AI models directly on your iPhone"
                )
                .tag(0)
                
                OnboardingPage(
                    icon: "arrow.down.circle",
                    title: "Download Models",
                    subtitle: "Browse thousands of GGUF models from HuggingFace. Downloads stay on your device."
                )
                .tag(1)
                
                OnboardingPage(
                    icon: "server.rack",
                    title: "API Server",
                    subtitle: "Expose a local API server and use OllamaKit as a backend for any app"
                )
                .tag(2)
                
                OnboardingPage(
                    icon: "checkmark.circle",
                    title: "Ready to Go",
                    subtitle: "Download your first model and start chatting"
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
                    Button("Get Started") {
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
