import Foundation
import PDFKit
import Testing
import UIKit
@testable import ImmersiveReader

@MainActor
struct PDFTextExtractorTests {
    @Test
    func extractsReflowableTextFromARealPDF() async throws {
        let fixture = try PDFExtractionFixture()
        defer { fixture.remove() }
        let document = try makePDF(
            pages: [.text("A paragraph that reflows.\nThe reader can resize it.\n\n中文正文支持调节字号。")],
            in: fixture.directory
        )

        let result = try await PDFTextExtractor().extract(document: document)

        #expect(result.textContent.format == .pdf)
        #expect(result.pageCount == 1)
        #expect(result.pagesWithoutText.isEmpty)
        let text = bodyText(of: result)
        #expect(text.contains("A paragraph that reflows. The reader can resize it."))
        #expect(text.contains("中文正文支持调节字号。"))
    }

    @Test
    func blankPDFReportsNoExtractableText() async throws {
        let fixture = try PDFExtractionFixture()
        defer { fixture.remove() }
        let document = try makePDF(pages: [.blank], in: fixture.directory)

        await #expect(throws: PDFTextExtractionError.noExtractableText) {
            try await PDFTextExtractor().extract(document: document)
        }
    }

    @Test
    func imageOnlyPDFIsNotMisrepresentedAsReadableText() async throws {
        let fixture = try PDFExtractionFixture()
        defer { fixture.remove() }
        let document = try makePDF(pages: [.image], in: fixture.directory)

        await #expect(throws: PDFTextExtractionError.noExtractableText) {
            try await PDFTextExtractor().extract(document: document)
        }
    }

    @Test
    func mixedPDFReportsEveryPageWithoutText() async throws {
        let fixture = try PDFExtractionFixture()
        defer { fixture.remove() }
        let document = try makePDF(
            pages: [.text("First page."), .blank, .image, .text("Last page.")],
            in: fixture.directory
        )

        let result = try await PDFTextExtractor().extract(document: document)

        #expect(result.pageCount == 4)
        #expect(result.pagesWithoutText == [2, 3])
        #expect(result.textContent.blocks == [.paragraph("First page."), .paragraph("Last page.")])
    }

    @Test
    func corruptPDFIsRejectedEvenWhenItsSignatureLooksValid() async throws {
        let fixture = try PDFExtractionFixture()
        defer { fixture.remove() }
        let fileURL = fixture.directory.appendingPathComponent("broken.pdf")
        try Data("%PDF-1.7\nThis is not a valid PDF document.".utf8).write(to: fileURL)

        await #expect(throws: PDFTextExtractionError.invalidDocument) {
            try await PDFTextExtractor().extract(document: makeDocument(at: fileURL))
        }
    }

    @Test
    func nonPDFDataAndEmptyFilesAreRejected() async throws {
        let fixture = try PDFExtractionFixture()
        defer { fixture.remove() }
        for data in [Data(), Data("plain text pretending to be PDF".utf8)] {
            let fileURL = fixture.directory.appendingPathComponent("\(UUID().uuidString).pdf")
            try data.write(to: fileURL)
            let document = makeDocument(at: fileURL)

            await #expect(throws: PDFTextExtractionError.invalidDocument) {
                try await PDFTextExtractor().extract(document: document)
            }
        }
    }

    @Test
    func checksFileSizeBeforeOpeningThePDF() async throws {
        let fixture = try PDFExtractionFixture()
        defer { fixture.remove() }
        let document = try makePDF(pages: [.text("A valid PDF.")], in: fixture.directory)

        await #expect(throws: PDFTextExtractionError.fileTooLarge(maximumBytes: 16)) {
            try await PDFTextExtractor(maximumFileSize: 16).extract(document: document)
        }
    }

    @Test
    func limitsExtractedUTF8BytesNotOnlyCharacterCount() async throws {
        let fixture = try PDFExtractionFixture()
        defer { fixture.remove() }
        let document = try makePDF(pages: [.text("中文正文")], in: fixture.directory)

        await #expect(throws: PDFTextExtractionError.extractedTextTooLarge(maximumBytes: 8)) {
            try await PDFTextExtractor(maximumExtractedUTF8Bytes: 8).extract(document: document)
        }
    }

    @Test
    func enforcesTheTextBudgetAcrossPages() async throws {
        let fixture = try PDFExtractionFixture()
        defer { fixture.remove() }
        let document = try makePDF(
            pages: [.text("1234567890"), .text("1234567890")],
            in: fixture.directory
        )

        await #expect(throws: PDFTextExtractionError.extractedTextTooLarge(maximumBytes: 16)) {
            try await PDFTextExtractor(maximumExtractedUTF8Bytes: 16).extract(document: document)
        }
    }

    @Test
    func limitsPageCountEvenWhenPagesAreEmpty() async throws {
        let fixture = try PDFExtractionFixture()
        defer { fixture.remove() }
        let document = try makePDF(pages: [.blank, .blank], in: fixture.directory)

        await #expect(throws: PDFTextExtractionError.tooManyPages(maximumPages: 1)) {
            try await PDFTextExtractor(maximumPageCount: 1).extract(document: document)
        }
    }

    @Test
    func enforcesParagraphCountAcrossSourcePages() async throws {
        let fixture = try PDFExtractionFixture()
        defer { fixture.remove() }
        let document = try makePDF(
            pages: [.text("First paragraph."), .blank, .text("Second paragraph."), .text("Third paragraph.")],
            in: fixture.directory
        )

        await #expect(throws: PDFTextExtractionError.tooManyParagraphs(maximumParagraphs: 2)) {
            try await PDFTextExtractor(maximumParagraphCount: 2).extract(document: document)
        }
    }

    @Test
    func acceptsExactlyTheParagraphLimitAndStillReportsBlankPages() async throws {
        let fixture = try PDFExtractionFixture()
        defer { fixture.remove() }
        let document = try makePDF(
            pages: [.text("First paragraph."), .blank, .text("Second paragraph."), .blank],
            in: fixture.directory
        )

        let result = try await PDFTextExtractor(maximumParagraphCount: 2).extract(document: document)

        #expect(result.textContent.blocks == [.paragraph("First paragraph."), .paragraph("Second paragraph.")])
        #expect(result.pagesWithoutText == [2, 4])
    }

    @Test
    func refusesPasswordProtectedPDFs() async throws {
        let fixture = try PDFExtractionFixture()
        defer { fixture.remove() }
        let document = try makePDF(
            pages: [.text("Private text.")],
            in: fixture.directory,
            documentInfo: [
                kCGPDFContextOwnerPassword as String: "fixture-owner",
                kCGPDFContextUserPassword as String: "fixture-reader",
            ]
        )
        let pdfDocument = try #require(PDFDocument(url: document.fileURL))
        #expect(pdfDocument.isLocked)

        await #expect(throws: PDFTextExtractionError.passwordProtected) {
            try await PDFTextExtractor().extract(document: document)
        }
    }

    @Test
    func respectsCopyRestrictionsOnUnlockedPDFs() async throws {
        let fixture = try PDFExtractionFixture()
        defer { fixture.remove() }
        let document = try makePDF(
            pages: [.text("Restricted text.")],
            in: fixture.directory,
            documentInfo: [
                kCGPDFContextOwnerPassword as String: "fixture-owner",
                kCGPDFContextAllowsCopying as String: false,
            ]
        )
        let pdfDocument = try #require(PDFDocument(url: document.fileURL))
        #expect(!pdfDocument.isLocked)
        #expect(!pdfDocument.allowsCopying)

        await #expect(throws: PDFTextExtractionError.copyingNotAllowed) {
            try await PDFTextExtractor().extract(document: document)
        }
    }

    @Test
    func rejectsDirectoriesAndSymbolicLinks() async throws {
        let fixture = try PDFExtractionFixture()
        defer { fixture.remove() }
        let document = try makePDF(pages: [.text("A real document.")], in: fixture.directory)
        let link = fixture.directory.appendingPathComponent("linked.pdf")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: document.fileURL)

        for fileURL in [fixture.directory, link] {
            let invalidDocument = makeDocument(at: fileURL)
            await #expect(throws: PDFTextExtractionError.notARegularFile) {
                try await PDFTextExtractor().extract(document: invalidDocument)
            }
        }
    }

    @Test
    func refusesRemoteURLsAndUnsupportedFormats() async throws {
        let remoteDocument = ReaderDocument(
            id: UUID(),
            title: "Remote",
            fileURL: try #require(URL(string: "https://example.com/document.pdf")),
            format: .pdf
        )
        await #expect(throws: PDFTextExtractionError.notARegularFile) {
            try await PDFTextExtractor().extract(document: remoteDocument)
        }

        let unsupportedDocument = ReaderDocument(
            id: UUID(),
            title: "Not PDF",
            fileURL: URL(fileURLWithPath: "/tmp/nonexistent.txt"),
            format: .plainText
        )
        await #expect(throws: PDFTextExtractionError.unsupportedFormat(.plainText)) {
            try await PDFTextExtractor().extract(document: unsupportedDocument)
        }
    }

    @Test
    func propagatesTaskCancellation() async throws {
        let fixture = try PDFExtractionFixture()
        defer { fixture.remove() }
        let document = try makePDF(pages: [.text("Cancelable text.")], in: fixture.directory)
        let task = Task {
            try await PDFTextExtractor().extract(document: document)
        }
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }

    @Test
    func joinsChineseHardLineBreaksWithoutInventedSpaces() throws {
        let paragraphs = try PDFTextNormalizer.paragraphs(
            from: "  阅读应该跟随\n你的字号设置。\n翻到下一行，\n仍然是同一段。\n\n新的段落保留。"
        )

        #expect(paragraphs == [
            "阅读应该跟随你的字号设置。翻到下一行，仍然是同一段。",
            "新的段落保留。",
        ])
    }

    @Test
    func joinsEnglishHardLineBreaksAndKeepsParagraphs() throws {
        let paragraphs = try PDFTextNormalizer.paragraphs(
            from: "  An English\r\nparagraph with\r\nseveral lines.  \r\n\r\nA\t second    paragraph."
        )

        #expect(paragraphs == [
            "An English paragraph with several lines.",
            "A second paragraph.",
        ])
    }

    @Test
    func preservesVisibleHyphensAndRemovesDiscretionaryHyphens() throws {
        let paragraphs = try PDFTextNormalizer.paragraphs(
            from: "A well-\nknown extra\u{00AD}\nordinary example (\nwith punctuation\n)."
        )

        #expect(paragraphs == ["A well-known extraordinary example (with punctuation)."])
    }

    @Test
    func keepsUnicodeParagraphSeparatorsAndIgnoresEmptyArtifacts() throws {
        let paragraphs = try PDFTextNormalizer.paragraphs(
            from: "\u{FEFF}第一行\u{2028}第二行\u{2029}下一段\u{000C}\0\u{200B}\u{00AD}"
        )

        #expect(paragraphs == ["第一行第二行", "下一段"])
    }

    @Test
    func rejectsTooManyParagraphsWithinOnePageOutput() {
        let onePageOutput = "First paragraph.\n\nSecond paragraph.\n\nThird paragraph."

        #expect(throws: PDFTextExtractionError.tooManyParagraphs(maximumParagraphs: 2)) {
            try PDFTextNormalizer.paragraphs(from: onePageOutput, maximumParagraphCount: 2)
        }
    }

    @Test
    func reflowsBooksWellPastTheOldTwentyThousandParagraphLimit() throws {
        let longBook = String(repeating: "这是一段正文。\n\n", count: 60_000)

        // Default limits: this is what a long PDF gets when it is opened for
        // reading, and it used to fail at 20,000 paragraphs.
        let paragraphs = try PDFTextNormalizer.paragraphs(from: longBook)

        #expect(paragraphs.count == 60_000)
    }

    @Test
    func rejectsTinyParagraphFloodsWithASmallLimit() {
        let manyTinyParagraphs = String(repeating: "x\n\n", count: 100_000)

        #expect(throws: PDFTextExtractionError.tooManyParagraphs(maximumParagraphs: 3)) {
            try PDFTextNormalizer.paragraphs(from: manyTinyParagraphs, maximumParagraphCount: 3)
        }
    }

    @Test
    func normalizesVeryLongLinesWithoutLosingContent() throws {
        let longLine = String(repeating: "阅读正文abc", count: 10_000)

        #expect(try PDFTextNormalizer.paragraphs(from: longLine) == [longLine])
    }

    private func bodyText(of result: PDFReflowContent) -> String {
        result.textContent.blocks.compactMap { block in
            if case .paragraph(let text) = block { return text }
            return nil
        }.joined(separator: "\n\n")
    }

    private func makeDocument(at fileURL: URL) -> ReaderDocument {
        ReaderDocument(id: UUID(), title: "PDF fixture", fileURL: fileURL, format: .pdf)
    }

    private func makePDF(
        pages: [Page],
        in directory: URL,
        documentInfo: [String: Any] = [:]
    ) throws -> ReaderDocument {
        let bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = documentInfo
        let renderer = UIGraphicsPDFRenderer(bounds: bounds, format: format)
        let data = renderer.pdfData { context in
            for page in pages {
                context.beginPage()
                switch page {
                case .text(let text):
                    (text as NSString).draw(
                        in: bounds.insetBy(dx: 36, dy: 36),
                        withAttributes: [.font: UIFont.systemFont(ofSize: 18)]
                    )
                case .image:
                    let image = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 240)).image {
                        imageContext in
                        UIColor.white.setFill()
                        imageContext.fill(CGRect(x: 0, y: 0, width: 400, height: 240))
                        ("A scanned image of text." as NSString).draw(
                            at: CGPoint(x: 24, y: 40),
                            withAttributes: [.font: UIFont.systemFont(ofSize: 22)]
                        )
                    }
                    image.draw(in: CGRect(x: 36, y: 36, width: 400, height: 240))
                case .blank:
                    break
                }
            }
        }
        let fileURL = directory.appendingPathComponent("\(UUID().uuidString).pdf")
        try data.write(to: fileURL, options: .atomic)
        return makeDocument(at: fileURL)
    }

    private enum Page {
        case text(String)
        case image
        case blank
    }
}

private struct PDFExtractionFixture {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PDFTextExtractorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
