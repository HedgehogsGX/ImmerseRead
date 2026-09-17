import Foundation
import ReadiumZIPFoundation
import Testing
import UIKit
@testable import ImmerseRead

struct BookCoverTests {
    // MARK: - Detection

    @Test @MainActor
    func rendersACoverFromTheFirstPDFPage() async throws {
        let fixture = try CoverFixture()
        defer { fixture.remove() }
        let sourceURL = try fixture.writeSource(
            filename: "illustrated.pdf",
            data: CoverFixture.pdfData(
                pageSizes: [CoverFixture.letterPageSize],
                contentPageIndexes: [0]
            )
        )

        let metadata = await BookMetadataExtractor().extract(from: sourceURL, format: .pdf)

        let coverData = try #require(metadata.coverData)
        #expect(metadata.coverSource == .rendered)
        let coverImage = try #require(UIImage(data: coverData))
        #expect(coverImage.size.width <= 480)
        #expect(coverImage.size.height <= 680)
    }

    @Test @MainActor
    func looksPastABlankFirstPageAndGivesUpOnAnEmptyDocument() async throws {
        let fixture = try CoverFixture()
        defer { fixture.remove() }
        let blankFirstPageURL = try fixture.writeSource(
            filename: "blank-first.pdf",
            data: CoverFixture.pdfData(
                pageSizes: Array(repeating: CoverFixture.letterPageSize, count: 2),
                contentPageIndexes: [1]
            )
        )
        let emptyURL = try fixture.writeSource(
            filename: "empty.pdf",
            data: CoverFixture.pdfData(
                pageSizes: Array(repeating: CoverFixture.letterPageSize, count: 2),
                contentPageIndexes: []
            )
        )
        let extractor = BookMetadataExtractor()

        let blankFirstPageMetadata = await extractor.extract(
            from: blankFirstPageURL,
            format: .pdf
        )
        let emptyMetadata = await extractor.extract(from: emptyURL, format: .pdf)

        #expect(blankFirstPageMetadata.coverData != nil)
        #expect(emptyMetadata.coverData == nil)
        #expect(emptyMetadata.coverSource == .generated)
    }

    @Test @MainActor
    func readsDOCXPropertiesAndTheFirstUsablePicture() async throws {
        let fixture = try CoverFixture()
        defer { fixture.remove() }
        let sourceURL = try await fixture.writeDOCX(
            filename: "report.docx",
            pictures: [
                // Word numbers pictures in document order; the decorative one
                // comes first and has to be skipped.
                ("word/media/image1.png", CoverFixture.pngData(size: CGSize(width: 48, height: 48))),
                ("word/media/image2.png", CoverFixture.pngData(size: CGSize(width: 360, height: 520))),
            ]
        )

        let metadata = await BookMetadataExtractor().extract(from: sourceURL, format: .docx)

        #expect(metadata.title == "季度报告")
        #expect(metadata.author == "报告作者")
        #expect(metadata.coverSource == .embedded)
        let coverData = try #require(metadata.coverData)
        let coverImage = try #require(UIImage(data: coverData))
        #expect(coverImage.size.width > 160)
    }

    @Test @MainActor
    func keepsDOCXPropertiesWhenEveryPictureIsDecorative() async throws {
        let fixture = try CoverFixture()
        defer { fixture.remove() }
        let sourceURL = try await fixture.writeDOCX(
            filename: "icons.docx",
            pictures: [
                ("word/media/image1.png", CoverFixture.pngData(size: CGSize(width: 24, height: 24))),
                ("word/media/image2.png", CoverFixture.pngData(size: CGSize(width: 64, height: 64))),
            ]
        )

        let metadata = await BookMetadataExtractor().extract(from: sourceURL, format: .docx)

        #expect(metadata.title == "季度报告")
        #expect(metadata.coverData == nil)
        #expect(metadata.coverSource == .generated)
    }

    @Test @MainActor
    func readsMarkdownTitleFromFrontMatterAndHeading() async throws {
        let fixture = try CoverFixture()
        defer { fixture.remove() }
        let frontMatterURL = try fixture.writeSource(
            filename: "front-matter.md",
            data: Data("""
            ---
            title: "设计手记"
            author: 示例作者
            ---

            # 被前置信息覆盖的标题

            正文。
            """.utf8)
        )
        let headingURL = try fixture.writeSource(
            filename: "heading.md",
            data: Data("""
            <!-- 说明 -->

            # 只有标题

            正文。
            """.utf8)
        )
        let extractor = BookMetadataExtractor()

        let frontMatterMetadata = await extractor.extract(from: frontMatterURL, format: .markdown)
        let headingMetadata = await extractor.extract(from: headingURL, format: .markdown)

        #expect(frontMatterMetadata.title == "设计手记")
        #expect(frontMatterMetadata.author == "示例作者")
        #expect(headingMetadata.title == "只有标题")
        #expect(headingMetadata.author == nil)
    }

    // MARK: - Storage

    @Test
    func storesReplacesAndRemovesTheCoverOfAnImportedBook() async throws {
        let fixture = try CoverFixture()
        defer { fixture.remove() }
        let identifier = try #require(UUID(uuidString: "1A2B3C4D-5E6F-4A8B-9C0D-1E2F3A4B5C6D"))
        let service = BookImportService(
            libraryRootURL: fixture.libraryRootURL,
            makeIdentifier: { identifier }
        )
        let sourceURL = try fixture.writeSource(
            filename: "illustrated.pdf",
            data: await CoverFixture.pdfData(
                pageSizes: [CoverFixture.letterPageSize],
                contentPageIndexes: [0]
            )
        )

        let result = try await service.importBook(from: sourceURL, existingContentHashes: [])
        #expect(result.coverSource == .rendered)
        let detectedPath = try #require(result.coverRelativePath)
        let detectedCover = try Data(
            contentsOf: try await service.storedCoverURL(for: detectedPath)
        )

        let customPath = try await service.replaceCover(
            for: identifier,
            imageData: await CoverFixture.pngData(
                size: CGSize(width: 420, height: 620),
                color: .systemPink
            )
        )
        #expect(customPath == "\(identifier.uuidString)/cover.jpg")
        let customCover = try Data(
            contentsOf: try await service.storedCoverURL(for: customPath)
        )
        #expect(customCover != detectedCover)
        #expect(customCover.count <= CoverImageProcessor.defaultMaximumEncodedBytes)

        try await service.removeCover(for: identifier)
        await #expect(throws: BookImportError.storedFileMissing) {
            _ = try await service.storedCoverURL(for: customPath)
        }

        let detection = try await service.detectCover(
            for: identifier,
            storedRelativePath: result.storedRelativePath,
            format: .pdf
        )
        #expect(detection.coverRelativePath == customPath)
        #expect(detection.source == .rendered)
    }

    @Test
    func refusesUnusablePicturesAndMismatchedBooks() async throws {
        let fixture = try CoverFixture()
        defer { fixture.remove() }
        let identifier = try #require(UUID(uuidString: "1A2B3C4D-5E6F-4A8B-9C0D-1E2F3A4B5C6D"))
        let service = BookImportService(
            libraryRootURL: fixture.libraryRootURL,
            makeIdentifier: { identifier }
        )
        let sourceURL = try fixture.writeSource(
            filename: "notes.txt",
            data: Data("纯文本没有封面。".utf8)
        )

        let result = try await service.importBook(from: sourceURL, existingContentHashes: [])
        #expect(result.coverRelativePath == nil)
        #expect(result.coverSource == .generated)

        await #expect(throws: BookImportError.unusableCoverImage) {
            _ = try await service.replaceCover(
                for: identifier,
                imageData: Data("这不是图片".utf8)
            )
        }

        await #expect(throws: BookImportError.unsafeStoredPath) {
            _ = try await service.detectCover(
                for: UUID(),
                storedRelativePath: result.storedRelativePath,
                format: .plainText
            )
        }

        // Removing a cover that was never written stays a no-op.
        try await service.removeCover(for: identifier)
    }
}

private struct CoverFixture {
    static let letterPageSize = CGSize(width: 612, height: 792)

    let baseURL: URL
    let sourceDirectoryURL: URL
    let libraryRootURL: URL

    init() throws {
        baseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BookCoverTests-\(UUID().uuidString)")
        sourceDirectoryURL = baseURL.appendingPathComponent("Sources", isDirectory: true)
        libraryRootURL = baseURL.appendingPathComponent("Books", isDirectory: true)
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

    func writeDOCX(filename: String, pictures: [(String, Data)]) async throws -> URL {
        let fileURL = sourceDirectoryURL.appendingPathComponent(filename)
        let archive = try await Archive(url: fileURL, accessMode: .create)

        var entries: [(String, Data)] = [
            (
                "[Content_Types].xml",
                Data("""
                <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
                  <Default Extension="png" ContentType="image/png"/>
                  <Default Extension="xml" ContentType="application/xml"/>
                </Types>
                """.utf8)
            ),
            (
                "docProps/core.xml",
                Data("""
                <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                <cp:coreProperties
                  xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties"
                  xmlns:dc="http://purl.org/dc/elements/1.1/">
                  <dc:title>季度报告</dc:title>
                  <dc:creator>报告作者</dc:creator>
                </cp:coreProperties>
                """.utf8)
            ),
            (
                "word/document.xml",
                Data("""
                <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
                  <w:body><w:p><w:r><w:t>正文</w:t></w:r></w:p></w:body>
                </w:document>
                """.utf8)
            ),
        ]
        entries.append(contentsOf: pictures)

        for (path, data) in entries {
            try await archive.addEntry(
                with: path,
                type: .file,
                uncompressedSize: Int64(data.count),
                provider: { position, requestedSize in
                    let start = Int(position)
                    guard start < data.count else {
                        return Data()
                    }
                    return data.subdata(in: start ..< min(start + requestedSize, data.count))
                }
            )
        }
        return fileURL
    }

    @MainActor
    static func pngData(size: CGSize, color: UIColor = .systemIndigo) -> Data {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)

        return renderer.pngData { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor.white.setFill()
            context.fill(CGRect(
                x: size.width * 0.2,
                y: size.height * 0.35,
                width: size.width * 0.6,
                height: size.height * 0.08
            ))
        }
    }

    @MainActor
    static func pdfData(pageSizes: [CGSize], contentPageIndexes: Set<Int>) -> Data {
        let bounds = CGRect(origin: .zero, size: pageSizes.first ?? letterPageSize)
        let renderer = UIGraphicsPDFRenderer(bounds: bounds)

        return renderer.pdfData { context in
            for (index, size) in pageSizes.enumerated() {
                context.beginPage(
                    withBounds: CGRect(origin: .zero, size: size),
                    pageInfo: [:]
                )
                guard contentPageIndexes.contains(index) else {
                    continue
                }
                UIColor.black.setFill()
                UIBezierPath(rect: CGRect(
                    x: size.width * 0.1,
                    y: size.height * 0.1,
                    width: size.width * 0.8,
                    height: size.height * 0.2
                )).fill()
            }
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: baseURL)
    }
}
