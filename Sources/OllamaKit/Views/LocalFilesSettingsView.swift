import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import UIKit

@MainActor
struct LocalFilesSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var sources: [FileSource]

    @StateObject private var scanner = LocalFilesScanner.shared

    @State private var pickerAction: FolderPickerAction?
    @State private var alertMessage: String?
    @State private var confirmingRemovalSourceID: UUID?

    private var sortedSources: [FileSource] {
        sources.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt > rhs.createdAt
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Local Files Index")
                    .font(.system(size: 16, weight: .medium))
                Text("Grant OllamaKit access to a folder and every file under it. Access is limited to folders you explicitly pick in the Files app.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 12)

            Divider()

            Button {
                pickerAction = .add
            } label: {
                HStack {
                    Image(systemName: "folder.badge.plus")
                    Text("Add Folder")
                    Spacer()
                }
                .font(.system(size: 16, weight: .medium))
            }
            .padding(.vertical, 12)

            if !sortedSources.isEmpty {
                Divider()

                VStack(spacing: 0) {
                    ForEach(Array(sortedSources.enumerated()), id: \.element.id) { index, source in
                        LocalFilesSourceRow(
                            source: source,
                            status: scanner.status(for: source.id),
                            onRescan: {
                                scanner.scan(source: source, mode: .incremental)
                            },
                            onFullRescan: {
                                scanner.scan(source: source, mode: .full)
                            },
                            onCancel: {
                                scanner.cancelScan(sourceID: source.id)
                            },
                            onReconnect: {
                                pickerAction = .reconnect(source.id)
                            },
                            onRemove: {
                                confirmingRemovalSourceID = source.id
                            }
                        )

                        if index < sortedSources.count - 1 {
                            Divider()
                        }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("No folders added yet.")
                        .font(.system(size: 14, weight: .medium))
                    Text("Add a folder from Files to let local models inspect metadata and text previews from that folder.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 12)
            }
        }
        .sheet(item: $pickerAction) { action in
            LocalFilesFolderPicker(
                title: action.sheetTitle,
                onPick: { url in
                    handlePickedFolder(url, action: action)
                },
                onCancel: {
                    pickerAction = nil
                }
            )
        }
        .alert(
            "Local Files",
            isPresented: Binding(
                get: { alertMessage != nil },
                set: { if !$0 { alertMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage ?? "")
        }
        .confirmationDialog(
            "Remove folder access?",
            isPresented: Binding(
                get: { confirmingRemovalSourceID != nil },
                set: { if !$0 { confirmingRemovalSourceID = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove Access", role: .destructive) {
                guard let sourceID = confirmingRemovalSourceID else { return }
                removeSource(withID: sourceID)
                confirmingRemovalSourceID = nil
            }
            Button("Cancel", role: .cancel) {
                confirmingRemovalSourceID = nil
            }
        } message: {
            Text("This removes the stored folder bookmark and deletes the indexed file metadata for that folder.")
        }
    }

    private func handlePickedFolder(_ url: URL, action: FolderPickerAction) {
        pickerAction = nil

        do {
            let bookmarkData = try url.bookmarkData(
                options: [.minimalBookmark],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )

            switch action {
            case .add:
                let source = FileSource(
                    name: friendlyName(for: url),
                    bookmarkData: bookmarkData
                )
                modelContext.insert(source)
                try modelContext.save()
                scanner.scan(source: source, mode: .full)

            case .reconnect(let sourceID):
                guard let source = sources.first(where: { $0.id == sourceID }) else {
                    throw LocalFilesSettingsError.sourceMissing
                }

                source.name = friendlyName(for: url)
                source.bookmarkData = bookmarkData
                try modelContext.save()
                scanner.scan(source: source, mode: .full)
            }
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    private func removeSource(withID sourceID: UUID) {
        do {
            scanner.cancelScan(sourceID: sourceID)

            let indexedFilesDescriptor = FetchDescriptor<IndexedFile>(
                predicate: #Predicate<IndexedFile> { file in
                    file.sourceID == sourceID
                }
            )
            let indexedFiles = try modelContext.fetch(indexedFilesDescriptor)
            indexedFiles.forEach(modelContext.delete)

            if let source = sources.first(where: { $0.id == sourceID }) {
                modelContext.delete(source)
            }

            try modelContext.save()
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    private func friendlyName(for url: URL) -> String {
        let defaultName = url.lastPathComponent.isEmpty ? "Folder" : url.lastPathComponent
        guard let values = try? url.resourceValues(forKeys: [.localizedNameKey, .volumeNameKey]) else {
            return defaultName
        }

        let localized = values.localizedName ?? defaultName
        guard let volumeName = values.volumeName, !volumeName.isEmpty, volumeName != localized else {
            return localized
        }

        return "\(localized) (\(volumeName))"
    }
}

private struct LocalFilesSourceRow: View {
    let source: FileSource
    let status: LocalFilesScanStatus
    let onRescan: () -> Void
    let onFullRescan: () -> Void
    let onCancel: () -> Void
    let onReconnect: () -> Void
    let onRemove: () -> Void

    private var lastScanText: String {
        guard let lastScanAt = source.lastScanAt else {
            return "Not scanned yet"
        }

        return "Last scan: \(lastScanAt.formatted(date: .abbreviated, time: .shortened))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(source.name)
                    .font(.system(size: 16, weight: .medium))
                Text(lastScanText)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                if status.isScanning {
                    ProgressView()
                        .controlSize(.small)
                }

                Text(status.statusText)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(status.requiresReconnect ? .orange : .secondary)

                if status.isScanning || status.scannedCount > 0 {
                    Text("• \(status.indexedCount) indexed")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }

            if let lastError = status.lastError {
                Text(lastError)
                    .font(.system(size: 12))
                    .foregroundStyle(status.requiresReconnect ? .orange : .red)
            }

            HStack(spacing: 10) {
                if status.isScanning {
                    Button("Cancel", action: onCancel)
                        .buttonStyle(.bordered)
                } else {
                    Button("Rescan", action: onRescan)
                        .buttonStyle(.bordered)

                    Button("Full Rebuild", action: onFullRescan)
                        .buttonStyle(.bordered)
                }

                if status.requiresReconnect {
                    Button("Re-pick Folder", action: onReconnect)
                        .buttonStyle(.borderedProminent)
                }

                Spacer()

                Button("Remove", role: .destructive, action: onRemove)
                    .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 12)
    }
}

private enum FolderPickerAction: Identifiable {
    case add
    case reconnect(UUID)

    var id: String {
        switch self {
        case .add:
            return "add"
        case .reconnect(let sourceID):
            return "reconnect-\(sourceID.uuidString)"
        }
    }

    var sheetTitle: String {
        switch self {
        case .add:
            return "Choose Folder"
        case .reconnect:
            return "Choose Folder Again"
        }
    }
}

private enum LocalFilesSettingsError: LocalizedError {
    case sourceMissing

    var errorDescription: String? {
        switch self {
        case .sourceMissing:
            return "That folder source no longer exists."
        }
    }
}

private struct LocalFilesFolderPicker: UIViewControllerRepresentable {
    let title: String
    let onPick: (URL) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        picker.title = title
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onPick: (URL) -> Void
        private let onCancel: () -> Void

        init(onPick: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick
            self.onCancel = onCancel
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else {
                onCancel()
                return
            }

            onPick(url)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onCancel()
        }
    }
}
