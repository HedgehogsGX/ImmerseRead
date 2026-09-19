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
    var coverRelativePath: String?
    /// `nil` means cover detection has never run for this book.
    var coverSourceRawValue: String?
    /// `nil` means the lettering cover follows the automatic palette.
    var coverStyleRawValue: String?
    /// Bumped whenever the cover file changes, so cached images are reloaded.
    var coverUpdatedAt: Date?
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
                return .plainText
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

    var coverSource: BookCoverSource? {
        get {
            coverSourceRawValue.flatMap(BookCoverSource.init(rawValue:))
        }
        set {
            coverSourceRawValue = newValue?.rawValue
        }
    }

    /// The palette of the lettering cover, either the reader's pick or the
    /// automatic one derived from the title.
    var coverStyle: BookCoverStyle {
        get {
            coverStyleRawValue.flatMap(BookCoverStyle.init(rawValue:))
                ?? BookCoverStyle.automatic(for: coverStyleSeed)
        }
        set {
            coverStyleRawValue = newValue.rawValue
        }
    }

    /// Whether the app has never looked inside this document for a cover.
    var needsCoverDetection: Bool {
        coverSourceRawValue == nil
    }

    private var coverStyleSeed: String {
        "\(title)|\(author ?? "")"
    }

    init(
        id: UUID,
        title: String,
        author: String? = nil,
        originalFilename: String,
        format: BookFormat,
        textEncoding: BookTextEncoding? = nil,
        storedRelativePath: String,
        coverRelativePath: String? = nil,
        coverSource: BookCoverSource? = nil,
        coverStyle: BookCoverStyle? = nil,
        coverUpdatedAt: Date? = nil,
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
        self.coverRelativePath = coverRelativePath
        coverSourceRawValue = coverSource?.rawValue
        coverStyleRawValue = coverStyle?.rawValue
        self.coverUpdatedAt = coverUpdatedAt
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
            author: importResult.author,
            originalFilename: importResult.originalFilename,
            format: importResult.format,
            textEncoding: importResult.textEncoding,
            storedRelativePath: importResult.storedRelativePath,
            coverRelativePath: importResult.coverRelativePath,
            coverSource: importResult.coverSource,
            coverUpdatedAt: importResult.coverRelativePath == nil
                ? nil
                : importResult.importedAt,
            contentHash: importResult.contentHash,
            fileByteCount: importResult.fileByteCount,
            importedAt: importResult.importedAt
        )
    }

    /// Records the outcome of a cover change, whether or not a file was written.
    func applyCover(
        relativePath: String?,
        source: BookCoverSource,
        updatedAt: Date = Date()
    ) {
        coverRelativePath = relativePath
        coverSource = source
        coverUpdatedAt = updatedAt
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
