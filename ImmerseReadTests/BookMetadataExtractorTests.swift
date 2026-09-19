import Foundation
import ReadiumZIPFoundation
import Testing
import UIKit
@testable import ImmerseRead

struct BookMetadataExtractorTests {
    @Test @MainActor
    func returnsEmptyMetadataForUnsupportedAndCorruptDocuments() async throws {
        let fixture = try MetadataFixture()
        defer { fixture.remove() }
        let corruptEPUBURL = try fixture.writeCorruptDocument(filename: "broken.epub")
        let corruptPDFURL = try fixture.writeCorruptDocument(filename: "broken.pdf")
        let plainTextURL = try fixture.writeCorruptDocument(filename: "notes.txt")
        let extractor = BookMetadataExtractor()

        let epubMetadata = await extractor.extract(from: corruptEPUBURL, format: .epub)
        let pdfMetadata = await extractor.extract(from: corruptPDFURL, format: .pdf)
        let plainTextMetadata = await extractor.extract(from: plainTextURL, format: .plainText)

        #expect(epubMetadata == BookMetadata())
        #expect(pdfMetadata == BookMetadata())
        #expect(plainTextMetadata == BookMetadata())
    }

    @Test @MainActor
    func normalizesBlankAndOversizedMetadataValues() {
        #expect(BookMetadataExtractor.normalized("  title  ") == "title")
        #expect(BookMetadataExtractor.normalized(" \n\t ") == nil)
        let oversized = String(repeating: "x", count: 600)
        #expect(BookMetadataExtractor.normalized(oversized)?.count == 512)
    }

    @Test @MainActor
    func extractsPDFTitleAndAuthorFromDocumentAttributes() async throws {
        let fixture = try MetadataFixture()
        defer { fixture.remove() }
        let sourceURL = try fixture.writePDF()

        let metadata = await BookMetadataExtractor().extract(from: sourceURL, format: .pdf)

        #expect(metadata.title == "PDF Test Title")
        #expect(metadata.author == "PDF Test Author")
        #expect(metadata.coverData == nil)
    }

    @Test @MainActor
    func extractsEPUBMetadataAndPersistsAValidCoverFile() async throws {
        let fixture = try MetadataFixture()
        defer { fixture.remove() }
        let sourceURL = try await fixture.writeEPUB()
        let extractor = BookMetadataExtractor(maximumCoverBytes: 100_000)

        let metadata = await extractor.extract(from: sourceURL, format: .epub)

        #expect(metadata.title == "测试书名")
        #expect(metadata.author == "测试作者")
        let metadataCoverData = try #require(metadata.coverData)
        let metadataCoverImage = try #require(UIImage(data: metadataCoverData))
        #expect(metadataCoverImage.size.width <= 480)
        #expect(metadataCoverImage.size.height <= 680)

        let service = BookImportService(
            libraryRootURL: fixture.libraryRootURL,
            makeIdentifier: { UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")! }
        )
        let result = try await service.importBook(from: sourceURL, existingContentHashes: [])

        #expect(result.title == "测试书名")
        #expect(result.author == "测试作者")
        let coverRelativePath = try #require(result.coverRelativePath)
        let coverURL = try await service.storedCoverURL(for: coverRelativePath)
        let coverData = try Data(contentsOf: coverURL)
        #expect(!coverData.isEmpty)
        #expect(coverData.count <= 1_500_000)

        for unsafePath in [
            "../outside/cover.jpg",
            "\(result.id.uuidString)/original.jpg",
            "\(result.id.uuidString)/cover.png",
        ] {
            do {
                _ = try await service.storedCoverURL(for: unsafePath)
                Issue.record("Expected unsafe cover path to be rejected: \(unsafePath)")
            } catch let error as BookImportError {
                #expect(error == .unsafeStoredPath)
            }
        }
    }

    @Test @MainActor
    func ignoresExternalEPUBCoverResources() async throws {
        let fixture = try MetadataFixture()
        defer { fixture.remove() }
        let sourceURL = try await fixture.writeEPUB(coverHref: "https://example.invalid/cover.jpg")

        let metadata = await BookMetadataExtractor().extract(from: sourceURL, format: .epub)

        #expect(metadata.title == "测试书名")
        #expect(metadata.author == "测试作者")
        #expect(metadata.coverData == nil)
    }

    @Test @MainActor
    func skipsCoversOverTheConfiguredSourceByteLimit() async throws {
        let fixture = try MetadataFixture()
        defer { fixture.remove() }
        let sourceURL = try await fixture.writeEPUB()
        let extractor = BookMetadataExtractor(maximumSourceCoverBytes: 32)

        let metadata = await extractor.extract(from: sourceURL, format: .epub)

        #expect(metadata.title == "测试书名")
        #expect(metadata.author == "测试作者")
        #expect(metadata.coverData == nil)
    }
}

private struct MetadataFixture {
    let baseURL: URL
    let libraryRootURL: URL

    init() throws {
        baseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BookMetadataExtractorTests-\(UUID().uuidString)")
        libraryRootURL = baseURL.appendingPathComponent("Books", isDirectory: true)
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
    }

    func writeEPUB(coverHref: String = "images/cover.png") async throws -> URL {
        let fileURL = baseURL.appendingPathComponent("metadata.epub")
        let archive = try await Archive(url: fileURL, accessMode: .create)
        let imageData = Data([
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
            0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
            0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
            0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
            0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41,
            0x54, 0x78, 0x9C, 0x63, 0xF8, 0xCF, 0xC0, 0xF0,
            0x1F, 0x00, 0x05, 0x00, 0x01, 0xFF, 0x89, 0x99,
            0x3D, 0x1D, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45,
            0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
        ])
        var entries: [(String, Data)] = [
            ("mimetype", Data("application/epub+zip".utf8)),
            (
                "META-INF/container.xml",
                Data("""
                <?xml version="1.0" encoding="UTF-8"?>
                <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
                  <rootfiles><rootfile full-path="EPUB/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
                </container>
                """.utf8)
            ),
            (
                "EPUB/content.opf",
                Data("""
                <?xml version="1.0" encoding="UTF-8"?>
                <package version="3.0" unique-identifier="book-id" xmlns="http://www.idpf.org/2007/opf">
                  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                    <dc:identifier id="book-id">urn:uuid:00000000-0000-0000-0000-000000000001</dc:identifier>
                    <dc:title>测试书名</dc:title><dc:creator>测试作者</dc:creator><dc:language>zh-CN</dc:language>
                  </metadata>
                  <manifest>
                    <item id="cover" href="\(coverHref)" media-type="image/png" properties="cover-image"/>
                    <item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/>
                  </manifest>
                  <spine><itemref idref="chapter"/></spine>
                </package>
                """.utf8)
            ),
            (
                "EPUB/chapter.xhtml",
                Data("<html xmlns=\"http://www.w3.org/1999/xhtml\"><body><p>正文</p></body></html>".utf8)
            ),
        ]
        if coverHref == "images/cover.png" {
            entries.append(("EPUB/images/cover.png", imageData))
        }
        for (path, data) in entries {
            try await archive.addEntry(
                with: path,
                type: .file,
                uncompressedSize: Int64(data.count),
                provider: { position, requestedSize in
                    let start = Int(position)
                    guard start < data.count else { return Data() }
                    return data.subdata(in: start ..< min(start + requestedSize, data.count))
                }
            )
        }
        return fileURL
    }

    func writePDF() throws -> URL {
        let fileURL = baseURL.appendingPathComponent("metadata.pdf")
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [4 0 R] /Count 1 >>",
            "<< /Title (PDF Test Title) /Author (PDF Test Author) >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 10 10] >>",
        ]
        var document = "%PDF-1.4\n"
        var offsets = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(document.utf8.count)
            document += "\(index + 1) 0 obj\n\(object)\nendobj\n"
        }
        let xrefOffset = document.utf8.count
        document += "xref\n0 \(objects.count + 1)\n"
        document += "0000000000 65535 f \n"
        for offset in offsets.dropFirst() {
            document += String(format: "%010d 00000 n \n", offset)
        }
        document += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R /Info 3 0 R >>\n"
        document += "startxref\n\(xrefOffset)\n%%EOF\n"
        try Data(document.utf8).write(to: fileURL)
        return fileURL
    }

    func writeCorruptDocument(filename: String) throws -> URL {
        let fileURL = baseURL.appendingPathComponent(filename)
        try Data("not a document".utf8).write(to: fileURL)
        return fileURL
    }

    func remove() {
        try? FileManager.default.removeItem(at: baseURL)
    }
}
