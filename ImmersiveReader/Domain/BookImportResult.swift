import Foundation

struct BookImportResult: Equatable, Sendable {
    let id: UUID
    let title: String
    let author: String?
    let originalFilename: String
    let format: BookFormat
    let textEncoding: BookTextEncoding?
    let storedRelativePath: String
    let coverRelativePath: String?
    let coverSource: BookCoverSource
    let contentHash: String
    let fileByteCount: Int64
    let importedAt: Date

    init(
        id: UUID,
        title: String,
        author: String? = nil,
        originalFilename: String,
        format: BookFormat,
        textEncoding: BookTextEncoding? = nil,
        storedRelativePath: String,
        coverRelativePath: String? = nil,
        coverSource: BookCoverSource = .embedded,
        contentHash: String,
        fileByteCount: Int64,
        importedAt: Date
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.originalFilename = originalFilename
        self.format = format
        self.textEncoding = textEncoding
        self.storedRelativePath = storedRelativePath
        self.coverRelativePath = coverRelativePath
        self.coverSource = coverRelativePath == nil ? .generated : coverSource
        self.contentHash = contentHash
        self.fileByteCount = fileByteCount
        self.importedAt = importedAt
    }
}
