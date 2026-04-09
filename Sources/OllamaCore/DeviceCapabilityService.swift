import Foundation

#if canImport(UIKit)
import UIKit
#endif

#if canImport(Metal)
import Metal
#endif

#if canImport(FoundationModels)
import FoundationModels
#endif

// FIX: changed from 'actor' to final class. The interfaceKind() method uses
// UIDevice.current which is main-thread-only, so it is marked @MainActor.
// Callers use MainActor.assumeIsolated for sync access to the singleton.
public final class DeviceCapabilityService {
    public static let shared = DeviceCapabilityService()

    public func currentProfile() -> DeviceProfile {
        currentRuntimeProfile().compatibilityProfile
    }

    public func currentRuntimeProfile() -> DeviceRuntimeProfile {
        let physicalMemory = Int64(ProcessInfo.processInfo.physicalMemory)
        let machineIdentifier = machineIdentifier()
        let recommendedBudget = max(
            min(Int64(Double(physicalMemory) * 0.30), physicalMemory - 3_000_000_000),
            1_500_000_000
        )
        let supportedBudget = max(
            min(Int64(Double(physicalMemory) * 0.42), physicalMemory - 2_000_000_000),
            recommendedBudget
        )
        let metalDevice = systemMetalDevice()

        return DeviceRuntimeProfile(
            machineIdentifier: machineIdentifier,
            chipFamily: chipFamily(for: machineIdentifier),
            systemVersion: systemVersionString(),
            physicalMemoryBytes: physicalMemory,
            interfaceKind: MainActor.assumeIsolated { interfaceKind() },
            recommendedGGUFBudgetBytes: recommendedBudget,
            supportedGGUFBudgetBytes: supportedBudget,
            hasMetalDevice: metalDevice != nil,
            metalDeviceName: metalDevice?.name
        )
    }

    public func compatibility(for entry: ModelCatalogEntry) async -> CompatibilityReport {
        switch entry.backendKind {
        case .ggufLlama:
            return await compatibilityForGGUFSize(entry.capabilitySummary.sizeBytes)
        case .appleFoundation:
            return await appleFoundationAvailability()
        case .coreMLPackage:
            return await compatibilityForCoreMLPackage(entry)
        }
    }

    public func compatibilityForGGUFSize(_ sizeBytes: Int64?) async -> CompatibilityReport {
        let profile = currentRuntimeProfile()
        guard let sizeBytes, sizeBytes > 0 else {
            return CompatibilityReport(
                backendKind: .ggufLlama,
                level: .unknown,
                title: "Unknown Size",
                message: "This GGUF file has no size metadata yet."
            )
        }

        if sizeBytes <= profile.recommendedGGUFBudgetBytes {
            return CompatibilityReport(
                backendKind: .ggufLlama,
                level: .recommended,
                title: "Recommended",
                message: "This GGUF file is within the recommended budget for \(profile.deviceLabel)."
            )
        }

        if sizeBytes <= profile.supportedGGUFBudgetBytes {
            return CompatibilityReport(
                backendKind: .ggufLlama,
                level: .supported,
                title: "May Run",
                message: "This GGUF file is larger than recommended for \(profile.deviceLabel), but it still has a realistic chance of loading."
            )
        }

        return CompatibilityReport(
            backendKind: .ggufLlama,
            level: .unavailable,
            title: "Too Large",
            message: "This GGUF file is above the likely working size for \(profile.deviceLabel)."
        )
    }

    public func appleFoundationAvailability() async -> CompatibilityReport {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, macOS 26.0, *) else {
            return CompatibilityReport(
                backendKind: .appleFoundation,
                level: .unavailable,
                title: "Unavailable",
                message: "Apple's built-in on-device model requires iOS 26 or macOS 26 or newer."
            )
        }

        let model = SystemLanguageModel.default
        guard model.supportsLocale() else {
            return CompatibilityReport(
                backendKind: .appleFoundation,
                level: .unavailable,
                title: "Unavailable",
                message: "Apple Intelligence is not enabled for the current language or locale."
            )
        }

        if case .available = model.availability {
            return CompatibilityReport(
                backendKind: .appleFoundation,
                level: .supported,
                title: "Available",
                message: "Uses Apple's built-in on-device Foundation Models runtime."
            )
        }

        let availabilityDescription = String(describing: model.availability)
        if availabilityDescription.localizedCaseInsensitiveContains("deviceNotEligible") {
            return CompatibilityReport(
                backendKind: .appleFoundation,
                level: .unavailable,
                title: "Unavailable",
                message: "This device is not eligible for Apple's on-device model."
            )
        }
        if availabilityDescription.localizedCaseInsensitiveContains("appleIntelligenceNotEnabled") {
            return CompatibilityReport(
                backendKind: .appleFoundation,
                level: .unavailable,
                title: "Unavailable",
                message: "Turn on Apple Intelligence to use Apple's on-device model."
            )
        }
        if availabilityDescription.localizedCaseInsensitiveContains("modelNotReady") {
            return CompatibilityReport(
                backendKind: .appleFoundation,
                level: .unavailable,
                title: "Unavailable",
                message: "Apple's on-device model is still preparing on this device."
            )
        }

        return CompatibilityReport(
            backendKind: .appleFoundation,
            level: .unavailable,
            title: "Unavailable",
            message: "Apple's on-device model is unavailable on this device."
        )
        #else
        return CompatibilityReport(
            backendKind: .appleFoundation,
            level: .unavailable,
            title: "Unavailable",
            message: "This build does not include Apple's Foundation Models framework."
        )
        #endif
    }

    public func compatibilityForCoreMLPackage(_ entry: ModelCatalogEntry) async -> CompatibilityReport {
        guard let packageRootURL = entry.packageRootURL else {
            return CompatibilityReport(
                backendKind: .coreMLPackage,
                level: .unavailable,
                title: "Unavailable",
                message: "This CoreML package is missing its package root."
            )
        }

        guard FileManager.default.fileExists(atPath: packageRootURL.path) else {
            return CompatibilityReport(
                backendKind: .coreMLPackage,
                level: .unavailable,
                title: "Unavailable",
                message: "This CoreML package no longer exists on disk."
            )
        }

        if let manifestURL = entry.manifestURL,
           FileManager.default.fileExists(atPath: manifestURL.path),
           let data = try? Data(contentsOf: manifestURL),
           let manifest = try? JSONDecoder().decode(ModelPackageManifest.self, from: data),
           let minimumOSVersion = manifest.minimumOSVersion,
           !supports(minimumOSVersion: minimumOSVersion) {
            return CompatibilityReport(
                backendKind: .coreMLPackage,
                level: .unavailable,
                title: "Unavailable",
                message: "This CoreML package requires iOS \(minimumOSVersion) or newer."
            )
        }

        guard let runtimeRootURL = CoreMLPackageLocator.runtimeModelRootURL(packageRootURL: packageRootURL) else {
            return CompatibilityReport(
                backendKind: .coreMLPackage,
                level: .unavailable,
                title: "Unavailable",
                message: "Import the full ANEMLL/CoreML model folder containing meta.yaml, tokenizer assets, and compiled .mlmodelc or .mlpackage payloads."
            )
        }

        #if !canImport(AnemllCore)
        return CompatibilityReport(
            backendKind: .coreMLPackage,
            level: .unavailable,
            title: "Unavailable",
            message: "This build does not include the ANEMLL CoreML runtime."
        )
        #else
        let relativeRoot = runtimeRootURL.path.replacingOccurrences(of: packageRootURL.path, with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        let detail = relativeRoot.isEmpty ? entry.displayName : relativeRoot
        return CompatibilityReport(
            backendKind: .coreMLPackage,
            level: .supported,
            title: "Supported",
            message: "This imported CoreML package includes a runnable ANEMLL payload (\(detail))."
        )
        #endif
    }

    private func machineIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        var machine = systemInfo.machine
        let capacity = MemoryLayout.size(ofValue: machine)

        return withUnsafePointer(to: &machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { charPointer in
                String(cString: charPointer)
            }
        }
    }

    private func systemVersionString() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    @MainActor private func interfaceKind() -> DeviceInterfaceKind {
        #if canImport(UIKit)
        switch UIDevice.current.userInterfaceIdiom {
        case .phone:
            return .phone
        case .pad:
            return .pad
        case .mac:
            return .mac
        default:
            return .other
        }
        #else
        return .other
        #endif
    }

    private func systemMetalDevice() -> MTLDevice? {
        #if canImport(Metal)
        MTLCreateSystemDefaultDevice()
        #else
        nil
        #endif
    }

    private func chipFamily(for machineIdentifier: String) -> String {
        let identifier = machineIdentifier.lowercased()

        if identifier.hasPrefix("realitydevice") {
            return "Apple M-Series"
        }

        if identifier.hasPrefix("arm64") {
            return "Apple Silicon"
        }

        if identifier.hasPrefix("iphone18") {
            return "Apple A19"
        }
        if identifier.hasPrefix("iphone17") {
            return "Apple A18"
        }
        if identifier.hasPrefix("iphone16") {
            return "Apple A17"
        }
        if identifier.hasPrefix("iphone15") {
            return "Apple A16"
        }
        if identifier.hasPrefix("iphone14") {
            return "Apple A15"
        }
        if identifier.hasPrefix("iphone13") {
            return "Apple A14"
        }

        if identifier.hasPrefix("ipad16,3") || identifier.hasPrefix("ipad16,4") || identifier.hasPrefix("ipad16,5") || identifier.hasPrefix("ipad16,6") {
            return "Apple M4"
        }
        if identifier.hasPrefix("ipad15") {
            return "Apple M3 / A16"
        }
        if identifier.hasPrefix("ipad14") {
            return "Apple M2 / A15"
        }
        if identifier.hasPrefix("ipad13") {
            return "Apple M1 / A14"
        }

        return "Apple Silicon"
    }

    private func supports(minimumOSVersion: String) -> Bool {
        let versionComponents = minimumOSVersion.split(separator: ".").compactMap { Int($0) }
        let requiredMajor = versionComponents.first ?? 0
        let requiredMinor = versionComponents.dropFirst().first ?? 0
        let current = ProcessInfo.processInfo.operatingSystemVersion

        if current.majorVersion != requiredMajor {
            return current.majorVersion > requiredMajor
        }

        return current.minorVersion >= requiredMinor
    }
}
