import Foundation
import Testing
import UIKit
@testable import ImmerseRead

struct ReaderContentCacheTests {
    @Test
    func cachedExtractionSkipsTheExtractorOnReopenAndStaysOutOfBackups() async throws {
        let fixture = try CacheFixture()
        defer { fixture.remove() }
        let document = try fixture.makePDF(text: "Cached body text that should only be extracted once.")
        let base = CountingExtractor()
        let extractor = CachingPDFTextExtractor(base: base, cache: ReaderContentCache())

        let first = try await extractor.extract(document: document)
        let second = try await extractor.extract(document: document)

        #expect(first == second)
        #expect(await base.invocationCount == 1)

        let cacheURL = fixture.directory.appendingPathComponent(CachingPDFTextExtractor.cacheKey.filename)
        let values = try cacheURL.resourceValues(forKeys: [.isExcludedFromBackupKey, .isRegularFileKey])
        #expect(values.isRegularFile == true)
        #expect(values.isExcludedFromBackup == true)

        // A fresh process still hits the cache.
        let reopened = CachingPDFTextExtractor(base: base, cache: ReaderContentCache())
        _ = try await reopened.extract(document: document)
        #expect(await base.invocationCount == 1)
    }

    @Test
    func changedSourceFilesAndOtherVersionsMissTheCache() async throws {
        let fixture = try CacheFixture()
        defer { fixture.remove() }
        let document = try fixture.makePDF(text: "Original text.")
        let cache = ReaderContentCache()
        let base = CountingExtractor()
        let extractor = CachingPDFTextExtractor(base: base, cache: cache)
        _ = try await extractor.extract(document: document)

        let otherVersion = ReaderContentCache.Key(kind: CachingPDFTextExtractor.cacheKey.kind, version: 999)
        #expect(await cache.load(PDFReflowContent.self, key: otherVersion, for: document) == nil)
        #expect(await cache.load(PDFReflowContent.self, key: CachingPDFTextExtractor.cacheKey, for: document) != nil)

        let replacement = try fixture.makePDF(text: "Replaced with different, longer text.", filename: "replacement.pdf")
        try FileManager.default.removeItem(at: document.fileURL)
        try FileManager.default.moveItem(at: replacement.fileURL, to: document.fileURL)

        let refreshed = try await extractor.extract(document: document)
        #expect(await base.invocationCount == 2)
        #expect(refreshed.textContent.blocks.contains(.paragraph("Replaced with different, longer text.")))
    }

    @Test
    func corruptCacheFilesAreIgnored() async throws {
        let fixture = try CacheFixture()
        defer { fixture.remove() }
        let document = try fixture.makePDF(text: "Body.")
        let cacheURL = fixture.directory.appendingPathComponent(CachingPDFTextExtractor.cacheKey.filename)
        try Data("{not json".utf8).write(to: cacheURL)

        let base = CountingExtractor()
        let content = try await CachingPDFTextExtractor(base: base, cache: ReaderContentCache()).extract(document: document)
        #expect(await base.invocationCount == 1)
        #expect(!content.textContent.blocks.isEmpty)
    }

    @Test
    func docxLoaderServesCachedBlocksWithoutRunningTheConverter() async throws {
        let fixture = try CacheFixture()
        defer { fixture.remove() }
        let fileURL = fixture.directory.appendingPathComponent("original.docx")
        try Data("not really a docx".utf8).write(to: fileURL)
        let document = ReaderDocument(id: UUID(), title: "DOCX", fileURL: fileURL, format: .docx)
        let cache = ReaderContentCache()
        let cached = ReaderTextContent(format: .docx, blocks: [
            .heading(level: 1, text: "第一章"),
            .paragraph("缓存中的正文。"),
        ])
        await cache.store(cached, key: DOCXReaderTextLoader.cacheKey, for: document)

        let loaded = try await DOCXReaderTextLoader(cache: cache).load(document: document)
        #expect(loaded == cached)
    }

    @Test
    func semanticBlocksRoundTripThroughJSONIncludingColorSpans() throws {
        let content = PDFReflowContent(
            textContent: ReaderTextContent(format: .pdf, blocks: [
                .heading(level: 2, text: "标题"),
                .paragraph("普通段落"),
                .styledParagraph(ReaderStyledText(
                    text: "青禾 说了一句话。",
                    styles: [ReaderTextStyleSpan(
                        range: NSRange(location: 0, length: 2),
                        color: ReaderTextColor(red: 0.62, green: 0.2, blue: 0.16, alpha: 0.9)
                    )]
                )),
                .unorderedListItem(depth: 1, text: "条目"),
                .orderedListItem(depth: 0, ordinal: 3, text: "第三"),
                .blockQuote("引用"),
                .code("let x = 1"),
                .divider,
            ]),
            pageCount: 12,
            pagesWithoutText: [3, 7]
        )

        let data = try JSONEncoder().encode(content)
        let decoded = try JSONDecoder().decode(PDFReflowContent.self, from: data)
        #expect(decoded == content)
    }
}

private actor CountingExtractor: PDFTextExtracting {
    private(set) var invocationCount = 0

    func extract(document: ReaderDocument) async throws -> PDFReflowContent {
        invocationCount += 1
        return try await PDFTextExtractor().extract(document: document)
    }
}

private struct CacheFixture {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReaderContentCacheTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }

    func makePDF(text: String, filename: String = "original.pdf") throws -> ReaderDocument {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
        let data = renderer.pdfData { context in
            context.beginPage()
            (text as NSString).draw(
                in: CGRect(x: 48, y: 60, width: 510, height: 600),
                withAttributes: [.font: UIFont.systemFont(ofSize: 14)]
            )
        }
        let fileURL = directory.appendingPathComponent(filename)
        try data.write(to: fileURL, options: .atomic)
        return ReaderDocument(id: UUID(), title: "PDF", fileURL: fileURL, format: .pdf)
    }
}
