import Foundation
import ReadiumZIPFoundation
import Testing
@testable import ImmerseRead

struct ArchiveSafetyValidatorTests {
    @Test
    func acceptsAnEPUBWithAValidContainerStructure() async throws {
        let fixture = try ArchiveFixture()
        defer { fixture.remove() }

        let archiveURL = try await fixture.makeArchive(
            filename: "valid.epub",
            entries: [
                ("mimetype", Data("application/epub+zip".utf8)),
                ("META-INF/container.xml", Data("<container />".utf8)),
                ("OPS/content.opf", Data("<package />".utf8)),
            ]
        )

        try await ArchiveSafetyValidator().validate(at: archiveURL, as: .epub)
    }

    @Test
    func rejectsEPUBWithAnInvalidMimetypeEntry() async throws {
        let fixture = try ArchiveFixture()
        defer { fixture.remove() }

        let archiveURL = try await fixture.makeArchive(
            filename: "invalid-mimetype.epub",
            entries: [
                ("mimetype", Data("application/zip".utf8)),
                ("META-INF/container.xml", Data("<container />".utf8)),
            ]
        )

        await #expect(throws: BookImportError.invalidArchive(expectedFormat: .epub)) {
            try await ArchiveSafetyValidator().validate(at: archiveURL, as: .epub)
        }
    }

    @Test
    func rejectsAZIPRenamedAsDOCXWhenRequiredPartsAreMissing() async throws {
        let fixture = try ArchiveFixture()
        defer { fixture.remove() }

        let archiveURL = try await fixture.makeArchive(
            filename: "renamed.docx",
            entries: [("notes.txt", Data("not a Word document".utf8))]
        )

        await #expect(throws: BookImportError.invalidArchive(expectedFormat: .docx)) {
            try await ArchiveSafetyValidator().validate(at: archiveURL, as: .docx)
        }
    }

    @Test
    func rejectsArchivePathTraversal() async throws {
        let fixture = try ArchiveFixture()
        defer { fixture.remove() }

        let archiveURL = try await fixture.makeArchive(
            filename: "unsafe.docx",
            entries: [
                ("[Content_Types].xml", Data("<Types />".utf8)),
                ("word/document.xml", Data("<document />".utf8)),
                ("../outside.txt", Data("escape".utf8)),
            ]
        )

        do {
            try await ArchiveSafetyValidator().validate(at: archiveURL, as: .docx)
            Issue.record("Expected path traversal to be rejected")
        } catch let error as BookImportError {
            guard case .unsafeArchive = error else {
                Issue.record("Expected unsafeArchive, received \(error)")
                return
            }
        }
    }

    @Test
    func rejectsArchiveWhoseExpandedContentExceedsTheLimit() async throws {
        let fixture = try ArchiveFixture()
        defer { fixture.remove() }

        let archiveURL = try await fixture.makeArchive(
            filename: "oversized.docx",
            entries: [
                ("[Content_Types].xml", Data("<Types />".utf8)),
                ("word/document.xml", Data(repeating: 0x61, count: 32)),
            ]
        )
        let limits = ArchiveSafetyLimits(
            maximumEntryCount: 10,
            maximumExpandedByteCount: 16,
            maximumCompressionRatio: 250
        )

        do {
            try await ArchiveSafetyValidator(limits: limits).validate(
                at: archiveURL,
                as: .docx
            )
            Issue.record("Expected expanded-size limit to be enforced")
        } catch let error as BookImportError {
            guard case .unsafeArchive = error else {
                Issue.record("Expected unsafeArchive, received \(error)")
                return
            }
        }
    }
}

private struct ArchiveFixture {
    let directoryURL: URL

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchiveSafetyValidatorTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
    }

    func makeArchive(
        filename: String,
        entries: [(path: String, data: Data)]
    ) async throws -> URL {
        let archiveURL = directoryURL.appendingPathComponent(filename)
        let archive = try await Archive(url: archiveURL, accessMode: .create)

        for entry in entries {
            let data = entry.data
            try await archive.addEntry(
                with: entry.path,
                type: .file,
                uncompressedSize: Int64(data.count),
                provider: { position, requestedSize in
                    let startIndex = Int(position)
                    guard startIndex < data.count else {
                        return Data()
                    }
                    let endIndex = min(startIndex + requestedSize, data.count)
                    return data.subdata(in: startIndex ..< endIndex)
                }
            )
        }

        return archiveURL
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}
