import Foundation
import SwiftData
import Testing
@testable import ImmerseRead

struct BookPersistenceTests {
    @Test @MainActor
    func importedMetadataAndReadingLocationSurviveDatabaseReopening() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.store")
        let id = UUID()
        let result = BookImportResult(
            id: id,
            title: "Publication title",
            author: "Publication author",
            originalFilename: "filename.epub",
            format: .epub,
            storedRelativePath: "\(id.uuidString)/original.epub",
            coverRelativePath: "\(id.uuidString)/cover.jpg",
            contentHash: String(repeating: "d", count: 64),
            fileByteCount: 5_000,
            importedAt: .now
        )
        let location = EPUBReadingLocation(locatorJSON: #"{"href":"chapter.xhtml"}"#, progress: 0.4)
        try autoreleasepool {
            let container = try ModelContainer(for: Book.self, configurations: ModelConfiguration(url: url))
            let context = ModelContext(container)
            let book = Book(importResult: result)
            book.updateReadingProgress(location.progress, locationData: location.encoded())
            context.insert(book)
            try context.save()
        }
        let reopened = try ModelContainer(for: Book.self, configurations: ModelConfiguration(url: url))
        let books = try ModelContext(reopened).fetch(FetchDescriptor<Book>())
        let book = try #require(books.first)
        #expect(book.id == id)
        #expect(book.title == result.title)
        #expect(book.author == result.author)
        #expect(book.coverRelativePath == result.coverRelativePath)
        #expect(EPUBReadingLocation.restore(from: book.readingLocationData) == location)
    }
}
