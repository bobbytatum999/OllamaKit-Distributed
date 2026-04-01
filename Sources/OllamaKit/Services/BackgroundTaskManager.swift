import Foundation
import BackgroundTasks

class BackgroundTaskManager {
    static let shared = BackgroundTaskManager()
    
    private let backgroundTaskIdentifier = "com.ollamakit.serverkeepalive"
    
    private init() {
        registerBackgroundTask()
    }
    
    func registerBackgroundTask() {
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: backgroundTaskIdentifier, using: nil) { [weak self] task in
            guard let processingTask = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            self?.handleBackgroundTask(processingTask)
        }
        if !registered {
            print("Failed to register background task identifier: \(backgroundTaskIdentifier)")
        }
    }
    
    func scheduleBackgroundTask() {
        guard AppSettings.shared.serverEnabled else { return }

        let request = BGProcessingTaskRequest(identifier: backgroundTaskIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        
        do {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: backgroundTaskIdentifier)
            try BGTaskScheduler.shared.submit(request)
        } catch {
            print("Failed to schedule background task: \(error)")
        }
    }

    func cancelScheduledBackgroundTask() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: backgroundTaskIdentifier)
    }
    
    private func handleBackgroundTask(_ task: BGProcessingTask) {
        scheduleBackgroundTask()
        
        Task {
            await ServerManager.shared.startServerIfEnabled()
            task.setTaskCompleted(success: true)
        }
        
        task.expirationHandler = {
            // Clean up if needed
        }
    }
}
