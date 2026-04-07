import SwiftUI
import SwiftData
import UIKit
import OllamaCore

@main
struct OllamaKitApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    let container: ModelContainer
    
    @MainActor
    init() {
        container = Self.makeModelContainer()
        ModelStorage.shared.configure(container: container)
        LocalFilesScanner.shared.configure(container: container)
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .modelContainer(container)
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
                category: .app,
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
