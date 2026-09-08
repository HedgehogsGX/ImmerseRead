import Foundation

struct BookImportResult: Equatable, Sendable {
    let id: UUID
    let title: String
    let originalFilename: String
    let format: BookFormat
    let textEncoding: BookTextEncoding?
    let storedRelativePath: String
    let contentHash: String
    let fileByteCount: Int64
    let importedAt: Date
}
