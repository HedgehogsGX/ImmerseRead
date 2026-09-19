import Foundation
import PDFKit
import Testing
import UIKit
@testable import ImmerseRead

@MainActor
struct PDFColorExtractionTests {
    @Test
    func keepsSpeakerColorsWithoutColoringDialogueOrMergingSpeakers() async throws {
        let fixture = try PDFColorFixture()
        defer { fixture.remove() }
        // These are deliberately invented names and colors. A speaker has no
        // colon, and the next speaker starts at an ordinary wrapped-line distance.
        let document = try makePDF(pages: [[
            Line("若禾    门口的灯还亮着。", y: 48, marks: [Mark("若禾", red)]),
            Line("我们可以再等一会儿。", y: 70),
            Line("景舟    我听见了脚步声。", y: 92, marks: [Mark("景舟", blue)]),
            Line("这一句属于单独的旁白。", y: 154),
        ]], in: fixture.directory)

        let result = try await PDFTextExtractor().extract(document: document)
        let paragraphs = paragraphContents(of: result)
        let firstSpeaker = try #require(paragraphs.first { $0.text.contains("若禾") })
        let secondSpeaker = try #require(paragraphs.first { $0.text.contains("景舟") })
        let narration = try #require(paragraphs.first { $0.text.contains("单独的旁白") })

        #expect(result.pageCount == 1)
        #expect(result.pagesWithoutText.isEmpty)
        #expect(firstSpeaker.text.contains("门口的灯还亮着。"))
        #expect(firstSpeaker.text.contains("我们可以再等一会儿。"))
        #expect(!firstSpeaker.text.contains("景舟"))
        #expect(secondSpeaker.text.contains("我听见了脚步声。"))
        #expect(!secondSpeaker.text.contains("单独的旁白"))
        #expect(narration.text == "这一句属于单独的旁白。")
        #expect(narration.styles.isEmpty)
        try expectOnlyWordsColored(firstSpeaker, words: ["若禾": redComponents])
        try expectOnlyWordsColored(secondSpeaker, words: ["景舟": blueComponents])
    }

    @Test
    func preservesColorsAcrossPagesAndOnHighlightedWordsNotJustNames() async throws {
        let fixture = try PDFColorFixture()
        defer { fixture.remove() }
        let document = try makePDF(pages: [
            [Line("若禾    风从走廊来。", y: 48, marks: [Mark("若禾", red)])],
            [
                Line("景舟    我听见了回声。", y: 48, marks: [
                    Mark("景舟", blue), Mark("回声", red),
                ]),
                Line("若禾    接下来的话没有改变颜色。", y: 92, marks: [Mark("若禾", red)]),
            ],
        ], in: fixture.directory)

        let result = try await PDFTextExtractor().extract(document: document)
        let paragraphs = paragraphContents(of: result)
        let firstPage = try #require(paragraphs.first { $0.text.contains("风从走廊来") })
        let secondPage = try #require(paragraphs.first { $0.text.contains("我听见了回声") })
        let repeatedSpeaker = try #require(paragraphs.first { $0.text.contains("接下来的话") })

        #expect(result.pageCount == 2)
        #expect(result.pagesWithoutText.isEmpty)
        #expect(!firstPage.text.contains("景舟"))
        #expect(!secondPage.text.contains("接下来的话"))
        try expectOnlyWordsColored(firstPage, words: ["若禾": redComponents])
        try expectOnlyWordsColored(secondPage, words: [
            "景舟": blueComponents, "回声": redComponents,
        ])
        try expectOnlyWordsColored(repeatedSpeaker, words: ["若禾": redComponents])
    }

    @Test
    func neutralPDFInkRemainsThemeDrivenRatherThanBecomingBlackOrWhiteOverrides() async throws {
        let fixture = try PDFColorFixture()
        defer { fixture.remove() }
        let document = try makePDF(pages: [[
            Line("Black body remains readable.", y: 48),
            Line("White body remains readable.", y: 100, ink: .white, background: .black),
            Line("Gray body remains readable.", y: 152, ink: UIColor(white: 0.45, alpha: 1)),
        ]], in: fixture.directory)

        let result = try await PDFTextExtractor().extract(document: document)
        let paragraphs = paragraphContents(of: result)
        let text = paragraphs.map(\.text).joined(separator: "\n")

        #expect(text.contains("Black body remains readable."))
        #expect(text.contains("White body remains readable."))
        #expect(text.contains("Gray body remains readable."))
        #expect(paragraphs.allSatisfy { $0.styles.isEmpty })
        #expect(result.textContent.blocks.allSatisfy { block in
            if case .paragraph = block { return true }
            return false
        })
    }

    @Test
    func remapsColorOffsetsAfterEmojiPrefixesAndWhitespaceCleanup() throws {
        let source = NSMutableAttributedString(
            string: "  🧭   青禾    你好。\n换行后是正文。",
            attributes: [.foregroundColor: UIColor.black]
        )
        source.addAttribute(
            .foregroundColor,
            value: blue,
            range: (source.string as NSString).range(of: "青禾")
        )

        let paragraphs = try PDFStyledTextNormalizer.paragraphs(from: source)
        let paragraph = try #require(paragraphs.first)

        #expect(paragraphs.count == 1)
        #expect(paragraph.text == "🧭 青禾 你好。换行后是正文。")
        try expectOnlyWordsColored(paragraph, words: ["青禾": blueComponents])
        let nameRange = (paragraph.text as NSString).range(of: "青禾")
        #expect(nameRange.location == 3) // Emoji occupies two UTF-16 code units.
        #expect(paragraph.styles.first?.range == nameRange)
    }

    @Test
    func removingASoftHyphenKeepsTheJoinedWordColoredWithoutBleedingIntoBody() throws {
        let source = NSMutableAttributedString(
            string: "🧭   extra\u{00AD}\nordinary    words stay neutral.",
            attributes: [.foregroundColor: UIColor.black]
        )
        source.addAttribute(
            .foregroundColor,
            value: red,
            range: (source.string as NSString).range(of: "extra\u{00AD}\nordinary")
        )

        let paragraphs = try PDFStyledTextNormalizer.paragraphs(from: source)
        let paragraph = try #require(paragraphs.first)

        #expect(paragraphs.count == 1)
        #expect(paragraph.text == "🧭 extraordinary words stay neutral.")
        try expectOnlyWordsColored(paragraph, words: ["extraordinary": redComponents])
    }

    @Test
    func anInlineColoredWordAfterAWrapDoesNotBecomeANewSpeakerParagraph() throws {
        let source = NSMutableAttributedString(
            string: "她提到了非常重要的\n线索，并继续往下说。",
            attributes: [.foregroundColor: UIColor.black]
        )
        source.addAttribute(
            .foregroundColor,
            value: red,
            range: (source.string as NSString).range(of: "线索")
        )

        let paragraphs = try PDFStyledTextNormalizer.paragraphs(from: source)
        let paragraph = try #require(paragraphs.first)

        #expect(paragraphs.count == 1)
        #expect(paragraph.text == "她提到了非常重要的线索，并继续往下说。")
        try expectOnlyWordsColored(paragraph, words: ["线索": redComponents])
    }

    @Test
    func aUniformlyColoredParagraphKeepsOrdinaryWrappedLinesTogether() throws {
        let source = NSAttributedString(
            string: "这一整段都使用同一种颜色，\n换行之后也仍然属于同一个段落。",
            attributes: [.foregroundColor: blue]
        )

        let paragraphs = try PDFStyledTextNormalizer.paragraphs(from: source)
        let paragraph = try #require(paragraphs.first)

        #expect(paragraphs.count == 1)
        #expect(paragraph.text == "这一整段都使用同一种颜色，换行之后也仍然属于同一个段落。")
        try expectOnlyWordsColored(paragraph, words: [paragraph.text: blueComponents])
    }

    @Test
    func indentedDialogueKeepsItsContinuationAndLonePunctuationOnAMixedMarginPDFPage() async throws {
        let fixture = try PDFColorFixture()
        defer { fixture.remove() }
        // Narration and dialogue intentionally use different left margins.
        // A stable dialogue indent is not a new paragraph on every physical line.
        let document = try makePDF(pages: [[
            Line("他站在门边，四周一片安静。", x: 51, y: 48),
            Line("青禾    我还有一些事情想告诉你", x: 63, y: 92, marks: [Mark("青禾", red)]),
            Line("这些都是同一段里接着说的话", x: 63, y: 114),
            Line("！", x: 63, y: 136),
            Line("说完以后，走廊又安静下来。", x: 51, y: 188),
        ]], in: fixture.directory)

        let result = try await PDFTextExtractor().extract(document: document)
        let paragraphs = paragraphContents(of: result)
        let dialogue = try #require(paragraphs.first { $0.text.contains("青禾") })

        #expect(paragraphs.map(\.text) == [
            "他站在门边，四周一片安静。",
            "青禾 我还有一些事情想告诉你这些都是同一段里接着说的话！",
            "说完以后，走廊又安静下来。",
        ])
        #expect(!paragraphs.contains { $0.text == "！" })
        try expectOnlyWordsColored(dialogue, words: ["青禾": redComponents])
    }

    @Test
    func styleRunLimitRejectsTwoColorsOnOnePageAndCumulativeColorsAcrossPages() async throws {
        let fixture = try PDFColorFixture()
        defer { fixture.remove() }
        let extractor = PDFTextExtractor(maximumStyleRunCount: 1)
        let oneRunPerPage = [
            [Line("甲色    后面是普通正文。", y: 48, marks: [Mark("甲色", red)])],
            [Line("乙色    这里同样只有一个颜色片段。", y: 48, marks: [Mark("乙色", blue)])],
        ]
        // Prove that each individual page is within budget before checking the
        // cumulative case; otherwise a per-page failure could hide a missing
        // document-wide guard.
        for page in oneRunPerPage {
            let singlePage = try makePDF(pages: [page], in: fixture.directory)
            let result = try await extractor.extract(document: singlePage)
            #expect(result.textContent.blocks.count == 1)
        }
        let samePage = try makePDF(pages: [[
            Line("甲色    乙色    后面是普通正文。", y: 48, marks: [
                Mark("甲色", red), Mark("乙色", blue),
            ]),
        ]], in: fixture.directory)
        let differentPages = try makePDF(pages: oneRunPerPage, in: fixture.directory)

        for document in [samePage, differentPages] {
            await #expect(throws: PDFTextExtractionError.tooManyStyleRuns(maximumRuns: 1)) {
                try await extractor.extract(document: document)
            }
        }
    }

    @Test
    func keepsExplicitParagraphBreaksAndUsesLocalColorRangesInEachParagraph() throws {
        let source = NSMutableAttributedString(
            string: "青禾  第一段。\r\n\r\n\u{3000}景舟  第二段。\u{2029}末尾的旁白。",
            attributes: [.foregroundColor: UIColor.black]
        )
        source.addAttribute(
            .foregroundColor,
            value: red,
            range: (source.string as NSString).range(of: "青禾")
        )
        source.addAttribute(
            .foregroundColor,
            value: blue,
            range: (source.string as NSString).range(of: "景舟")
        )

        let paragraphs = try PDFStyledTextNormalizer.paragraphs(from: source)

        #expect(paragraphs.map(\.text) == ["青禾 第一段。", "景舟 第二段。", "末尾的旁白。"])
        guard paragraphs.count == 3 else { return }
        try expectOnlyWordsColored(paragraphs[0], words: ["青禾": redComponents])
        try expectOnlyWordsColored(paragraphs[1], words: ["景舟": blueComponents])
        #expect(paragraphs[0].styles.first?.range.location == 0)
        #expect(paragraphs[1].styles.first?.range.location == 0)
        #expect(paragraphs[2].styles.isEmpty)
    }

    @Test
    func styledParagraphExtractionStillHonorsTheParagraphLimit() {
        let source = NSAttributedString(
            string: "第一段。\n\n第二段。\n\n第三段。",
            attributes: [.foregroundColor: blue]
        )

        #expect(throws: PDFTextExtractionError.tooManyParagraphs(maximumParagraphs: 2)) {
            try PDFStyledTextNormalizer.paragraphs(from: source, maximumParagraphCount: 2)
        }
    }

    private var red: UIColor {
        UIColor(red: 0.72, green: 0.19, blue: 0.28, alpha: 1)
    }

    private var blue: UIColor {
        UIColor(red: 0.16, green: 0.37, blue: 0.75, alpha: 1)
    }

    private var redComponents: ReaderTextColor {
        ReaderTextColor(red: 0.72, green: 0.19, blue: 0.28)
    }

    private var blueComponents: ReaderTextColor {
        ReaderTextColor(red: 0.16, green: 0.37, blue: 0.75)
    }

    private func paragraphContents(of result: PDFReflowContent) -> [ReaderStyledText] {
        result.textContent.blocks.compactMap { block in
            switch block {
            case .paragraph(let text):
                ReaderStyledText(text: text, styles: [])
            case .styledParagraph(let text):
                text
            default:
                nil
            }
        }
    }

    private func expectOnlyWordsColored(
        _ paragraph: ReaderStyledText,
        words: [String: ReaderTextColor]
    ) throws {
        let text = paragraph.text as NSString
        var actual = [ReaderTextColor?](repeating: nil, count: text.length)
        var expected = actual

        for span in paragraph.styles {
            let validRange = span.range.location >= 0
                && span.range.location <= text.length
                && span.range.length > 0
                && span.range.length <= text.length - span.range.location
            #expect(validRange)
            guard validRange else { continue }
            for offset in span.range.location ..< NSMaxRange(span.range) {
                actual[offset] = span.color
            }
        }
        for (word, color) in words {
            let range = text.range(of: word)
            try #require(range.location != NSNotFound)
            for offset in range.location ..< NSMaxRange(range) {
                expected[offset] = color
            }
        }

        for offset in 0 ..< text.length {
            // PDFKit may synthesize inter-run spaces using the previous run's
            // attributes. Their invisible color is immaterial; visible body text
            // must never inherit a speaker's source color.
            if let scalar = UnicodeScalar(text.character(at: offset)),
               CharacterSet.whitespacesAndNewlines.contains(scalar) {
                continue
            }
            switch (actual[offset], expected[offset]) {
            case (.none, .none):
                break
            case (.some(let actualColor), .some(let expectedColor)):
                // PDF producers and PDFKit can round device-RGB components.
                #expect(abs(actualColor.red - expectedColor.red) < 0.02)
                #expect(abs(actualColor.green - expectedColor.green) < 0.02)
                #expect(abs(actualColor.blue - expectedColor.blue) < 0.02)
                #expect(abs(actualColor.alpha - expectedColor.alpha) < 0.02)
            default:
                Issue.record("Unexpected source color at UTF-16 offset \(offset) in \(paragraph.text)")
            }
        }
    }

    private func makePDF(pages: [[Line]], in directory: URL) throws -> ReaderDocument {
        let bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        let renderer = UIGraphicsPDFRenderer(bounds: bounds)
        let data = renderer.pdfData { context in
            for lines in pages {
                context.beginPage()
                for line in lines {
                    if let background = line.background {
                        context.cgContext.setFillColor(background.cgColor)
                        context.cgContext.fill(CGRect(
                            x: line.x - 8, y: line.y - 4, width: bounds.width - line.x - 24, height: 30
                        ))
                    }
                    let attributed = NSMutableAttributedString(
                        string: line.text,
                        attributes: [.font: UIFont.systemFont(ofSize: 18), .foregroundColor: line.ink]
                    )
                    for mark in line.marks {
                        let range = (line.text as NSString).range(of: mark.word)
                        precondition(range.location != NSNotFound)
                        attributed.addAttribute(.foregroundColor, value: mark.color, range: range)
                    }
                    attributed.draw(at: CGPoint(x: line.x, y: line.y))
                }
            }
        }
        let fileURL = directory.appendingPathComponent("colored-dialogue-\(UUID().uuidString).pdf")
        try data.write(to: fileURL, options: .atomic)
        return ReaderDocument(id: UUID(), title: "Colored dialogue fixture", fileURL: fileURL, format: .pdf)
    }

    private struct Line {
        let text: String
        let x: CGFloat
        let y: CGFloat
        let marks: [Mark]
        let ink: UIColor
        let background: UIColor?

        init(
            _ text: String,
            x: CGFloat = 40,
            y: CGFloat,
            marks: [Mark] = [],
            ink: UIColor = .black,
            background: UIColor? = nil
        ) {
            self.text = text
            self.x = x
            self.y = y
            self.marks = marks
            self.ink = ink
            self.background = background
        }
    }

    private struct Mark {
        let word: String
        let color: UIColor

        init(_ word: String, _ color: UIColor) {
            self.word = word
            self.color = color
        }
    }
}

private struct PDFColorFixture {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PDFColorExtractionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
