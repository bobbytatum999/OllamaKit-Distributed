import Foundation
import SwiftData

@MainActor
final class LocalFilesTool {
    private let context: ModelContext

    init(container: ModelContainer) {
        self.context = ModelContext(container)
    }

    func listFiles(filter: LocalFilesFilter = LocalFilesFilter()) -> [IndexedFileSummary] {
        let descriptor = FetchDescriptor<IndexedFile>()

        guard let indexedFiles = try? context.fetch(descriptor) else {
            return []
        }

        let normalizedSearchText = filter.searchText.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase

        let filtered = indexedFiles
            .filter { file in
                if let sourceID = filter.sourceID, file.sourceID != sourceID {
                    return false
                }

                if !filter.fileTypes.isEmpty, !filter.fileTypes.contains(file.fileType) {
                    return false
                }

                if !normalizedSearchText.isEmpty {
                    let haystack = "\(file.fileName) \(file.urlPath)".localizedLowercase
                    if !haystack.contains(normalizedSearchText) {
                        return false
                    }
                }

                return true
            }
            .sorted { lhs, rhs in
                if lhs.lastModified != rhs.lastModified {
                    return (lhs.lastModified ?? .distantPast) > (rhs.lastModified ?? .distantPast)
                }
                return lhs.fileName.localizedCaseInsensitiveCompare(rhs.fileName) == .orderedAscending
            }
            .prefix(max(filter.limit, 0))

        return filtered.map { file in
            IndexedFileSummary(
                id: file.id,
                sourceID: file.sourceID,
                urlPath: file.urlPath,
                fileName: file.fileName,
                fileExtension: file.fileExtension,
                fileType: file.fileType,
                fileSize: file.fileSize,
                lastModified: file.lastModified
            )
        }
    }

    func getFileMetadata(id: UUID) -> IndexedFile? {
        let descriptor = FetchDescriptor<IndexedFile>(
            predicate: #Predicate<IndexedFile> { file in
                file.id == id
            }
        )
        return try? context.fetch(descriptor).first
    }

    func readFilePreview(id: UUID, maxBytes: Int = 4096) -> String? {
        guard maxBytes > 0,
              let indexedFile = getFileMetadata(id: id),
              indexedFile.fileType == LocalIndexedFileType.text.rawValue
        else {
            return nil
        }
        let sourceID = indexedFile.sourceID

        let sourceDescriptor = FetchDescriptor<FileSource>(
            predicate: #Predicate<FileSource> { source in
                source.id == sourceID
            }
        )

        guard let source = try? context.fetch(sourceDescriptor).first else {
            return nil
        }

        do {
            var bookmarkIsStale = false
            let rootURL = try URL(
                resolvingBookmarkData: source.bookmarkData,
                options: [.withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &bookmarkIsStale
            )

            guard rootURL.startAccessingSecurityScopedResource() else {
                return nil
            }
            defer {
                rootURL.stopAccessingSecurityScopedResource()
            }

            let fileURL = rootURL.appendingPathComponent(indexedFile.urlPath, isDirectory: false)
            let handle = try FileHandle(forReadingFrom: fileURL)
            defer {
                handle.closeFile()
            }

            let data = try handle.read(upToCount: maxBytes)
            guard let data, !data.isEmpty else {
                return nil
            }

            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}
