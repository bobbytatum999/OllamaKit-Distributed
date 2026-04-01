import SwiftUI
import WebKit

struct AgentView: View {
    @ObservedObject private var settings = AppSettings.shared
    @StateObject private var workspaceManager = AgentWorkspaceManager.shared
    @StateObject private var approvals = AgentApprovalCenter.shared
    @StateObject private var agentLogs = AgentLogStore.shared
    @StateObject private var modelStore = ModelStorage.shared
    @StateObject private var bundlePatches = BundlePatchStore.shared

    @State private var runtimeContext: AgentJSONValue?
    @State private var githubSummary: AgentJSONValue?
    @State private var workflowRuns: AgentJSONValue?
    @State private var workflowArtifacts: AgentJSONValue?
    @State private var workflowLogInfo: AgentJSONValue?
    @State private var displayedLogs: [AgentLogEntry] = []
    @State private var liveLogs = true
    @State private var logSearch = ""
    @State private var errorMessage: String?

    private var activeWorkspace: AgentWorkspaceRecord? {
        workspaceManager.activeWorkspace()
    }

    private var previewURL: URL? {
        workspaceManager.currentPreviewURL()
    }

    private var showsBundleSection: Bool {
        settings.isJailbreakBuild && (
            !bundlePatches.records.isEmpty ||
            workspaceManager.workspaces.contains(where: { $0.kind == .bundleLive })
        )
    }

    private var filteredLogs: [AgentLogEntry] {
        let needle = logSearch.trimmedForLookup.lowercased()
        guard !needle.isEmpty else { return displayedLogs }
        return displayedLogs.filter { entry in
            [
                entry.title,
                entry.message,
                entry.category.rawValue,
                entry.level.rawValue,
                entry.body ?? ""
            ]
            .joined(separator: " ")
            .lowercased()
            .contains(needle)
        }
    }

    private var exportedLogText: String {
        filteredLogs.map(renderLogEntry).joined(separator: "\n\n")
    }

    var body: some View {
        ZStack {
            AnimatedMeshBackground()

            ScrollView {
                VStack(spacing: 20) {
                    SurfaceSectionCard(
                        title: "Runtime",
                        footer: "Standard sideload mode edits internal writable workspaces. If the live bundle is writable, the app exposes it as a separate expert workspace with backups and restart requirements."
                    ) {
                        runtimeSection
                    }

                    SurfaceSectionCard(title: "Approvals") {
                        approvalsSection
                    }

                    SurfaceSectionCard(title: "Checkpoints") {
                        checkpointsSection
                    }

                    SurfaceSectionCard(title: "GitHub") {
                        githubSection
                    }

                    SurfaceSectionCard(title: "Actions") {
                        actionsSection
                    }

                    SurfaceSectionCard(title: "Preview") {
                        previewSection
                    }

                    if showsBundleSection {
                        SurfaceSectionCard(title: "Bundle Patches") {
                            bundleSection
                        }
                    }

                    SurfaceSectionCard(title: "Tools") {
                        toolsSection
                    }

                    SurfaceSectionCard(title: "Agent Logs") {
                        logsSection
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            }
            .scrollIndicators(.hidden)
        }
        .navigationTitle("Agent")
        .task {
            workspaceManager.bootstrapIfNeeded()
            BundlePatchStore.shared.bootstrapIfNeeded()
            await refreshContext()
            displayedLogs = agentLogs.entries
        }
        .onChange(of: agentLogs.entries) { _, newValue in
            if liveLogs {
                displayedLogs = newValue
            }
        }
        .alert("Agent Error", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
    }

    private var runtimeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(settings.powerAgentEnabled ? "Power Agent Enabled" : "Power Agent Disabled")
                        .font(.system(size: 16, weight: .semibold))
                    Text(activeWorkspace?.name ?? "No active workspace")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Refresh Context") {
                    Task { await refreshContext() }
                }
                .font(.system(size: 13, weight: .medium))
            }

            if let context = runtimeContext?.objectValue {
                contextRow(title: "App", value: context["app"]?.compactDescription ?? "Unknown")
                contextRow(title: "Build Variant", value: context["app"]?.objectValue?["build_variant"]?.stringValue ?? "Unknown")
                contextRow(title: "Device", value: context["device"]?.compactDescription ?? "Unknown")
                contextRow(title: "Server", value: context["server"]?.compactDescription ?? "Unknown")
                contextRow(title: "Agent", value: context["agent"]?.compactDescription ?? "Unknown")
                contextRow(title: "Agent Model", value: context["active_model"]?.compactDescription ?? "No model selected")
                contextRow(title: "Workspace", value: context["workspace_summary"]?.compactDescription ?? "Unknown")
                contextRow(title: "Capabilities", value: context["capabilities"]?.compactDescription ?? "Unknown")
                contextRow(title: "Model Tool Access", value: context["agent_model_capabilities"]?.compactDescription ?? "No model-specific agent capabilities")
            } else {
                Text("Runtime context has not been loaded yet.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Button("Create Checkpoint") {
                    do {
                        _ = try workspaceManager.createCheckpoint(name: "Manual Checkpoint", reason: "Created from the Agent tab.")
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }

                Button("Reset Seed", role: .destructive) {
                    do {
                        _ = try workspaceManager.resetBuiltInWorkspaceToSeed()
                        Task { await refreshContext() }
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
            }
            .font(.system(size: 13, weight: .medium))
        }
    }

    private var approvalsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if approvals.requests.isEmpty {
                Text("No pending approvals.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(approvals.requests) { request in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(request.title)
                            .font(.system(size: 15, weight: .semibold))
                        Text(request.summary)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                        HStack {
                            Button("Approve") {
                                Task {
                                    _ = await AgentToolRuntime.shared.approve(requestID: request.id)
                                    await refreshContext()
                                }
                            }
                            Button("Reject", role: .destructive) {
                                _ = AgentToolRuntime.shared.reject(requestID: request.id)
                            }
                        }
                        .font(.system(size: 13, weight: .medium))
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(.ultraThinMaterial)
                    )
                }
            }
        }
    }

    private var checkpointsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            let checkpoints = workspaceManager.checkpointRecords().prefix(8)
            if checkpoints.isEmpty {
                Text("No checkpoints yet.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(checkpoints), id: \.id) { checkpoint in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(checkpoint.name)
                                .font(.system(size: 14, weight: .medium))
                            Text(checkpoint.createdAt, style: .relative)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Restore") {
                            do {
                                _ = try workspaceManager.restoreCheckpoint(checkpointID: checkpoint.id)
                                Task { await refreshContext() }
                            } catch {
                                errorMessage = error.localizedDescription
                            }
                        }
                        .font(.system(size: 13, weight: .medium))
                    }
                }
            }
        }
    }

    private var githubSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(settings.agentGitHubRepository.nonEmpty ?? "No repository configured")
                    .font(.system(size: 14, design: .monospaced))
                Spacer()
                Button("Load") {
                    Task { await loadGitHubData() }
                }
                .font(.system(size: 13, weight: .medium))
            }

            if let githubSummary {
                contextRow(title: "Repository", value: githubSummary.compactDescription)
            }

            if let workflowRuns = workflowRuns?.objectValue?["workflow_runs"]?.arrayValue {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(workflowRuns.prefix(4).enumerated()), id: \.offset) { _, run in
                        Text(run.compactDescription)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            HStack(spacing: 12) {
                Button("Start Device Flow") {
                    Task {
                        do {
                            _ = try await GitHubService.shared.startDeviceFlow(clientID: settings.agentGitHubClientID)
                            await refreshContext()
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                }
                .disabled(settings.agentGitHubClientID.trimmedForLookup.isEmpty)

                Button("Poll Login") {
                    Task {
                        do {
                            _ = try await GitHubService.shared.pollDeviceFlowToken(clientID: settings.agentGitHubClientID)
                            await refreshContext()
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                }
                .disabled(!settings.hasPendingGitHubDeviceFlow)

                Button("Refresh Mirror") {
                    Task {
                        do {
                            _ = try await AgentWorkspaceManager.shared.refreshBuiltInWorkspaceFromGitHub(
                                repository: settings.agentGitHubRepository,
                                ref: nil
                            )
                            await refreshContext()
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                }
                .disabled(settings.agentGitHubRepository.trimmedForLookup.isEmpty)

                Button("Clone Repo") {
                    Task {
                        do {
                            _ = try await AgentWorkspaceManager.shared.cloneRepositoryWorkspace(
                                repository: settings.agentGitHubRepository,
                                ref: nil
                            )
                            await refreshContext()
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                }
                .disabled(settings.agentGitHubRepository.trimmedForLookup.isEmpty)

                Button("Push Snapshot") {
                    Task {
                        guard let workspace = activeWorkspace else { return }
                        do {
                            _ = try await GitHubService.shared.pushWorkspaceSnapshot(
                                repository: settings.agentGitHubRepository,
                                branch: nil,
                                message: "Power Agent workspace sync",
                                workspace: workspace
                            )
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                }
                .disabled(settings.agentGitHubRepository.trimmedForLookup.isEmpty || settings.agentGitHubToken.trimmedForLookup.isEmpty)
            }
            .font(.system(size: 13, weight: .medium))

            if settings.hasPendingGitHubDeviceFlow {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Device Flow")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text("Code: \(settings.agentGitHubUserCode)")
                        .font(.system(size: 12, design: .monospaced))
                    Text(settings.agentGitHubVerificationURL)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let runs = workflowRuns?.objectValue?["workflow_runs"]?.arrayValue, !runs.isEmpty {
                ForEach(Array(runs.prefix(6).enumerated()), id: \.offset) { _, run in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(run.objectValue?["name"]?.stringValue ?? "Workflow")
                            .font(.system(size: 14, weight: .semibold))
                        Text(run.compactDescription)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        HStack(spacing: 12) {
                            Button("Logs") {
                                Task {
                                    do {
                                        guard let runID = run.objectValue?["id"]?.intValue else { return }
                                        workflowLogInfo = try await GitHubService.shared.workflowRunLogs(repository: settings.agentGitHubRepository, runID: runID)
                                    } catch {
                                        errorMessage = error.localizedDescription
                                    }
                                }
                            }
                            Button("Artifacts") {
                                Task {
                                    do {
                                        guard let runID = run.objectValue?["id"]?.intValue else { return }
                                        workflowArtifacts = try await GitHubService.shared.workflowArtifacts(repository: settings.agentGitHubRepository, runID: runID)
                                    } catch {
                                        errorMessage = error.localizedDescription
                                    }
                                }
                            }
                            Button("Rerun") {
                                Task {
                                    do {
                                        guard let runID = run.objectValue?["id"]?.intValue else { return }
                                        _ = try await GitHubService.shared.rerunWorkflow(repository: settings.agentGitHubRepository, runID: runID)
                                    } catch {
                                        errorMessage = error.localizedDescription
                                    }
                                }
                            }
                        }
                        .font(.system(size: 12, weight: .medium))
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial))
                }
            } else {
                Text("Load GitHub data to inspect recent workflow runs.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            if let workflowLogInfo {
                contextRow(title: "Run Logs", value: workflowLogInfo.compactDescription)
            }
            if let workflowArtifacts {
                contextRow(title: "Artifacts", value: workflowArtifacts.compactDescription)
            }
        }
    }

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let previewURL, let workspace = activeWorkspace {
                AgentPreviewWebView(url: previewURL, rootURL: URL(fileURLWithPath: workspace.rootPath, isDirectory: true))
                    .frame(height: 280)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            } else {
                Text("No local preview was found. Create `preview/index.html` or use the scaffold button.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            Button("Scaffold Preview") {
                do {
                    _ = try WebPreviewService.scaffoldStaticApp(workspaceManager: workspaceManager, workspaceID: activeWorkspace?.id)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            .font(.system(size: 13, weight: .medium))
        }
    }

    private var toolsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(AgentToolRuntime.shared.toolDescriptors()) { tool in
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(tool.title)
                            .font(.system(size: 14, weight: .semibold))
                        Text(tool.detail)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        if !tool.requiredCapabilities.isEmpty {
                            Text(tool.requiredCapabilities.map(\.rawValue).joined(separator: ", "))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                        if let availabilityReason = tool.availabilityReason?.nonEmpty, !tool.available {
                            Text(availabilityReason)
                                .font(.system(size: 11))
                                .foregroundStyle(.orange)
                        }
                    }
                    Spacer()
                    Text(tool.available ? tool.category.rawValue : "Unavailable")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(tool.available ? .blue : .orange)
                }
            }
        }
    }

    private var bundleSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if workspaceManager.workspaces.contains(where: { $0.kind == .bundleLive }) {
                Text("Writable live bundle detected. Resource edits are backed up and usually require an app restart to take effect.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            ForEach(bundlePatches.records.prefix(12)) { patch in
                VStack(alignment: .leading, spacing: 4) {
                    Text(patch.relativePath)
                        .font(.system(size: 13, weight: .semibold))
                    Text("\(patch.operation) • \(patch.createdAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                    if let backupPath = patch.backupPath?.nonEmpty {
                        Text(backupPath)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial))
            }
        }
    }

    private var logsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Search agent logs", text: $logSearch)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(.ultraThinMaterial)
                    )

                Toggle("Live", isOn: $liveLogs)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 80)
            }

            Text(agentLogs.persistenceSummary)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            HStack {
                Button("Copy") {
                    UIPasteboard.general.string = exportedLogText
                }
                Button("Clear") {
                    agentLogs.clear()
                    displayedLogs = []
                }
                .foregroundStyle(.red)
            }
            .font(.system(size: 13, weight: .medium))

            ScrollView {
                VStack(spacing: 10) {
                    ForEach(filteredLogs.suffix(60)) { entry in
                        AgentLogEntryCard(entry: entry)
                    }
                }
            }
            .frame(minHeight: 220, maxHeight: 360)
        }
    }

    private func contextRow(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
        }
    }

    private func refreshContext() async {
        let result = await AgentToolRuntime.shared.execute(toolID: "workspace.context", arguments: .object([:]))
        runtimeContext = result.data
    }

    private func loadGitHubData() async {
        guard settings.agentGitHubRepository.nonEmpty != nil else { return }
        do {
            githubSummary = try await GitHubService.shared.repositorySummary(repository: settings.agentGitHubRepository)
            workflowRuns = try await GitHubService.shared.workflowRuns(repository: settings.agentGitHubRepository)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func renderLogEntry(_ entry: AgentLogEntry) -> String {
        let timestamp = ISO8601DateFormatter().string(from: entry.timestamp)
        let metadata = entry.metadata
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        let metadataPart = metadata.isEmpty ? "" : "\n\(metadata)"
        let bodyPart = entry.body.map { "\n\($0)" } ?? ""
        return "[\(timestamp)] [\(entry.level.rawValue.uppercased())] [\(entry.category.rawValue)] \(entry.title)\n\(entry.message)\(metadataPart)\(bodyPart)"
    }
}

private struct AgentLogEntryCard: View {
    let entry: AgentLogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(entry.title)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(entry.category.rawValue)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Text(entry.message)
                .font(.system(size: 12))
            if let body = entry.body {
                Text(body)
                    .font(.system(size: 11, design: .monospaced))
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(.ultraThinMaterial))
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial))
    }
}

private struct AgentPreviewWebView: UIViewRepresentable {
    let url: URL
    let rootURL: URL

    func makeUIView(context: Context) -> WKWebView {
        WKWebView(frame: .zero)
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        webView.loadFileURL(url, allowingReadAccessTo: rootURL)
    }
}

private extension AgentJSONValue {
    var compactDescription: String {
        switch self {
        case .string(let value):
            return value
        case .int(let value):
            return String(value)
        case .double(let value):
            return String(value)
        case .bool(let value):
            return value ? "true" : "false"
        case .array(let values):
            return values.prefix(4).map(\.compactDescription).joined(separator: " | ")
        case .object(let values):
            return values
                .sorted { $0.key < $1.key }
                .prefix(6)
                .map { "\($0.key)=\($0.value.compactDescription)" }
                .joined(separator: " ")
        case .null:
            return "null"
        }
    }
}
