import Foundation
import BackgroundTasks
import OllamaCore

final class BackgroundTaskManager: @unchecked Sendable {
    static let shared = BackgroundTaskManager()

    private let backgroundTaskIdentifier = "com.ollamakit.serverkeepalive"
    private let lock = NSLock()

    private init() {
        registerBackgroundTask()
    }

    func registerBackgroundTask() {
        let registered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: backgroundTaskIdentifier,
            using: nil
        ) { [weak self] task in
            guard let self = self,
                  let processingTask = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            self.handleBackgroundTask(processingTask)
        }

        if !registered {
            Task { @MainActor in
                AppLogStore.shared.record(
                    .app,
                    level: .error,
                    title: "Background Task Registration Failed",
                    message: "Could not register: \(self.backgroundTaskIdentifier)",
                    metadata: ["task_id": self.backgroundTaskIdentifier]
                )
            }
        } else {
            Task { @MainActor in
                AppLogStore.shared.record(
                    .app,
                    level: .info,
                    title: "Background Task Registered",
                    message: "Registered: \(self.backgroundTaskIdentifier)",
                    metadata: ["task_id": self.backgroundTaskIdentifier]
                )
            }
        }
    }

    func scheduleBackgroundTask() {
        guard AppSettings.shared.serverEnabled else {
            cancelScheduledBackgroundTask()
            return
        }

        let request = BGProcessingTaskRequest(identifier: backgroundTaskIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false

        // Schedule ~15 minutes from now (iOS BGProcessingTask minimum interval)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)

        do {
            // Cancel any pending request before submitting a new one
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: backgroundTaskIdentifier)
            try BGTaskScheduler.shared.submit(request)

            Task { @MainActor in
                AppLogStore.shared.record(
                    .app,
                    level: .debug,
                    title: "Background Task Scheduled",
                    message: "Next keep-alive in ~15 minutes",
                    metadata: ["task_id": self.backgroundTaskIdentifier]
                )
            }
        } catch {
            Task { @MainActor in
                AppLogStore.shared.record(
                    .app,
                    level: .error,
                    title: "Background Task Schedule Failed",
                    message: error.localizedDescription,
                    metadata: ["error": error.localizedDescription]
                )
            }
        }
    }

    func cancelScheduledBackgroundTask() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: backgroundTaskIdentifier)

        Task { @MainActor in
            AppLogStore.shared.record(
                .app,
                level: .info,
                title: "Background Task Cancelled",
                message: "Server keep-alive scheduling stopped",
                metadata: ["task_id": self.backgroundTaskIdentifier]
            )
        }
    }

    private func handleBackgroundTask(_ task: BGProcessingTask) {
        // Always schedule the next run, even if this one fails
        scheduleBackgroundTask()

        // Expiration handler — if we don't complete in time, log and clean up
        task.expirationHandler = { [weak self] in
            Task { @MainActor in
                AppLogStore.shared.record(
                    .app,
                    level: .warning,
                    title: "Background Task Expired",
                    message: "Server keep-alive was cancelled by the system before completion.",
                    metadata: ["task_id": self?.backgroundTaskIdentifier ?? ""]
                )
            }
            // Don't call setTaskCompleted — iOS handles that on expiration
        }

        Task {
            // Run the server startup
            await ServerManager.shared.startServerIfEnabled()
            task.setTaskCompleted(success: true)
        }
    }
}
