import AVFoundation
import Foundation
import SwiftData
import UniformTypeIdentifiers
#if canImport(PDFKit)
import PDFKit
#endif

enum ScanMode: String, CaseIterable, Sendable {
    case full
    case incremental
}

struct LocalFilesScanStatus: Equatable, Sendable {
    let sourceID: UUID
    var isScanning: Bool
    var scannedCount: Int
    var indexedCount: Int
    var statusText: String
    var lastError: String?
    var requiresReconnect: Bool

    static func idle(sourceID: UUID) -> LocalFilesScanStatus {
        LocalFilesScanStatus(
            sourceID: sourceID,
            isScanning: false,
            scannedCount: 0,
            indexedCount: 0,
            statusText: "Ready",
            lastError: nil,
            requiresReconnect: false
        )
    }
}

@MainActor
final class LocalFilesScanner: ObservableObject {
    static let shared = LocalFilesScanner()

    @Published private(set) var statuses: [UUID: LocalFilesScanStatus] = [:]

    private var container: ModelContainer?
    private var tasks: [UUID: Task<Void, Never>] = [:]

    private init() {}

    func configure(container: ModelContainer) {
        self.container = container
    }

    func status(for sourceID: UUID) -> LocalFilesScanStatus {
        statuses[sourceID] ?? .idle(sourceID: sourceID)
    }

    func scan(source: FileSource, mode: ScanMode) {
        guard let container else {
            statuses[source.id] = LocalFilesScanStatus(
                sourceID: source.id,
                isScanning: false,
                scannedCount: 0,
                indexedCount: 0,
                statusText: "Unavailable",
                lastError: "The local files scanner is not configured yet.",
                requiresReconnect: false
            )
            return
        }

        cancelScan(sourceID: source.id, message: nil)

        let snapshot = FileSourceSnapshot(
            id: source.id,
            name: source.name,
            bookmarkData: source.bookmarkData
        )

        statuses[source.id] = LocalFilesScanStatus(
            sourceID: source.id,
            isScanning: true,
            scannedCount: 0,
            indexedCount: 0,
            statusText: mode == .full ? "Preparing full scan" : "Preparing incremental scan",
            lastError: nil,
            requiresReconnect: false
        )

        let task = Task.detached(priority: .userInitiated) {
            do {
                let result = try await LocalFilesScanner.performScan(
                    snapshot: snapshot,
                    mode: mode,
                    container: container
                )
                await LocalFilesScanner.finish(
                    sourceID: snapshot.id,
                    scannedCount: result.scannedCount,
                    indexedCount: result.indexedCount,
                    statusText: result.statusText,
                    lastError: result.lastError,
                    requiresReconnect: result.requiresReconnect
                )
            } catch is CancellationError {
                await LocalFilesScanner.finish(
                    sourceID: snapshot.id,
                    scannedCount: 0,
                    indexedCount: 0,
                    statusText: "Cancelled",
                    lastError: nil,
                    requiresReconnect: false
                )
            } catch {
                await LocalFilesScanner.finish(
                    sourceID: snapshot.id,
                    scannedCount: 0,
                    indexedCount: 0,
                    statusText: "Scan failed",
                    lastError: error.localizedDescription,
                    requiresReconnect: error.isLocalFilesReconnectError
                )
            }
        }

        tasks[source.id] = task
    }

    func cancelScan(sourceID: UUID) {
        cancelScan(sourceID: sourceID, message: "Cancelled")
    }

    private func cancelScan(sourceID: UUID, message: String?) {
        tasks[sourceID]?.cancel()
        tasks[sourceID] = nil

        guard let message else { return }
        var status = statuses[sourceID] ?? .idle(sourceID: sourceID)
        status.isScanning = false
        status.statusText = message
        statuses[sourceID] = status
    }

    nonisolated private static func updateProgress(
        sourceID: UUID,
        scannedCount: Int,
        indexedCount: Int,
        statusText: String
    ) async {
        await MainActor.run {
            var status = LocalFilesScanner.shared.status(for: sourceID)
            status.isScanning = true
            status.scannedCount = scannedCount
            status.indexedCount = indexedCount
            status.statusText = statusText
            status.lastError = nil
            status.requiresReconnect = false
            LocalFilesScanner.shared.statuses[sourceID] = status
        }
    }

    nonisolated private static func finish(
        sourceID: UUID,
        scannedCount: Int,
        indexedCount: Int,
        statusText: String,
        lastError: String?,
        requiresReconnect: Bool
    ) async {
        await MainActor.run {
            var status = LocalFilesScanner.shared.status(for: sourceID)
            status.isScanning = false
            status.scannedCount = scannedCount
            status.indexedCount = indexedCount
            status.statusText = statusText
            status.lastError = lastError
            status.requiresReconnect = requiresReconnect
            LocalFilesScanner.shared.statuses[sourceID] = status
            LocalFilesScanner.shared.tasks[sourceID] = nil
        }
    }

    nonisolated private static func performScan(
        snapshot: FileSourceSnapshot,
        mode: ScanMode,
        container: ModelContainer
    ) async throws -> LocalFilesScanResult {
        let context = ModelContext(container)
        let resolvedRoot = try resolveBookmarkedRoot(for: snapshot)
        let rootURL = resolvedRoot.url
        let sourceID = snapshot.id
        var scannedCount = 0
        var indexedCount = 0
        let bookmarkNeedsReconnect = resolvedRoot.needsReconnect
        var bookmarkWarning = resolvedRoot.warning
        let saveBatchSize = 200

        guard rootURL.startAccessingSecurityScopedResource() else {
            throw LocalFilesScanError.accessDenied(snapshot.name)
        }
        defer {
            rootURL.stopAccessingSecurityScopedResource()
        }

        try updateSourceBookmark(
            sourceID: sourceID,
            refreshedBookmarkData: resolvedRoot.refreshedBookmarkData,
            context: context
        )

        let fileManager = FileManager.default
        let sourceDescriptor = FetchDescriptor<FileSource>(
            predicate: #Predicate<FileSource> { source in
                source.id == sourceID
            }
        )

        guard let storedSource = try context.fetch(sourceDescriptor).first else {
            throw LocalFilesScanError.sourceMissing
        }

        let existingDescriptor = FetchDescriptor<IndexedFile>(
            predicate: #Predicate<IndexedFile> { item in
                item.sourceID == sourceID
            }
        )
        let existingFiles = try context.fetch(existingDescriptor)
        var existingByPath = Dictionary(uniqueKeysWithValues: existingFiles.map { ($0.urlPath, $0) })

        if mode == .full {
            for file in existingFiles {
                context.delete(file)
            }
            existingByPath.removeAll(keepingCapacity: true)
            try context.save()
        }

        let requestedKeys: [URLResourceKey] = [
            .isRegularFileKey,
            .isDirectoryKey,
            .isHiddenKey,
            .fileSizeKey,
            .contentModificationDateKey,
            .typeIdentifierKey,
            .localizedNameKey
        ]

        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: requestedKeys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else {
            throw LocalFilesScanError.enumerationFailed
        }

        while let nextObject = enumerator.nextObject() {
            try Task.checkCancellation()
            guard let fileURL = nextObject as? URL else { continue }

            let values = try fileURL.resourceValues(forKeys: Set(requestedKeys))
            guard values.isRegularFile == true else { continue }

            scannedCount += 1
            let relativePath = relativePath(for: fileURL, rootedAt: rootURL)
            let record = try await buildRecord(
                for: fileURL,
                relativePath: relativePath,
                sourceID: sourceID,
                resourceValues: values
            )

            switch mode {
            case .full:
                context.insert(record.makeIndexedFile())
            case .incremental:
                if let existing = existingByPath.removeValue(forKey: relativePath) {
                    existing.fileName = record.fileName
                    existing.fileExtension = record.fileExtension
                    existing.fileType = record.fileType
                    existing.fileSize = record.fileSize
                    existing.lastModified = record.lastModified
                    existing.extraMetadata = record.extraMetadata
                } else {
                    context.insert(record.makeIndexedFile())
                }
            }

            indexedCount += 1

            if indexedCount % saveBatchSize == 0 {
                try context.save()
                await updateProgress(
                    sourceID: sourceID,
                    scannedCount: scannedCount,
                    indexedCount: indexedCount,
                    statusText: "Indexed \(indexedCount) files from \(snapshot.name)"
                )
            } else if scannedCount % 25 == 0 {
                await updateProgress(
                    sourceID: sourceID,
                    scannedCount: scannedCount,
                    indexedCount: indexedCount,
                    statusText: "Scanning \(snapshot.name)"
                )
            }
        }

        if mode == .incremental {
            for (_, file) in existingByPath {
                context.delete(file)
            }
        }

        storedSource.lastScanAt = .now
        try context.save()

        if bookmarkWarning == nil, bookmarkNeedsReconnect {
            bookmarkWarning = "Folder access changed. Pick the folder again to refresh the bookmark."
        }

        return LocalFilesScanResult(
            scannedCount: scannedCount,
            indexedCount: indexedCount,
            statusText: indexedCount == 0 ? "Scan complete. No files found." : "Scan complete. Indexed \(indexedCount) files.",
            lastError: bookmarkWarning,
            requiresReconnect: bookmarkNeedsReconnect
        )
    }

    nonisolated private static func resolveBookmarkedRoot(for snapshot: FileSourceSnapshot) throws -> ResolvedSourceRoot {
        var bookmarkIsStale = false
        let rootURL: URL
        do {
            rootURL = try URL(
                resolvingBookmarkData: snapshot.bookmarkData,
                options: [.withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &bookmarkIsStale
            )
        } catch {
            throw LocalFilesScanError.accessDenied(snapshot.name)
        }

        guard bookmarkIsStale else {
            return ResolvedSourceRoot(
                url: rootURL,
                refreshedBookmarkData: nil,
                needsReconnect: false,
                warning: nil
            )
        }

        do {
            let refreshed = try rootURL.bookmarkData(
                options: [.minimalBookmark],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            return ResolvedSourceRoot(
                url: rootURL,
                refreshedBookmarkData: refreshed,
                needsReconnect: false,
                warning: nil
            )
        } catch {
            return ResolvedSourceRoot(
                url: rootURL,
                refreshedBookmarkData: nil,
                needsReconnect: true,
                warning: "Folder access changed. Pick the folder again to refresh the bookmark."
            )
        }
    }

    nonisolated private static func updateSourceBookmark(
        sourceID: UUID,
        refreshedBookmarkData: Data?,
        context: ModelContext
    ) throws {
        guard let refreshedBookmarkData else { return }
        let descriptor = FetchDescriptor<FileSource>(
            predicate: #Predicate<FileSource> { source in
                source.id == sourceID
            }
        )

        guard let storedSource = try context.fetch(descriptor).first else {
            throw LocalFilesScanError.sourceMissing
        }

        storedSource.bookmarkData = refreshedBookmarkData
        try context.save()
    }

    nonisolated private static func buildRecord(
        for fileURL: URL,
        relativePath: String,
        sourceID: UUID,
        resourceValues: URLResourceValues
    ) async throws -> ScannedFileRecord {
        let typeIdentifier = resourceValues.typeIdentifier
        let detectedType = classify(typeIdentifier: typeIdentifier, pathExtension: fileURL.pathExtension)

        var metadata: [String: Any] = [:]

        if detectedType == .audio || detectedType == .video {
            let mediaProperties = await mediaMetadata(for: fileURL)
            metadata.merge(mediaProperties, uniquingKeysWith: { _, latest in latest })
        }

        #if canImport(PDFKit)
        if (typeIdentifier.flatMap(UTType.init)?.conforms(to: .pdf) ?? false) || fileURL.pathExtension.lowercased() == "pdf" {
            if let document = PDFDocument(url: fileURL) {
                metadata["pageCount"] = document.pageCount
            }
        }
        #endif

        let extraMetadata = metadata.isEmpty ? nil : try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
        let fileName = resourceValues.localizedName ?? fileURL.lastPathComponent
        let fileExtension = fileURL.pathExtension.isEmpty ? nil : fileURL.pathExtension.lowercased()

        return ScannedFileRecord(
            sourceID: sourceID,
            urlPath: relativePath,
            fileName: fileName,
            fileExtension: fileExtension,
            fileType: detectedType.rawValue,
            fileSize: resourceValues.fileSize.map(Int64.init),
            lastModified: resourceValues.contentModificationDate,
            extraMetadata: extraMetadata
        )
    }

    nonisolated private static func classify(typeIdentifier: String?, pathExtension: String) -> LocalIndexedFileType {
        if let typeIdentifier, let type = UTType(typeIdentifier) {
            if type.conforms(to: .audio) {
                return .audio
            }
            if type.conforms(to: .image) {
                return .image
            }
            if type.conforms(to: .movie) || type.conforms(to: .video) {
                return .video
            }
            if type.conforms(to: .text)
                || type.conforms(to: .plainText)
                || type.conforms(to: .utf8PlainText)
                || type.conforms(to: .json)
                || type.conforms(to: .xml)
                || type.conforms(to: .commaSeparatedText)
                || type.conforms(to: .sourceCode) {
                return .text
            }
        }

        if let type = UTType(filenameExtension: pathExtension.lowercased()) {
            if type.conforms(to: .audio) {
                return .audio
            }
            if type.conforms(to: .image) {
                return .image
            }
            if type.conforms(to: .movie) || type.conforms(to: .video) {
                return .video
            }
            if type.conforms(to: .text)
                || type.conforms(to: .plainText)
                || type.conforms(to: .utf8PlainText)
                || type.conforms(to: .json)
                || type.conforms(to: .xml)
                || type.conforms(to: .commaSeparatedText)
                || type.conforms(to: .sourceCode) {
                return .text
            }
        }

        return .other
    }

    nonisolated private static func mediaMetadata(for fileURL: URL) async -> [String: Any] {
        let asset = AVURLAsset(url: fileURL)
        var metadata: [String: Any] = [:]

        if let durationTime = try? await asset.load(.duration) {
            let duration = CMTimeGetSeconds(durationTime)
            if duration.isFinite, duration > 0 {
                metadata["durationSeconds"] = duration
            }
        }

        if let commonMetadata = try? await asset.load(.commonMetadata) {
            if let title = await firstMetadataString(in: commonMetadata, identifier: .commonIdentifierTitle) {
                metadata["title"] = title
            }
            if let artist = await firstMetadataString(in: commonMetadata, identifier: .commonIdentifierArtist) {
                metadata["artist"] = artist
            }
            if let album = await firstMetadataString(in: commonMetadata, identifier: .commonIdentifierAlbumName) {
                metadata["album"] = album
            }
        }

        return metadata
    }

    nonisolated private static func firstMetadataString(
        in items: [AVMetadataItem],
        identifier: AVMetadataIdentifier
    ) async -> String? {
        let matchingItems = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: identifier)
        for item in matchingItems {
            if let value = try? await item.load(.stringValue),
               !value.isEmpty
            {
                return value
            }
        }

        return nil
    }

    nonisolated private static func relativePath(for fileURL: URL, rootedAt rootURL: URL) -> String {
        let filePath = fileURL.standardizedFileURL.path
        var rootPath = rootURL.standardizedFileURL.path
        if !rootPath.hasSuffix("/") {
            rootPath.append("/")
        }

        guard filePath.hasPrefix(rootPath) else {
            return fileURL.lastPathComponent
        }

        return String(filePath.dropFirst(rootPath.count))
    }
}

private struct FileSourceSnapshot: Sendable {
    let id: UUID
    let name: String
    let bookmarkData: Data
}

private struct ResolvedSourceRoot: Sendable {
    let url: URL
    let refreshedBookmarkData: Data?
    let needsReconnect: Bool
    let warning: String?
}

private struct LocalFilesScanResult: Sendable {
    let scannedCount: Int
    let indexedCount: Int
    let statusText: String
    let lastError: String?
    let requiresReconnect: Bool
}

private struct ScannedFileRecord: Sendable {
    let sourceID: UUID
    let urlPath: String
    let fileName: String
    let fileExtension: String?
    let fileType: String
    let fileSize: Int64?
    let lastModified: Date?
    let extraMetadata: Data?

    func makeIndexedFile() -> IndexedFile {
        IndexedFile(
            sourceID: sourceID,
            urlPath: urlPath,
            fileName: fileName,
            fileExtension: fileExtension,
            fileType: fileType,
            fileSize: fileSize,
            lastModified: lastModified,
            extraMetadata: extraMetadata
        )
    }
}

private enum LocalFilesScanError: LocalizedError {
    case accessDenied(String)
    case enumerationFailed
    case sourceMissing

    var errorDescription: String? {
        switch self {
        case .accessDenied(let sourceName):
            return "Could not access \(sourceName). Pick the folder again in Local Files settings."
        case .enumerationFailed:
            return "The selected folder could not be scanned."
        case .sourceMissing:
            return "The selected file source no longer exists."
        }
    }
}

private extension Error {
    var isLocalFilesReconnectError: Bool {
        if let scanError = self as? LocalFilesScanError {
            switch scanError {
            case .accessDenied:
                return true
            case .enumerationFailed, .sourceMissing:
                return false
            }
        }

        return false
    }
}
