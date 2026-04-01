import Foundation
import SwiftData

enum LocalIndexedFileType: String, CaseIterable, Codable, Sendable {
    case audio
    case text
    case image
    case video
    case other
}

@Model
final class FileSource {
    @Attribute(.unique) var id: UUID
    var name: String
    @Attribute(.externalStorage) var bookmarkData: Data
    var createdAt: Date
    var lastScanAt: Date?

    init(
        id: UUID = UUID(),
        name: String,
        bookmarkData: Data,
        createdAt: Date = .now,
        lastScanAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.bookmarkData = bookmarkData
        self.createdAt = createdAt
        self.lastScanAt = lastScanAt
    }
}

@Model
final class IndexedFile {
    @Attribute(.unique) var id: UUID
    var sourceID: UUID
    var urlPath: String
    var fileName: String
    var fileExtension: String?
    var fileType: String
    var fileSize: Int64?
    var lastModified: Date?
    var createdAt: Date
    @Attribute(.externalStorage) var extraMetadata: Data?

    init(
        id: UUID = UUID(),
        sourceID: UUID,
        urlPath: String,
        fileName: String,
        fileExtension: String? = nil,
        fileType: String,
        fileSize: Int64? = nil,
        lastModified: Date? = nil,
        createdAt: Date = .now,
        extraMetadata: Data? = nil
    ) {
        self.id = id
        self.sourceID = sourceID
        self.urlPath = urlPath
        self.fileName = fileName
        self.fileExtension = fileExtension
        self.fileType = fileType
        self.fileSize = fileSize
        self.lastModified = lastModified
        self.createdAt = createdAt
        self.extraMetadata = extraMetadata
    }
}

struct LocalFilesFilter: Hashable, Sendable {
    var sourceID: UUID?
    var fileTypes: Set<String>
    var searchText: String
    var limit: Int

    init(
        sourceID: UUID? = nil,
        fileTypes: Set<String> = [],
        searchText: String = "",
        limit: Int = 250
    ) {
        self.sourceID = sourceID
        self.fileTypes = fileTypes
        self.searchText = searchText
        self.limit = limit
    }
}

struct IndexedFileSummary: Identifiable, Hashable, Sendable {
    let id: UUID
    let sourceID: UUID
    let urlPath: String
    let fileName: String
    let fileExtension: String?
    let fileType: String
    let fileSize: Int64?
    let lastModified: Date?
}
