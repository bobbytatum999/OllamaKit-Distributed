import Foundation

private enum SwiftRuntimeError: LocalizedError {
    case invalidInput(String)
    case unsupportedOperation(String)
    case workspaceMissing

    var errorDescription: String? {
        switch self {
        case .invalidInput(let message):
            return message
        case .unsupportedOperation(let operation):
            return "Unsupported Swift runtime operation: \(operation)"
        case .workspaceMissing:
            return "The selected workspace path is missing."
        }
    }
}

private enum JSONValue: Codable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON.")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}

private struct SwiftRuntimeResponse: Encodable {
    let success: Bool
    let stdout: String
    let stderr: String
    let exitCode: Int
    let durationMs: Int
    let result: JSONValue?
    let artifacts: [String]
    let filesTouched: [String]
    let error: String?
}

private struct SwiftRuntimeRequest {
    let operation: String
    let input: [String: JSONValue]
    let workspaceRoot: URL
}

private func decodeInput(_ json: String) -> [String: JSONValue] {
    guard let data = json.data(using: .utf8),
          let decoded = try? JSONDecoder().decode([String: JSONValue].self, from: data) else {
        return [:]
    }
    return decoded
}

private func frameworkRoot() -> URL {
    let fileManager = FileManager.default
    if let privateFrameworks = Bundle.main.privateFrameworksURL {
        let candidate = privateFrameworks.appendingPathComponent("OllamaKitSwiftRuntime.framework", isDirectory: true)
        if fileManager.fileExists(atPath: candidate.path) {
            return candidate
        }
    }

    return Bundle.main.bundleURL
        .appendingPathComponent("Frameworks", isDirectory: true)
        .appendingPathComponent("OllamaKitSwiftRuntime.framework", isDirectory: true)
}

private func templatesRoot() -> URL {
    frameworkRoot().appendingPathComponent("Resources/OllamaKitSwift/Templates", isDirectory: true)
}

private func loadTemplate(named name: String) throws -> String {
    let templateURL = templatesRoot().appendingPathComponent(name)
    guard let value = try? String(contentsOf: templateURL, encoding: .utf8) else {
        throw SwiftRuntimeError.invalidInput("Missing Swift runtime template: \(name)")
    }
    return value
}

private func packageName(from input: [String: JSONValue]) -> String {
    if case .string(let value)? = input["name"] {
        return value
    }
    return "LocalPackage"
}

private func createFile(at url: URL, contents: String) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try contents.write(to: url, atomically: true, encoding: .utf8)
}

private func scaffoldPackage(request: SwiftRuntimeRequest) throws -> SwiftRuntimeResponse {
    let name = packageName(from: request.input)
    let root = request.workspaceRoot
    let packageSwift = try loadTemplate(named: "Package.swift.template").replacingOccurrences(of: "{{PACKAGE_NAME}}", with: name)
    let librarySwift = try loadTemplate(named: "Library.swift.template").replacingOccurrences(of: "{{PACKAGE_NAME}}", with: name)
    let testsSwift = try loadTemplate(named: "Tests.swift.template").replacingOccurrences(of: "{{PACKAGE_NAME}}", with: name)

    let touched = [
        "Package.swift",
        "Sources/\(name)/\(name)Library.swift",
        "Tests/\(name)Tests/\(name)Tests.swift"
    ]

    try createFile(at: root.appendingPathComponent("Package.swift"), contents: packageSwift)
    try createFile(at: root.appendingPathComponent("Sources/\(name)/\(name)Library.swift"), contents: librarySwift)
    try createFile(at: root.appendingPathComponent("Tests/\(name)Tests/\(name)Tests.swift"), contents: testsSwift)

    return SwiftRuntimeResponse(
        success: true,
        stdout: "Scaffolded Swift package \(name).",
        stderr: "",
        exitCode: 0,
        durationMs: 0,
        result: .object([
            "package": .string(name),
            "files": .array(touched.map(JSONValue.string))
        ]),
        artifacts: [],
        filesTouched: touched,
        error: nil
    )
}

private func inspectSources(request: SwiftRuntimeRequest) throws -> SwiftRuntimeResponse {
    guard FileManager.default.fileExists(atPath: request.workspaceRoot.path) else {
        throw SwiftRuntimeError.workspaceMissing
    }

    let enumerator = FileManager.default.enumerator(
        at: request.workspaceRoot,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
    )

    var swiftFiles: [String] = []
    var hasPackage = false
    while let next = enumerator?.nextObject() as? URL {
        let relativePath = next.path.replacingOccurrences(of: request.workspaceRoot.path + "/", with: "")
        if relativePath == "Package.swift" {
            hasPackage = true
        }
        if next.pathExtension == "swift" {
            swiftFiles.append(relativePath)
        }
    }

    return SwiftRuntimeResponse(
        success: true,
        stdout: "Inspected \(swiftFiles.count) Swift files.",
        stderr: "",
        exitCode: 0,
        durationMs: 0,
        result: .object([
            "package_manifest_present": .bool(hasPackage),
            "swift_files": .array(swiftFiles.map(JSONValue.string))
        ]),
        artifacts: [],
        filesTouched: [],
        error: nil
    )
}

private func rewritePackageName(request: SwiftRuntimeRequest) throws -> SwiftRuntimeResponse {
    guard case .string(let oldName)? = request.input["old_name"],
          case .string(let newName)? = request.input["new_name"] else {
        throw SwiftRuntimeError.invalidInput("rewrite_package_name requires old_name and new_name.")
    }

    let manifestURL = request.workspaceRoot.appendingPathComponent("Package.swift")
    guard let manifest = try? String(contentsOf: manifestURL, encoding: .utf8) else {
        throw SwiftRuntimeError.invalidInput("Package.swift is missing in the selected workspace.")
    }

    try createFile(at: manifestURL, contents: manifest.replacingOccurrences(of: oldName, with: newName))

    return SwiftRuntimeResponse(
        success: true,
        stdout: "Rewrote package name from \(oldName) to \(newName).",
        stderr: "",
        exitCode: 0,
        durationMs: 0,
        result: .object([
            "old_name": .string(oldName),
            "new_name": .string(newName)
        ]),
        artifacts: [],
        filesTouched: ["Package.swift"],
        error: nil
    )
}

private func diagnoseManifest(request: SwiftRuntimeRequest) throws -> SwiftRuntimeResponse {
    let manifestURL = request.workspaceRoot.appendingPathComponent("Package.swift")
    guard let manifest = try? String(contentsOf: manifestURL, encoding: .utf8) else {
        throw SwiftRuntimeError.invalidInput("Package.swift is missing in the selected workspace.")
    }

    var diagnostics: [JSONValue] = []
    if !manifest.contains("products:") {
        diagnostics.append(.string("Package.swift does not define a products section."))
    }
    if !manifest.contains("targets:") {
        diagnostics.append(.string("Package.swift does not define a targets section."))
    }
    if diagnostics.isEmpty {
        diagnostics.append(.string("No obvious manifest issues found."))
    }

    return SwiftRuntimeResponse(
        success: true,
        stdout: "Generated Swift manifest diagnostics.",
        stderr: "",
        exitCode: 0,
        durationMs: 0,
        result: .object([
            "diagnostics": .array(diagnostics)
        ]),
        artifacts: [],
        filesTouched: [],
        error: nil
    )
}

private func execute(script: String, inputJSON: String, workspaceRoot: String) throws -> SwiftRuntimeResponse {
    let trimmed = script.trimmingCharacters(in: .whitespacesAndNewlines)
    let input = decodeInput(inputJSON)
    let operation: String
    if !trimmed.isEmpty {
        operation = trimmed
    } else if case .string(let op)? = input["operation"] {
        operation = op
    } else {
        throw SwiftRuntimeError.invalidInput("swift.run requires an operation name in script or input.operation.")
    }

    let workspaceURL = URL(fileURLWithPath: workspaceRoot, isDirectory: true)
    let request = SwiftRuntimeRequest(operation: operation, input: input, workspaceRoot: workspaceURL)

    switch operation {
    case "scaffold_package":
        return try scaffoldPackage(request: request)
    case "inspect_sources":
        return try inspectSources(request: request)
    case "rewrite_package_name":
        return try rewritePackageName(request: request)
    case "diagnose_manifest":
        return try diagnoseManifest(request: request)
    default:
        throw SwiftRuntimeError.unsupportedOperation(operation)
    }
}

private func encodeResponse(_ response: SwiftRuntimeResponse) -> UnsafeMutablePointer<CChar>? {
    let encoder = JSONEncoder()
    guard let data = try? encoder.encode(response),
          let string = String(data: data, encoding: .utf8) else {
        return strdup("{\"success\":false,\"stdout\":\"\",\"stderr\":\"\",\"exitCode\":1,\"durationMs\":0,\"result\":null,\"artifacts\":[],\"filesTouched\":[],\"error\":\"Failed to encode Swift runtime response.\"}")
    }
    return strdup(string)
}

@_cdecl("OllamaKitSwiftRunJSON")
public func OllamaKitSwiftRunJSON(
    _ script: UnsafePointer<CChar>?,
    _ inputJSON: UnsafePointer<CChar>?,
    _ workspaceRoot: UnsafePointer<CChar>?
) -> UnsafeMutablePointer<CChar>? {
    let startedAt = Date()
    let scriptString = script.map(String.init(cString:)) ?? ""
    let inputString = inputJSON.map(String.init(cString:)) ?? "{}"
    let workspaceString = workspaceRoot.map(String.init(cString:)) ?? ""

    do {
        let raw = try execute(script: scriptString, inputJSON: inputString, workspaceRoot: workspaceString)
        let response = SwiftRuntimeResponse(
            success: raw.success,
            stdout: raw.stdout,
            stderr: raw.stderr,
            exitCode: raw.exitCode,
            durationMs: Int(Date().timeIntervalSince(startedAt) * 1000.0),
            result: raw.result,
            artifacts: raw.artifacts,
            filesTouched: raw.filesTouched,
            error: raw.error
        )
        return encodeResponse(response)
    } catch {
        let response = SwiftRuntimeResponse(
            success: false,
            stdout: "",
            stderr: "",
            exitCode: 1,
            durationMs: Int(Date().timeIntervalSince(startedAt) * 1000.0),
            result: nil,
            artifacts: [],
            filesTouched: [],
            error: error.localizedDescription
        )
        return encodeResponse(response)
    }
}
