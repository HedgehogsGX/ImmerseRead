import Foundation
import Testing
@testable import ImmersiveReader

struct BookImportServiceTests {
    @Test
    func importsIntoAtomicBookDirectoryAndPreservesOriginalBytes() async throws {
        let fixture = try ImportFixture()
        defer { fixture.remove() }

        let identifier = try #require(UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF"))
        let importedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let service = BookImportService(
            libraryRootURL: fixture.libraryRootURL,
            now: { importedAt },
            makeIdentifier: { identifier }
        )
        let sourceURL = try fixture.writeSource(
            filename: "..\\escape.MD",
            data: Data("hello".utf8)
        )

        let result = try await service.importBook(
            from: sourceURL,
            existingContentHashes: []
        )

        #expect(result.id == identifier)
        #expect(result.title == "..\\escape")
        #expect(result.originalFilename == "..\\escape.MD")
        #expect(result.format == .md)
        #expect(result.textEncoding == .utf8)
        #expect(result.storedRelativePath == "\(identifier.uuidString)/original.md")
        #expect(result.contentHash == "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
        #expect(result.fileByteCount == 5)
        #expect(result.importedAt == importedAt)
        #expect(!result.storedRelativePath.contains("\\"))

        let storedURL = try await service.storedFileURL(for: result.storedRelativePath)
        #expect(try Data(contentsOf: storedURL) == Data("hello".utf8))

        try Data("changed".utf8).write(to: sourceURL, options: .atomic)
        #expect(try Data(contentsOf: storedURL) == Data("hello".utf8))

        let rootEntries = try FileManager.default.contentsOfDirectory(
            at: fixture.libraryRootURL,
            includingPropertiesForKeys: nil
        )
        #expect(rootEntries.map(\.lastPathComponent) == [identifier.uuidString])
    }

    @Test
    func rejectsHashAlreadyPersistedWithoutLeavingStagingFiles() async throws {
        let fixture = try ImportFixture()
        defer { fixture.remove() }

        let sourceURL = try fixture.writeSource(
            filename: "duplicate.txt",
            data: Data("hello".utf8)
        )
        let service = BookImportService(libraryRootURL: fixture.libraryRootURL)
        let knownHash = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"

        do {
            _ = try await service.importBook(
                from: sourceURL,
                existingContentHashes: [knownHash]
            )
            Issue.record("Expected duplicate content to be rejected")
        } catch let error as BookImportError {
            #expect(error == .duplicate(contentHash: knownHash))
        }

        let rootEntries = try FileManager.default.contentsOfDirectory(
            at: fixture.libraryRootURL,
            includingPropertiesForKeys: nil
        )
        #expect(rootEntries.isEmpty)
    }

    @Test
    func rejectsDuplicateImportedDuringCurrentSession() async throws {
        let fixture = try ImportFixture()
        defer { fixture.remove() }

        let firstURL = try fixture.writeSource(
            filename: "first.txt",
            data: Data("same content".utf8)
        )
        let secondURL = try fixture.writeSource(
            filename: "second.md",
            data: Data("same content".utf8)
        )
        let service = BookImportService(libraryRootURL: fixture.libraryRootURL)
        let firstImport = try await service.importBook(
            from: firstURL,
            existingContentHashes: []
        )

        do {
            _ = try await service.importBook(
                from: secondURL,
                existingContentHashes: []
            )
            Issue.record("Expected same-session duplicate content to be rejected")
        } catch let error as BookImportError {
            #expect(error == .duplicate(contentHash: firstImport.contentHash))
        }
    }

    @Test
    func removeDeletesOnlyTheRequestedBookAndReleasesSessionHash() async throws {
        let fixture = try ImportFixture()
        defer { fixture.remove() }

        let sourceURL = try fixture.writeSource(
            filename: "book.txt",
            data: Data("content".utf8)
        )
        let service = BookImportService(libraryRootURL: fixture.libraryRootURL)
        let imported = try await service.importBook(
            from: sourceURL,
            existingContentHashes: []
        )

        try await service.removeStoredFiles(
            for: imported.id,
            contentHash: imported.contentHash
        )

        await #expect(throws: BookImportError.storedFileMissing) {
            try await service.storedFileURL(for: imported.storedRelativePath)
        }

        let importedAgain = try await service.importBook(
            from: sourceURL,
            existingContentHashes: []
        )
        #expect(importedAgain.contentHash == imported.contentHash)
        #expect(importedAgain.id != imported.id)
    }

    @Test
    func rejectsUnsafeStoredRelativePaths() async throws {
        let fixture = try ImportFixture()
        defer { fixture.remove() }
        let service = BookImportService(libraryRootURL: fixture.libraryRootURL)

        let unsafePaths = [
            "../outside/original",
            "/absolute/original",
            "not-a-uuid/original.txt",
            "01234567-89AB-CDEF-0123-456789ABCDEF/../secret",
            "01234567-89AB-CDEF-0123-456789ABCDEF/original.exe",
        ]

        for unsafePath in unsafePaths {
            do {
                _ = try await service.storedFileURL(for: unsafePath)
                Issue.record("Expected unsafe path to be rejected: \(unsafePath)")
            } catch let error as BookImportError {
                #expect(error == .unsafeStoredPath)
            }
        }
    }

    @Test
    func enforcesConfiguredFileSizeLimitBeforeCopying() async throws {
        let fixture = try ImportFixture()
        defer { fixture.remove() }

        let sourceURL = try fixture.writeSource(
            filename: "large.txt",
            data: Data("12345".utf8)
        )
        let service = BookImportService(
            libraryRootURL: fixture.libraryRootURL,
            maximumFileSize: 4
        )

        do {
            _ = try await service.importBook(
                from: sourceURL,
                existingContentHashes: []
            )
            Issue.record("Expected oversized file to be rejected")
        } catch let error as BookImportError {
            #expect(error == .fileTooLarge(actualBytes: 5, maximumBytes: 4))
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.libraryRootURL.path))
    }

    @Test
    func reconciliationRemovesOnlyOwnedOrphansAndStagingDirectories() async throws {
        let fixture = try ImportFixture()
        defer { fixture.remove() }

        let firstURL = try fixture.writeSource(
            filename: "kept.txt",
            data: Data("kept".utf8)
        )
        let secondURL = try fixture.writeSource(
            filename: "orphan.txt",
            data: Data("orphan".utf8)
        )
        let service = BookImportService(libraryRootURL: fixture.libraryRootURL)
        let kept = try await service.importBook(from: firstURL, existingContentHashes: [])
        let orphan = try await service.importBook(from: secondURL, existingContentHashes: [])

        let stagingURL = fixture.libraryRootURL
            .appendingPathComponent(".import-\(UUID().uuidString)", isDirectory: true)
        let unknownURL = fixture.libraryRootURL
            .appendingPathComponent("do-not-touch", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingURL, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: unknownURL, withIntermediateDirectories: false)

        try await service.reconcileStorage(validBookIDs: [kept.id])

        let keptURL = try await service.storedFileURL(for: kept.storedRelativePath)
        #expect(keptURL.isFileURL)
        await #expect(throws: BookImportError.storedFileMissing) {
            try await service.storedFileURL(for: orphan.storedRelativePath)
        }
        #expect(!FileManager.default.fileExists(atPath: stagingURL.path))
        #expect(FileManager.default.fileExists(atPath: unknownURL.path))
    }
}

private struct ImportFixture {
    let baseURL: URL
    let sourceDirectoryURL: URL
    let libraryRootURL: URL

    init() throws {
        baseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BookImportServiceTests-\(UUID().uuidString)")
        sourceDirectoryURL = baseURL.appendingPathComponent("Sources", isDirectory: true)
        libraryRootURL = baseURL.appendingPathComponent("Application Support/Books", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sourceDirectoryURL,
            withIntermediateDirectories: true
        )
    }

    func writeSource(filename: String, data: Data) throws -> URL {
        let url = sourceDirectoryURL.appendingPathComponent(filename)
        try data.write(to: url, options: .atomic)
        return url
    }

    func remove() {
        try? FileManager.default.removeItem(at: baseURL)
    }
}
