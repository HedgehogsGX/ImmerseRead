import Foundation
import Testing
import UIKit
@testable import ImmersiveReader

struct ReaderCoreTests {
    @Test
    func mapsImportedExtensionsToReaderFormats() {
        #expect(ReaderFormat(fileExtension: "EPUB") == .epub)
        #expect(ReaderFormat(fileExtension: ".pdf") == .pdf)
        #expect(ReaderFormat(fileExtension: "txt") == .plainText)
        #expect(ReaderFormat(fileExtension: "md") == .markdown)
        #expect(ReaderFormat(fileExtension: "MARKDOWN") == .markdown)
        #expect(ReaderFormat(fileExtension: "docx") == .docx)
        #expect(ReaderFormat(fileExtension: "doc") == .legacyWord)
        #expect(ReaderFormat(fileExtension: "rtf") == nil)
    }

    @Test
    func parsesPlainTextIntoParagraphsWithoutDiscardingLineBreaks() {
        let blocks = ReaderSemanticParser.parse(
            "第一行\n第二行\n\n第三段",
            format: .plainText
        )

        #expect(blocks == [
            .paragraph("第一行\n第二行"),
            .paragraph("第三段")
        ])
    }

    @Test
    func parsesCommonMarkdownBlocks() {
        let source = """
        # 标题

        正文含有 **强调**。

        - 第一项
        2. 第二项

        > 引用

        ---

        ```swift
        let answer = 42
        ```
        """

        let blocks = ReaderSemanticParser.parse(source, format: .markdown)

        #expect(blocks == [
            .heading(level: 1, text: "标题"),
            .paragraph("正文含有 **强调**。"),
            .unorderedListItem(depth: 0, text: "第一项"),
            .orderedListItem(depth: 0, ordinal: 2, text: "第二项"),
            .blockQuote("引用"),
            .divider,
            .code("let answer = 42")
        ])
    }

    @Test
    func textLoaderReadsUTF16WithBOM() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReaderCoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileURL = directory.appendingPathComponent("sample.txt")
        var data = Data([0xFF, 0xFE])
        data.append(try #require("第一段\n\n第二段".data(using: .utf16LittleEndian)))
        try data.write(to: fileURL, options: .atomic)

        let document = ReaderDocument(
            id: UUID(),
            title: "样例",
            fileURL: fileURL,
            format: .plainText
        )
        let content = try await LocalReaderTextLoader().load(document: document)

        #expect(content.blocks == [.paragraph("第一段"), .paragraph("第二段")])
    }

    @Test
    func textLoaderRejectsNonTextReaderFormats() async {
        let document = ReaderDocument(
            id: UUID(),
            title: "PDF",
            fileURL: URL(fileURLWithPath: "/tmp/example.pdf"),
            format: .pdf
        )

        await #expect(throws: ReaderTextLoadingError.unsupportedFormat(.pdf)) {
            try await LocalReaderTextLoader().load(document: document)
        }
    }

    @Test @MainActor
    func paginatorProducesContiguousRangesWithoutCopyingWholePages() async throws {
        let text = NSAttributedString(
            string: String(repeating: "一段用于分页的正文。", count: 600),
            attributes: [.font: UIFont.systemFont(ofSize: 18)]
        )
        let ranges = try await ReaderTextPaginator.pageRanges(
            from: text,
            contentSize: CGSize(width: 280, height: 420)
        )

        #expect(ranges.count > 1)
        #expect(ranges.first?.location == 0)
        #expect(ranges.last.map(NSMaxRange) == text.length)

        for (previous, next) in zip(ranges, ranges.dropFirst()) {
            #expect(NSMaxRange(previous) == next.location)
        }
    }

    @Test @MainActor
    func readerSettingsRoundTripThroughUserDefaults() throws {
        let suiteName = "ReaderSettingsStoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let expected = ReaderDisplaySettings(
            layoutMode: .scrolling,
            fontSize: 24,
            lineHeightMultiple: 1.8,
            theme: .sepia
        )

        ReaderSettingsStore.save(expected, to: defaults)

        #expect(ReaderSettingsStore.load(from: defaults) == expected)
    }

    @Test
    func PDFSupportsTextTypographyAndFontButtonsRespectBounds() {
        #expect(ReaderFormat.pdf.supportsTypography)
        #expect(!ReaderFormat.legacyWord.supportsTypography)

        var settings = ReaderDisplaySettings(fontSize: 19)
        settings.adjustFontSize(by: 1)
        #expect(settings.fontSize == 20)
        settings.adjustFontSize(by: 100)
        #expect(settings.fontSize == 40)
        settings.adjustFontSize(by: -100)
        #expect(settings.fontSize == 14)
        settings.fontSize = .nan
        settings.adjustFontSize(by: 1)
        #expect(settings.fontSize == 20)
    }

    @Test @MainActor
    func largeFontSettingsPersistAndInvalidSettingsAreClamped() throws {
        let suiteName = "ReaderFontRangeTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        ReaderSettingsStore.save(ReaderDisplaySettings(fontSize: 40), to: defaults)
        #expect(ReaderSettingsStore.load(from: defaults).fontSize == 40)

        ReaderSettingsStore.save(ReaderDisplaySettings(fontSize: 100), to: defaults)
        #expect(ReaderSettingsStore.load(from: defaults).fontSize == 40)

        ReaderSettingsStore.save(ReaderDisplaySettings(fontSize: 1), to: defaults)
        #expect(ReaderSettingsStore.load(from: defaults).fontSize == 14)
    }
}
