import Foundation
import SwiftData
import Testing
@testable import ImmersiveReader

/// What has to keep working when a reader installs a newer build over an older
/// one: the database opens, it opens from where it already lives, and the
/// documents outlive a database that does not.
struct LibraryUpdateSafetyTests {
    @Test @MainActor
    func aLibraryWrittenWithoutAVersionedSchemaStillOpens() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryUpdateSafetyTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let storeURL = directory.appendingPathComponent("default.store")
        let id = UUID()
        let location = EPUBReadingLocation(locatorJSON: #"{"href":"chapter.xhtml"}"#, progress: 0.62)

        // The store an installed copy already has, written by the model with no
        // version attached to it.
        try autoreleasepool {
            let container = try ModelContainer(
                for: Book.self,
                configurations: ModelConfiguration(url: storeURL)
            )
            let context = ModelContext(container)
            context.insert(
                Book(
                    id: id,
                    title: "Installed before the update",
                    author: "Author",
                    originalFilename: "book.epub",
                    format: .epub,
                    storedRelativePath: "\(id.uuidString)/original.epub",
                    contentHash: String(repeating: "a", count: 64),
                    fileByteCount: 4_096,
                    importedAt: .now,
                    readingProgress: location.progress,
                    readingLocationData: location.encoded()
                )
            )
            try context.save()
        }

        let upgraded = try LibraryStore.makeContainer(
            configuration: ModelConfiguration(schema: LibraryStore.schema, url: storeURL)
        )
        let books = try ModelContext(upgraded).fetch(FetchDescriptor<Book>())

        let book = try #require(books.first)
        #expect(books.count == 1)
        #expect(book.id == id)
        #expect(book.title == "Installed before the update")
        #expect(book.readingProgress == location.progress)
        #expect(EPUBReadingLocation.restore(from: book.readingLocationData) == location)
    }

    @Test
    func theStoreStaysWhereInstalledCopiesAlreadyKeepIt() throws {
        let configuration = LibraryStore.defaultConfiguration
        let expected = URL.applicationSupportDirectory
            .appendingPathComponent("default.store")

        #expect(configuration.url.resolvingSymlinksInPath() == expected.resolvingSymlinksInPath())
    }

    @Test
    func booksAreKeptWhenTheLibraryReadsAsEmpty() async throws {
        let fixture = try LibraryFixture()
        defer { fixture.remove() }

        let service = fixture.makeService()
        let first = try await service.importBook(
            from: try fixture.writeSource(filename: "first.txt", data: Data("first".utf8)),
            existingContentHashes: []
        )
        let second = try await service.importBook(
            from: try fixture.writeSource(filename: "second.txt", data: Data("second".utf8)),
            existingContentHashes: []
        )

        // A database that failed to open reports the same thing as a shelf the
        // reader emptied, and the documents must survive the first.
        try await service.reconcileStorage(validBookIDs: [])

        #expect(try await service.storedFileURL(for: first.storedRelativePath).isFileURL)
        #expect(try await service.storedFileURL(for: second.storedRelativePath).isFileURL)
    }

    @Test
    func aBookSetAsideIsGivenBackWhenItsRecordReturns() async throws {
        let fixture = try LibraryFixture()
        defer { fixture.remove() }

        let service = fixture.makeService()
        let kept = try await service.importBook(
            from: try fixture.writeSource(filename: "kept.txt", data: Data("kept".utf8)),
            existingContentHashes: []
        )
        let missing = try await service.importBook(
            from: try fixture.writeSource(filename: "missing.txt", data: Data("missing".utf8)),
            existingContentHashes: []
        )

        try await service.reconcileStorage(validBookIDs: [kept.id])

        let quarantined = try #require(fixture.quarantinedEntries().first)
        #expect(fixture.quarantinedEntries().count == 1)
        #expect(quarantined.lastPathComponent.hasSuffix(missing.id.uuidString))
        let setAsideOriginal = quarantined.appendingPathComponent("original.txt")
        #expect(try Data(contentsOf: setAsideOriginal) == Data("missing".utf8))

        try await service.reconcileStorage(validBookIDs: [kept.id, missing.id])

        let restoredURL = try await service.storedFileURL(for: missing.storedRelativePath)
        #expect(try Data(contentsOf: restoredURL) == Data("missing".utf8))
        #expect(fixture.quarantinedEntries().isEmpty)
    }

    @Test
    func aBookSetAsideIsDiscardedOnceItsRetentionRunsOut() async throws {
        let fixture = try LibraryFixture()
        defer { fixture.remove() }

        let quarantinedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let service = fixture.makeService(now: quarantinedAt)
        let kept = try await service.importBook(
            from: try fixture.writeSource(filename: "kept.txt", data: Data("kept".utf8)),
            existingContentHashes: []
        )
        let expiring = try await service.importBook(
            from: try fixture.writeSource(filename: "expiring.txt", data: Data("expiring".utf8)),
            existingContentHashes: []
        )

        try await service.reconcileStorage(validBookIDs: [kept.id])
        #expect(fixture.quarantinedEntries().count == 1)

        let laterService = fixture.makeService(
            now: quarantinedAt.addingTimeInterval(BookImportService.orphanRetention + 1)
        )
        try await laterService.reconcileStorage(validBookIDs: [kept.id])

        #expect(fixture.quarantinedEntries().isEmpty)
        await #expect(throws: BookImportError.storedFileMissing) {
            try await laterService.storedFileURL(for: expiring.storedRelativePath)
        }
        #expect(try await laterService.storedFileURL(for: kept.storedRelativePath).isFileURL)
    }
}

private struct LibraryFixture {
    let baseURL: URL
    let sourceDirectoryURL: URL
    let libraryRootURL: URL

    init() throws {
        baseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryUpdateSafetyTests-\(UUID().uuidString)")
        sourceDirectoryURL = baseURL.appendingPathComponent("Sources", isDirectory: true)
        libraryRootURL = baseURL.appendingPathComponent("Application Support/Books", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sourceDirectoryURL,
            withIntermediateDirectories: true
        )
    }

    func makeService(now: Date = .now) -> BookImportService {
        BookImportService(libraryRootURL: libraryRootURL, now: { now })
    }

    func writeSource(filename: String, data: Data) throws -> URL {
        let url = sourceDirectoryURL.appendingPathComponent(filename)
        try data.write(to: url, options: .atomic)
        return url
    }

    func quarantinedEntries() -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: libraryRootURL,
            includingPropertiesForKeys: nil,
            options: []
        )) ?? []
        return entries.filter { $0.lastPathComponent.hasPrefix(".orphaned-") }
    }

    func remove() {
        try? FileManager.default.removeItem(at: baseURL)
    }
}
