import Foundation
import OllamaCore
import SwiftUI
import UIKit
import CoreImage.CIFilterBuiltins
#if canImport(Darwin)
import Darwin
#endif

struct ServerView: View {
    @ObservedObject private var settings = AppSettings.shared
    @StateObject private var viewModel = ServerViewModel()
    
    var body: some View {
        ZStack {
            AnimatedMeshBackground()

            ScrollView {
                VStack(spacing: 20) {
                    ServerStatusCard(viewModel: viewModel)

                    ConnectionInfoCard(viewModel: viewModel)

                    SurfaceSectionCard(title: "Server Configuration") {
                        ServerSettingsSection(settings: settings)
                    }

                    SurfaceSectionCard(title: "Security") {
                        SecuritySettingsSection(settings: settings)
                    }

                    SurfaceSectionCard(
                        title: "Live Logs",
                        footer: "Raw request and response logs are shown here with auth secrets redacted."
                    ) {
                        ServerLogsSection()
                    }

                    SurfaceSectionCard(title: "API") {
                        APIDocsSection()
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            }
            .scrollIndicators(.hidden)
        }
        .navigationTitle("Server")
        .onAppear {
            viewModel.refreshStatus()
        }
        .onChange(of: settings.serverEnabled) { _, enabled in
            Task {
                if enabled {
                    await viewModel.startServer()
                } else {
                    await viewModel.stopServer()
                }
            }
        }
        .onChange(of: settings.serverPort) {
            Task {
                await viewModel.restartServerIfNeeded()
            }
        }
        .onChange(of: settings.serverExposureMode) {
            Task {
                await viewModel.restartServerIfNeeded()
                await viewModel.refreshPublicHealth()
            }
        }
        .onChange(of: settings.publicBaseURL) {
            Task {
                await viewModel.refreshPublicHealth()
            }
        }
        .onChange(of: settings.requireApiKey) {
            Task {
                await viewModel.refreshPublicHealth()
            }
        }
        .onChange(of: relay.state) {
            Task {
                await viewModel.refreshPublicHealth()
            }
        }
    }
}

struct ServerStatusCard: View {
    @ObservedObject var viewModel: ServerViewModel
    
    var statusColor: Color {
        viewModel.isRunning ? .green : .red
    }
    
    var statusText: String {
        viewModel.isRunning ? "Running" : "Stopped"
    }
    
    var body: some View {
        VStack(spacing: 20) {
            // Status indicator
            ZStack {
                Circle()
                    .fill(statusColor.opacity(0.2))
                    .frame(width: 100, height: 100)
                
                Circle()
                    .fill(statusColor.opacity(0.3))
                    .frame(width: 80, height: 80)
                
                Image(systemName: viewModel.isRunning ? "checkmark.shield.fill" : "xmark.shield.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(statusColor)
            }
            .overlay(
                Circle()
                    .stroke(statusColor.opacity(0.5), lineWidth: 2)
            )
            
            VStack(spacing: 8) {
                Text(statusText)
                    .font(.system(size: 28, weight: .bold))
                
                if viewModel.isRunning {
                    Text("OllamaKit API Server")
                        .font(.system(size: 17))
                        .foregroundStyle(.secondary)
                    
                    HStack(spacing: 8) {
                        Text("Port \(AppSettings.shared.serverPort)")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                            .background(
                                Capsule()
                                    .fill(.ultraThinMaterial)
                            )

                        Text(AppSettings.shared.serverExposureMode.title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                Capsule()
                                    .fill(.ultraThinMaterial)
                            )

                        Text(AppSettings.shared.buildVariant.title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                Capsule()
                                    .fill(.ultraThinMaterial)
                            )
                    }
                }
            }
            
            // Toggle button
            Button {
                Task {
                    if viewModel.isRunning {
                        await viewModel.stopServer()
                    } else {
                        await viewModel.startServer()
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: viewModel.isRunning ? "stop.fill" : "play.fill")
                    Text(viewModel.isRunning ? "Stop Server" : "Start Server")
                }
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(viewModel.isRunning ? Color.red : Color.accentColor)
                )
            }
        }
        .padding(24)
        .background(
            RoundedRectangle(cornerRadius: 24)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 24)
                        .stroke(.white.opacity(0.1), lineWidth: 0.5)
                )
        )
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

struct ConnectionInfoCard: View {
    @ObservedObject var viewModel: ServerViewModel
    @State private var showingCopiedAlert = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "network")
                    .font(.system(size: 20))
                    .foregroundStyle(Color.accentColor)
                
                Text("Connection URLs")
                    .font(.system(size: 20, weight: .bold))
                
                Spacer()
            }
            
            VStack(spacing: 12) {
                URLRow(
                    label: "Local",
                    url: AppSettings.shared.localServerURL,
                    description: "For apps on this device"
                )

                if AppSettings.shared.serverExposureMode.allowsRemoteConnections {
                    Divider()

                    URLRow(
                        label: "Network",
                        url: viewModel.networkURL,
                        description: "For other devices on your network"
                    )
                }

                if AppSettings.shared.serverExposureMode.isPublic {
                    Divider()

                    URLRow(
                        label: "Public",
                        url: AppSettings.shared.publicServerURL.nonEmpty ?? "Not Configured",
                        description: viewModel.publicHealthDetail
                    )

                    HealthStatusRow(
                        title: "Public URL Health",
                        status: viewModel.publicHealthTitle,
                        tint: viewModel.publicHealthColor
                    )


                }
            }

            if viewModel.isRunning {
                let serverURL = viewModel.networkURL.isEmpty ? AppSettings.shared.localServerURL : viewModel.networkURL
                Divider()
                
                VStack(spacing: 12) {
                    Text("QR Code")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                    
                    if let qrImage = generateQRCode(from: serverURL) {
                        Image(uiImage: qrImage)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 140, height: 140)
                            .padding(12)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    
                    HStack(spacing: 12) {
                        Button {
                            UIPasteboard.general.string = serverURL
                            showingCopiedAlert = true
                        } label: {
                            Label("Copy URL", systemImage: "doc.on.doc")
                                .font(.system(size: 13))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        
                        ShareLink(item: serverURL) {
                            Label("Share", systemImage: "square.and.arrow.up")
                                .font(.system(size: 13))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    
                    Text(serverURL)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            } else {
                Divider()
                HStack(spacing: 12) {
                    Image(systemName: "qrcode")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Server Not Running")
                            .font(.system(size: 15, weight: .semibold))
                        Text("Start the server to generate a QR code")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 8)
            }

            Text("Background availability is best-effort on iOS. The app can restart the server after background task wakeups, but iOS may still suspend the process.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(.white.opacity(0.1), lineWidth: 0.5)
                )
        )
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

struct URLRow: View {
    let label: String
    let url: String
    let description: String
    
    @State private var showingCopied = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(.ultraThinMaterial)
                    )
                
                Spacer()
                
                Button {
                    UIPasteboard.general.string = url
                    Task { @MainActor in
                        HapticManager.notification(.success)
                    }
                    withAnimation {
                        showingCopied = true
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        withAnimation {
                            showingCopied = false
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: showingCopied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 12))
                        Text(showingCopied ? "Copied" : "Copy")
                            .font(.system(size: 12))
                    }
                    .foregroundStyle(Color.accentColor)
                }
            }
            
            Text(url)
                .font(.system(size: 15, weight: .medium, design: .monospaced))
                .textSelection(.enabled)
            
            Text(description)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
        )
    }
}

struct HealthStatusRow: View {
    let title: String
    let status: String
    let tint: Color

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)

            Spacer()

            Text(status)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
        )
    }
}

struct ServerSettingsSection: View {
    @ObservedObject var settings: AppSettings
    @State private var showingPortPicker = false
    
    var body: some View {
        VStack(spacing: 0) {
            // Port setting
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Server Port")
                        .font(.system(size: 16, weight: .medium))
                    Text("Port for the API server")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                Button {
                    showingPortPicker = true
                } label: {
                    Text("\(settings.serverPort)")
                        .font(.system(size: 16, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(.ultraThinMaterial)
                        )
                }
            }
            .padding(.vertical, 12)
            
            Divider()
            
            // Auto-start toggle
            Toggle(isOn: $settings.serverEnabled) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Auto-start Server")
                        .font(.system(size: 16, weight: .medium))
                    Text("Start server when app launches")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 12)
            
            Divider()

            Picker(selection: $settings.serverExposureMode) {
                ForEach(ServerExposureMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Exposure Mode")
                        .font(.system(size: 16, weight: .medium))
                    Text(settings.serverExposureMode.description)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }
            .pickerStyle(.menu)
            .padding(.vertical, 12)



            if settings.serverExposureMode == .publicCustom {
                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Custom Public Base URL")
                        .font(.system(size: 16, weight: .medium))

                    Text("Use the public URL from your own tunnel or reverse proxy. OllamaKit will treat it as the canonical remote endpoint but will not create the tunnel itself.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)

                    TextField("https://your-public-url.example.com", text: $settings.publicBaseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(size: 14, design: .monospaced))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(.ultraThinMaterial)
                        )

                    if settings.normalizedPublicBaseURL == nil {
                        Text("Enter a valid http:// or https:// URL to use Custom Public URL mode.")
                            .font(.system(size: 12))
                            .foregroundStyle(.orange)
                    }
                }
                .padding(.vertical, 12)
            }
        }
        .sheet(isPresented: $showingPortPicker) {
            PortPickerSheet(port: $settings.serverPort)
        }
    }
}

struct SecuritySettingsSection: View {
    @ObservedObject var settings: AppSettings
    @State private var showingAPIKey = false
    
    var body: some View {
        VStack(spacing: 0) {
            // API Key toggle
            Toggle(
                isOn: Binding(
                    get: { settings.isAPIKeyRequiredForCurrentExposure },
                    set: { settings.requireApiKey = $0 }
                )
            ) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Require API Key")
                        .font(.system(size: 16, weight: .medium))
                    Text(settings.serverExposureMode.isPublic
                        ? "Required in public exposure modes"
                        : "Protect server with authentication")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(settings.serverExposureMode.isPublic)
            .padding(.vertical, 12)

            if settings.serverExposureMode.isPublic {
                Divider()

                Text(settings.serverExposureMode == .publicManaged
                     ? "Managed public relay mode always requires API-key authentication. The relay authenticates the device separately, but remote API clients must still send your API key."
                     : "Custom public URL mode always requires API-key authentication. Keep this key private and configure your tunnel or proxy to forward it securely.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)
            }

            if settings.isAPIKeyRequiredForCurrentExposure {
                Divider()
                
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("API Key")
                            .font(.system(size: 16, weight: .medium))
                        Text("Use this key in API requests")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    
                    Spacer()
                    
                    HStack(spacing: 8) {
                        Text(showingAPIKey ? settings.apiKey : String(repeating: "•", count: 16))
                            .font(.system(size: 14, weight: .medium, design: .monospaced))
                        
                        Button {
                            showingAPIKey.toggle()
                        } label: {
                            Image(systemName: showingAPIKey ? "eye.slash" : "eye")
                                .font(.system(size: 14))
                                .foregroundStyle(.secondary)
                        }
                        
                        Button {
                            UIPasteboard.general.string = settings.apiKey
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 14))
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(.ultraThinMaterial)
                    )
                }
                .padding(.vertical, 12)
                
                Divider()
                
                Button {
                    settings.apiKey = String(UUID().uuidString.prefix(16)).uppercased()
                } label: {
                    HStack {
                        Image(systemName: "arrow.clockwise")
                        Text("Regenerate API Key")
                    }
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                }
                .padding(.vertical, 12)
            }
        }
    }
}

struct APIDocsSection: View {
    @State private var showingDocs = false
    
    let endpoints = [
        ("GET", "/api/tags", "List validated server-runnable models"),
        ("POST", "/api/show", "Show model validation and capability detail"),
        ("POST", "/api/generate", "Generate text completion"),
        ("POST", "/api/chat", "Chat completion"),
        ("POST", "/api/embed", "Conditional embeddings endpoint"),
        ("POST", "/api/pull", "Download and validate a model"),
        ("DELETE", "/api/delete", "Delete a model"),
        ("GET", "/api/ps", "List running models"),
        ("GET", "/v1/models", "OpenAI-compatible validated model list"),
        ("POST", "/v1/completions", "OpenAI-compatible completions"),
        ("POST", "/v1/chat/completions", "OpenAI-compatible chat"),
        ("POST", "/v1/embeddings", "Conditional OpenAI embeddings endpoint"),
        ("POST", "/v1/responses", "OpenAI-style rich responses")
    ]
    
    var body: some View {
        VStack(spacing: 0) {
            Button {
                showingDocs = true
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("API Documentation")
                            .font(.system(size: 16, weight: .medium))
                        Text("View available endpoints")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    
                    Spacer()
                    
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            .padding(.vertical, 12)
            
            Divider()
            
            // Quick endpoint list
            VStack(alignment: .leading, spacing: 8) {
                Text("Endpoints")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                
                ForEach(endpoints, id: \.1) { method, path, desc in
                    HStack(spacing: 8) {
                        Text(method)
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(methodColor(method))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(methodColor(method).opacity(0.2))
                            )
                        
                        Text(path)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 12)
        }
        .sheet(isPresented: $showingDocs) {
            APIDocumentationView()
        }
    }
    
    func methodColor(_ method: String) -> Color {
        switch method {
        case "GET": return .blue
        case "POST": return .green
        case "DELETE": return .red
        default: return .gray
        }
    }
}

struct ServerLogsSection: View {
    @ObservedObject private var logStore = ServerLogStore.shared
    @State private var liveUpdates = true
    @State private var displayedEntries: [ServerLogEntry] = []
    @State private var searchText = ""
    @State private var selectedCategory: ServerLogCategory?

    private var filteredEntries: [ServerLogEntry] {
        displayedEntries.filter { entry in
            let matchesCategory = selectedCategory.map { entry.category == $0 } ?? true
            let needle = searchText.trimmedForLookup.lowercased()
            let matchesSearch: Bool
            if needle.isEmpty {
                matchesSearch = true
            } else {
                matchesSearch = [
                    entry.title,
                    entry.message,
                    entry.body ?? "",
                    entry.category.rawValue,
                    entry.level.rawValue,
                    entry.requestID ?? ""
                ]
                .joined(separator: " ")
                .lowercased()
                .contains(needle)
            }

            return matchesCategory && matchesSearch
        }
    }

    private var exportedLogText: String {
        filteredEntries.map(ServerLogsSection.renderEntry).joined(separator: "\n\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                TextField("Search logs", text: $searchText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(size: 14))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(.ultraThinMaterial)
                    )

                Menu {
                    Button("All Categories") { selectedCategory = nil }
                    ForEach(ServerLogCategory.allCases) { category in
                        Button(category.rawValue.capitalized) {
                            selectedCategory = category
                        }
                    }
                } label: {
                    Label(selectedCategory?.rawValue.capitalized ?? "Category", systemImage: "line.3.horizontal.decrease.circle")
                        .font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(.ultraThinMaterial)
                        )
                }
            }

            HStack(spacing: 12) {
                Toggle("Live", isOn: $liveUpdates)
                    .font(.system(size: 13, weight: .medium))

                Spacer()

                Button("Copy") {
                    UIPasteboard.general.string = exportedLogText
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .disabled(filteredEntries.isEmpty)

                ShareLink(
                    item: exportedLogText,
                    subject: Text("OllamaKit Server Logs"),
                    message: Text("Exported server logs from OllamaKit.")
                ) {
                    Text("Export")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                }
                .disabled(filteredEntries.isEmpty)

                Button("Clear") {
                    ServerLogStore.shared.clear()
                    displayedEntries = []
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.red)
            }

            Text(logStore.persistenceSummary)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            ScrollView {
                VStack(spacing: 10) {
                    if filteredEntries.isEmpty {
                        Text("No server log entries yet.")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 12)
                    } else {
                        ForEach(filteredEntries.suffix(80)) { entry in
                            ServerLogEntryRow(entry: entry)
                        }
                    }
                }
            }
            .frame(minHeight: 240, maxHeight: 360)
        }
        .onAppear {
            displayedEntries = logStore.entries
        }
        .onChange(of: logStore.entries) { _, newValue in
            if liveUpdates {
                displayedEntries = newValue
            }
        }
        .onChange(of: liveUpdates) { _, newValue in
            if newValue {
                displayedEntries = logStore.entries
            }
        }
    }

    private static func renderEntry(_ entry: ServerLogEntry) -> String {
        let timestamp = ISO8601DateFormatter().string(from: entry.timestamp)
        let requestPart = entry.requestID.map { " [\($0)]" } ?? ""
        let metadata = entry.metadata
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        let metadataPart = metadata.isEmpty ? "" : "\n\(metadata)"
        let bodyPart = entry.body.map { "\n\($0)" } ?? ""
        return "[\(timestamp)] [\(entry.level.rawValue.uppercased())] [\(entry.category.rawValue)]\(requestPart) \(entry.title)\n\(entry.message)\(metadataPart)\(bodyPart)"
    }
}

struct ServerLogEntryRow: View {
    let entry: ServerLogEntry

    private var tint: Color {
        switch entry.level {
        case .debug:
            return .secondary
        case .info:
            return .blue
        case .warning:
            return .orange
        case .error:
            return .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title)
                        .font(.system(size: 13, weight: .semibold))
                    Text(entry.timestamp, style: .time)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(entry.category.rawValue)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(tint)
            }

            Text(entry.message)
                .font(.system(size: 12))

            if !entry.metadata.isEmpty {
                Text(entry.metadata
                    .sorted { $0.key < $1.key }
                    .map { "\($0.key)=\($0.value)" }
                    .joined(separator: " "))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if let requestID = entry.requestID {
                Text("request_id=\(requestID)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if let body = entry.body {
                Text(body)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(.ultraThinMaterial)
                    )
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
        )
    }
}

struct PortPickerSheet: View {
    @Binding var port: Int
    @Environment(\.dismiss) private var dismiss
    @State private var tempPort: String = ""

    private var parsedPort: Int? {
        Int(tempPort)
    }

    private var isValidPort: Bool {
        guard let parsedPort else { return false }
        return (1024...65535).contains(parsedPort)
    }
    
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Port", text: $tempPort)
                        .keyboardType(.numberPad)
                        .font(.system(size: 20, weight: .medium, design: .monospaced))
                } header: {
                    Text("Server Port (1024-65535)")
                }
                
                Section {
                    Button("Use Default (11434)") {
                        tempPort = "11434"
                    }
                    .foregroundStyle(Color.accentColor)
                }
            }
            .navigationTitle("Server Port")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if let newPort = parsedPort, isValidPort {
                            port = newPort
                        }
                        dismiss()
                    }
                    .disabled(!isValidPort)
                }
            }
            .onAppear {
                tempPort = String(port)
            }
        }
    }
}

struct APIDocumentationView: View {
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Introduction
                    DocSection(title: "Introduction") {
                        Text("OllamaKit provides an on-device API server with Ollama-style routes and a richer OpenAI-compatible `/v1` surface. The canonical endpoint can be local, local-network, a managed public relay URL, or a custom public URL from your own tunnel or reverse proxy. Only models that are installed, validated, and server-runnable on this device are exposed through the model-list routes.")
                            .font(.system(size: 15))
                    }
                    
                    // Authentication
                    DocSection(title: "Authentication") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("If API key protection is enabled, or if the server is in a public exposure mode, include it in the Authorization header:")
                                .font(.system(size: 15))
                            
                            CodeBlock(code: "Authorization: Bearer YOUR_API_KEY")
                        }
                    }
                    
                    // Endpoints
                    DocSection(title: "Endpoints") {
                        VStack(alignment: .leading, spacing: 16) {
                            EndpointDoc(
                                method: "GET",
                                path: "/api/tags",
                                description: "List validated server-runnable models with capabilities",
                                example: """
                                curl http://localhost:11434/api/tags
                                """
                            )

                            EndpointDoc(
                                method: "POST",
                                path: "/api/show",
                                description: "Show validation and capability detail for one model",
                                example: """
                                curl -X POST http://localhost:11434/api/show \\
                                  -H "Content-Type: application/json" \\
                                  -d '{"name":"MODEL_ID_FROM_/api/tags"}'
                                """
                            )
                            
                            EndpointDoc(
                                method: "POST",
                                path: "/api/generate",
                                description: "Generate a completion",
                                example: """
                                curl -X POST http://localhost:11434/api/generate \\
                                  -H "Content-Type: application/json" \\
                                  -d '{
                                    "model": "MODEL_ID_FROM_/api/tags",
                                    "prompt": "Why is the sky blue?"
                                  }'
                                """
                            )
                            
                            EndpointDoc(
                                method: "GET",
                                path: "/v1/models",
                                description: "OpenAI-compatible validated model list with capabilities",
                                example: """
                                curl http://localhost:11434/v1/models
                                """
                            )

                            EndpointDoc(
                                method: "POST",
                                path: "/v1/chat/completions",
                                description: "OpenAI-compatible chat completions with capability checks",
                                example: """
                                curl -X POST http://localhost:11434/v1/chat/completions \\
                                  -H "Content-Type: application/json" \\
                                  -d '{
                                    "model": "MODEL_ID_FROM_/v1/models",
                                    "messages": [
                                      {"role": "user", "content": "Hello!"}
                                    ]
                                  }'
                                """
                            )

                            EndpointDoc(
                                method: "POST",
                                path: "/v1/responses",
                                description: "OpenAI-style rich responses for capability-aware requests",
                                example: """
                                curl -X POST http://localhost:11434/v1/responses \\
                                  -H "Content-Type: application/json" \\
                                  -d '{
                                    "model": "MODEL_ID_FROM_/v1/models",
                                    "input": "Summarize the latest request log."
                                  }'
                                """
                            )

                            EndpointDoc(
                                method: "POST",
                                path: "/api/chat",
                                description: "Chat completion with message history",
                                example: """
                                curl -X POST http://localhost:11434/api/chat \\
                                  -H "Content-Type: application/json" \\
                                  -d '{
                                    "model": "MODEL_ID_FROM_/api/tags",
                                    "messages": [
                                      {"role": "user", "content": "Hello!"}
                                    ]
                                  }'
                                """
                            )
                        }
                    }
                    
                    // Parameters
                    DocSection(title: "Generation Parameters") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Use the exact model identifier returned by `/api/tags` or `/v1/models`. Capability-aware routes reject unsupported tool, reasoning, embedding, image, audio, or video features for the selected model instead of silently ignoring them.")
                                .font(.system(size: 14))
                                .foregroundStyle(.secondary)

                            ParameterRow(name: "temperature", type: "float", default: "0.7", description: "Sampling temperature")
                            ParameterRow(name: "top_p", type: "float", default: "0.9", description: "Nucleus sampling")
                            ParameterRow(name: "top_k", type: "int", default: "40", description: "Top-k sampling")
                            ParameterRow(name: "repeat_penalty", type: "float", default: "1.1", description: "Repetition penalty")
                            ParameterRow(name: "max_tokens", type: "int", default: "-1", description: "Max tokens to generate")
                        }
                    }
                }
                .padding(20)
            }
            .navigationTitle("API Documentation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

struct DocSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 22, weight: .bold))
            
            content
        }
    }
}

struct CodeBlock: View {
    let code: String
    
    var body: some View {
        Text(code)
            .font(.system(size: 13, design: .monospaced))
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.black.opacity(0.3))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.white.opacity(0.1), lineWidth: 0.5)
            )
    }
}

struct EndpointDoc: View {
    let method: String
    let path: String
    let description: String
    let example: String
    
    var methodColor: Color {
        switch method {
        case "GET": return .blue
        case "POST": return .green
        case "DELETE": return .red
        default: return .gray
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(method)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(methodColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(methodColor.opacity(0.2))
                    )
                
                Text(path)
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
            }
            
            Text(description)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
            
            CodeBlock(code: example)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
        )
    }
}

struct ParameterRow: View {
    let name: String
    let type: String
    let defaultValue: String
    let description: String

    init(name: String, type: String, default defaultValue: String, description: String) {
        self.name = name
        self.type = type
        self.defaultValue = defaultValue
        self.description = description
    }
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                
                HStack(spacing: 4) {
                    Text(type)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.accentColor)
                    
                    Text("default: \(defaultValue)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 140, alignment: .leading)
            
            Text(description)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
        }
    }
}

@MainActor
enum PublicURLHealthState {
    case hidden
    case notConfigured
    case checking
    case healthy
    case unreachable(String)
    case invalid

    var title: String {
        switch self {
        case .hidden:
            return "Not Applicable"
        case .notConfigured:
            return "Not Configured"
        case .checking:
            return "Checking"
        case .healthy:
            return "Reachable"
        case .unreachable:
            return "Unreachable"
        case .invalid:
            return "Invalid URL"
        }
    }

    var detail: String {
        switch self {
        case .hidden:
            return "Public URL mode is not active."
        case .notConfigured:
            return "Configure either a managed relay service URL or a custom public URL."
        case .checking:
            return "Checking the configured public endpoint or relay session."
        case .healthy:
            return "The configured public endpoint is healthy."
        case .unreachable(let detail):
            return detail
        case .invalid:
            return "Use a valid http:// or https:// URL."
        }
    }

    var tint: Color {
        switch self {
        case .healthy:
            return .green
        case .checking:
            return .blue
        case .hidden, .notConfigured:
            return .secondary
        case .unreachable, .invalid:
            return .orange
        }
    }
}

@MainActor
class ServerViewModel: ObservableObject {
    @Published var isRunning = false
    @Published var networkURL = ""
    @Published var publicHealthState: PublicURLHealthState = .hidden

    var publicHealthTitle: String {
        publicHealthState.title
    }

    var publicHealthDetail: String {
        publicHealthState.detail
    }

    var publicHealthColor: Color {
        publicHealthState.tint
    }
    
    func refreshStatus() {
        Task {
            isRunning = ServerManager.shared.isServerRunning
            updateNetworkURL()
            await refreshPublicHealth()
        }
    }
    
    func startServer() async {
        await ServerManager.shared.startServer()
        isRunning = ServerManager.shared.isServerRunning
        updateNetworkURL()
        await refreshPublicHealth()
        if isRunning {
            if AppSettings.shared.serverEnabled {
                BackgroundTaskManager.shared.scheduleBackgroundTask()
            }
            HapticManager.notification(.success)
        }
    }
    
    func stopServer() async {
        await ServerManager.shared.stopServer()
        BackgroundTaskManager.shared.cancelScheduledBackgroundTask()
        isRunning = ServerManager.shared.isServerRunning
        await refreshPublicHealth()
        HapticManager.impact(.medium)
    }

    func restartServerIfNeeded() async {
        let wasRunning = ServerManager.shared.isServerRunning
        await ServerManager.shared.restartServerIfRunning()
        isRunning = ServerManager.shared.isServerRunning
        updateNetworkURL()
        await refreshPublicHealth()
        if wasRunning && isRunning {
            HapticManager.selectionChanged()
        }
    }

    func refreshPublicHealth() async {
        guard AppSettings.shared.serverExposureMode.isPublic else {
            publicHealthState = .hidden
            return
        }

        guard let urlString = AppSettings.shared.normalizedPublicBaseURL else {
            publicHealthState = AppSettings.shared.publicBaseURL.trimmedForLookup.isEmpty ? .notConfigured : .invalid
            return
        }

        guard isRunning else {
            publicHealthState = .unreachable("The on-device server is not running.")
            return
        }

        guard let url = URL(string: urlString) else {
            publicHealthState = .invalid
            return
        }

        publicHealthState = .checking

        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        if AppSettings.shared.isAPIKeyRequiredForCurrentExposure {
            request.setValue("Bearer \(AppSettings.shared.apiKey)", forHTTPHeaderField: "Authorization")
        }

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, (200...399).contains(httpResponse.statusCode) {
                publicHealthState = .healthy
                ServerLogStore.shared.record(
                    ServerLogEntry(
                        level: .info,
                        category: .health,
                        title: "Custom Public URL Healthy",
                        message: "The configured custom public endpoint responded successfully.",
                        metadata: [
                            "url": urlString,
                            "status": String(httpResponse.statusCode)
                        ]
                    )
                )
            } else if let httpResponse = response as? HTTPURLResponse {
                publicHealthState = .unreachable("The custom public endpoint returned HTTP \(httpResponse.statusCode).")
            } else {
                publicHealthState = .unreachable("The custom public endpoint returned an unexpected response.")
            }
        } catch {
            publicHealthState = .unreachable(error.localizedDescription)
            ServerLogStore.shared.record(
                ServerLogEntry(
                    level: .warning,
                    category: .health,
                    title: "Custom Public URL Unreachable",
                    message: error.localizedDescription,
                    metadata: ["url": urlString]
                )
            )
        }
    }
    
    private func updateNetworkURL() {
        // Get device IP address
        var address = "Unknown"
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        
        if getifaddrs(&ifaddr) == 0 {
            var ptr = ifaddr
            while let current = ptr {
                let flags = Int32(current.pointee.ifa_flags)

                guard let interfaceAddress = current.pointee.ifa_addr else {
                    ptr = current.pointee.ifa_next
                    continue
                }

                let addr = interfaceAddress.pointee
                
                if (flags & (IFF_UP|IFF_RUNNING|IFF_LOOPBACK)) == (IFF_UP|IFF_RUNNING) {
                    if addr.sa_family == UInt8(AF_INET) {
                        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        if getnameinfo(interfaceAddress, socklen_t(addr.sa_len),
                                      &hostname, socklen_t(hostname.count),
                                      nil, socklen_t(0), NI_NUMERICHOST) == 0 {
                            let ip = String(cString: hostname)
                            if ip != "127.0.0.1" {
                                address = ip
                                break
                            }
                        }
                    }
                }
                ptr = current.pointee.ifa_next
            }
            freeifaddrs(ifaddr)
        }
        
        networkURL = "http://\(address):\(AppSettings.shared.serverPort)"
    }
}

private func generateQRCode(from string: String, size: CGFloat = 200) -> UIImage? {
    let context = CIContext()
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(string.utf8)
    filter.correctionLevel = "M"
    guard let outputImage = filter.outputImage else { return nil }
    let transform = CGAffineTransform(scaleX: size/outputImage.extent.width, y: size/outputImage.extent.height)
    let scaledImage = outputImage.transformed(by: transform)
    guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) else { return nil }
    return UIImage(cgImage: cgImage)
}

#Preview {
    ServerView()
}
