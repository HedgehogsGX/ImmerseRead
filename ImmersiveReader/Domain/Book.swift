import Foundation
import SwiftData

@Model
final class Book {
    @Attribute(.unique) var id: UUID
    var title: String
    var author: String?
    var originalFilename: String
    var formatRawValue: String
    var textEncodingRawValue: String?
    var storedRelativePath: String
    @Attribute(.unique) var contentHash: String
    var fileByteCount: Int64
    var importedAt: Date
    var lastOpenedAt: Date?
    var readingProgress: Double
    var readingLocationData: Data?

    var format: BookFormat {
        get {
            guard let format = BookFormat(rawValue: formatRawValue) else {
                assertionFailure("Unknown persisted book format: \(formatRawValue)")
                return .txt
            }
            return format
        }
        set {
            formatRawValue = newValue.rawValue
        }
    }

    var textEncoding: BookTextEncoding? {
        get {
            textEncodingRawValue.flatMap(BookTextEncoding.init(rawValue:))
        }
        set {
            textEncodingRawValue = newValue?.rawValue
        }
    }

    init(
        id: UUID,
        title: String,
        author: String? = nil,
        originalFilename: String,
        format: BookFormat,
        textEncoding: BookTextEncoding? = nil,
        storedRelativePath: String,
        contentHash: String,
        fileByteCount: Int64,
        importedAt: Date,
        lastOpenedAt: Date? = nil,
        readingProgress: Double = 0,
        readingLocationData: Data? = nil
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.originalFilename = originalFilename
        formatRawValue = format.rawValue
        textEncodingRawValue = textEncoding?.rawValue
        self.storedRelativePath = storedRelativePath
        self.contentHash = contentHash
        self.fileByteCount = fileByteCount
        self.importedAt = importedAt
        self.lastOpenedAt = lastOpenedAt
        self.readingProgress = min(max(readingProgress, 0), 1)
        self.readingLocationData = readingLocationData
    }

    convenience init(importResult: BookImportResult) {
        self.init(
            id: importResult.id,
            title: importResult.title,
            originalFilename: importResult.originalFilename,
            format: importResult.format,
            textEncoding: importResult.textEncoding,
            storedRelativePath: importResult.storedRelativePath,
            contentHash: importResult.contentHash,
            fileByteCount: importResult.fileByteCount,
            importedAt: importResult.importedAt
        )
    }

    func updateReadingProgress(
        _ progress: Double,
        locationData: Data?,
        openedAt: Date = Date()
    ) {
        readingProgress = min(max(progress, 0), 1)
        readingLocationData = locationData
        lastOpenedAt = openedAt
    }
}
