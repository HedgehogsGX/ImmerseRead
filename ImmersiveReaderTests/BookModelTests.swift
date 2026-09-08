import Foundation
import Testing
@testable import ImmersiveReader

struct BookModelTests {
    @Test
    func initializesFromImportResultAndClampsProgress() throws {
        let id = try #require(UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF"))
        let date = Date(timeIntervalSince1970: 100)
        let result = BookImportResult(
            id: id,
            title: "示例",
            originalFilename: "示例.markdown",
            format: .markdown,
            textEncoding: .utf8,
            storedRelativePath: "\(id.uuidString)/original.markdown",
            contentHash: String(repeating: "a", count: 64),
            fileByteCount: 12,
            importedAt: date
        )

        let book = Book(importResult: result)
        #expect(book.id == result.id)
        #expect(book.format == .markdown)
        #expect(book.textEncoding == .utf8)
        #expect(book.readingProgress == 0)

        let location = Data("locator".utf8)
        book.updateReadingProgress(1.25, locationData: location, openedAt: date)
        #expect(book.readingProgress == 1)
        #expect(book.readingLocationData == location)
        #expect(book.lastOpenedAt == date)

        book.updateReadingProgress(-1, locationData: nil, openedAt: date)
        #expect(book.readingProgress == 0)
    }
}
