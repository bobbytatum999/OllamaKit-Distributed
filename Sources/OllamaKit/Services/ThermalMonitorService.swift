import Combine
import Foundation
import OllamaCore

/// Continuously monitors device thermal state and provides estimated temperatures.
/// Note: iOS does not expose actual CPU temperature via public APIs.
/// ProcessInfo.thermalState provides categorical levels. We map these to
/// estimated temperature ranges based on documented iOS thermal management behavior.
@MainActor
final class ThermalMonitorService: ObservableObject {
    static let shared = ThermalMonitorService()

    @Published private(set) var thermalState: ProcessInfo.ThermalState

    var isElevated: Bool {
        thermalState == .serious || thermalState == .critical
    }

    /// Estimated temperature range for each thermal state, in Celsius.
    /// Based on documented iOS thermal management behavior.
    private static let estimatedCelsiusRanges: [ProcessInfo.ThermalState: ClosedRange<Double>] = [
        .nominal:   20...40,
        .fair:      40...50,
        .serious:   50...60,
        .critical:  60...80,
    ]

    /// Converts Celsius to Fahrenheit.
    private static func toFahrenheit(_ celsius: Double) -> Double {
        celsius * 9.0 / 5.0 + 32.0
    }

    /// Estimated temperature at current state (midpoint of range), in Celsius.
    @Published private(set) var temperatureCelsius: Double = 30.0

    /// Estimated temperature at current state (midpoint of range), in Fahrenheit.
    @Published private(set) var temperatureFahrenheit: Double = 86.0

    /// Min/max estimated range for current state, in Celsius.
    @Published private(set) var temperatureRangeCelsius: ClosedRange<Double> = 20...40

    /// Min/max estimated range for current state, in Fahrenheit.
    @Published private(set) var temperatureRangeFahrenheit: ClosedRange<Double> = 68...104

    /// Human-readable status label.
    @Published private(set) var statusLabel: String = "Normal"

    /// Color name for current severity (nominal=fair=green, serious=yellow, critical=red).
    @Published private(set) var severityColor: String = "green"

    /// Whether continuous monitoring is enabled.
    @Published var monitoringEnabled: Bool = true {
        didSet {
            if monitoringEnabled {
                startPolling()
            } else {
                stopPolling()
            }
            AppSettings.shared.thermalMonitoringEnabled = monitoringEnabled
        }
    }

    private var pollingTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    private init() {
        let initialState = ProcessInfo.processInfo.thermalState
        let presentation = Self.presentation(for: initialState)

        thermalState = initialState
        temperatureCelsius = presentation.temperatureCelsius
        temperatureFahrenheit = presentation.temperatureFahrenheit
        temperatureRangeCelsius = presentation.rangeCelsius
        temperatureRangeFahrenheit = presentation.rangeFahrenheit
        statusLabel = presentation.statusLabel
        severityColor = presentation.severityColor
        monitoringEnabled = AppSettings.shared.thermalMonitoringEnabled

        setupNotificationObserver()
        if monitoringEnabled {
            startPolling()
        }
    }

    deinit {
        pollingTimer?.invalidate()
    }

    // MARK: - Public

    /// Manually refresh the current state.
    func refresh() {
        updateFromThermalState(ProcessInfo.processInfo.thermalState)
    }

    // MARK: - Private

    private func setupNotificationObserver() {
        NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateFromThermalState(ProcessInfo.processInfo.thermalState)
            }
            .store(in: &cancellables)
    }

    private func startPolling() {
        pollingTimer?.invalidate()
        // Poll every 2 seconds for continuous updates
        pollingTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    private func stopPolling() {
        pollingTimer?.invalidate()
        pollingTimer = nil
    }

    private func updateFromThermalState(_ state: ProcessInfo.ThermalState) {
        thermalState = state
        let presentation = Self.presentation(for: state)
        temperatureRangeCelsius = presentation.rangeCelsius
        temperatureCelsius = presentation.temperatureCelsius
        temperatureFahrenheit = presentation.temperatureFahrenheit
        temperatureRangeFahrenheit = presentation.rangeFahrenheit
        statusLabel = presentation.statusLabel
        severityColor = presentation.severityColor
    }

    private static func presentation(for state: ProcessInfo.ThermalState) -> (
        rangeCelsius: ClosedRange<Double>,
        temperatureCelsius: Double,
        temperatureFahrenheit: Double,
        rangeFahrenheit: ClosedRange<Double>,
        statusLabel: String,
        severityColor: String
    ) {
        let range = estimatedCelsiusRanges[state] ?? 20...40
        let midCelsius = (range.lowerBound + range.upperBound) / 2.0
        return (
            rangeCelsius: range,
            temperatureCelsius: midCelsius,
            temperatureFahrenheit: toFahrenheit(midCelsius),
            rangeFahrenheit: toFahrenheit(range.lowerBound)...toFahrenheit(range.upperBound),
            statusLabel: label(for: state),
            severityColor: color(for: state)
        )
    }

    private static func label(for state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal:  return "Normal"
        case .fair:     return "Warm"
        case .serious:   return "Hot"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }

    private static func color(for state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal:  return "green"
        case .fair:     return "green"
        case .serious:   return "yellow"
        case .critical: return "red"
        @unknown default: return "gray"
        }
    }
}

// MARK: - AppSettings extension for thermal monitoring preference

extension AppSettings {
    private static let thermalMonitoringKey = "thermal_monitoring_enabled"

    var thermalMonitoringEnabled: Bool {
        get { (UserDefaults.standard.object(forKey: Self.thermalMonitoringKey) as? Bool) ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.thermalMonitoringKey) }
    }
}
