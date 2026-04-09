import Foundation

@MainActor
final class ThermalMonitorService: ObservableObject {
    static let shared = ThermalMonitorService()

    @Published private(set) var thermalState: ProcessInfo.ThermalState

    private init(processInfo: ProcessInfo = .processInfo, notificationCenter: NotificationCenter = .default) {
        thermalState = processInfo.thermalState

        notificationCenter.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: processInfo,
            queue: .main
        ) { [weak self] _ in
            self?.thermalState = processInfo.thermalState
        }
    }

    var isElevated: Bool {
        thermalState == .serious || thermalState == .critical
    }
}
