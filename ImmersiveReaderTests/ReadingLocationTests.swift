import Foundation
import Testing
import UIKit
@testable import ImmersiveReader

struct ReadingLocationTests {
    private let blockRanges = [
        NSRange(location: 0, length: 10),
        NSRange(location: 10, length: 25),
        NSRange(location: 35, length: 5),
    ]

    @Test
    func anchorsRoundTripThroughBlockRanges() {
        for offset in [0, 9, 10, 22, 34, 35, 39] {
            let anchor = ReaderTextPosition.anchor(forCharacterOffset: offset, blockRanges: blockRanges)
            #expect(ReaderTextPosition.characterOffset(for: anchor, blockRanges: blockRanges) == offset)
        }

        let middle = ReaderTextPosition.anchor(forCharacterOffset: 22, blockRanges: blockRanges)
        #expect(middle == ReaderTextAnchor(blockIndex: 1, offsetInBlock: 12))
    }

    @Test
    func anchorsOutsideTheDocumentClampToTheNearestBlock() {
        let pastEnd = ReaderTextPosition.anchor(forCharacterOffset: 500, blockRanges: blockRanges)
        #expect(pastEnd.blockIndex == 2)
        #expect(ReaderTextPosition.characterOffset(for: pastEnd, blockRanges: blockRanges) == 39)

        let missingBlock = ReaderTextAnchor(blockIndex: 40, offsetInBlock: 3)
        #expect(ReaderTextPosition.characterOffset(for: missingBlock, blockRanges: blockRanges) == 38)

        let shorterBlock = ReaderTextAnchor(blockIndex: 0, offsetInBlock: 99)
        #expect(ReaderTextPosition.characterOffset(for: shorterBlock, blockRanges: blockRanges) == 9)

        #expect(ReaderTextPosition.characterOffset(for: missingBlock, blockRanges: []) == 0)
        #expect(ReaderTextPosition.anchor(forCharacterOffset: 5, blockRanges: []) == ReaderTextAnchor(blockIndex: 0, offsetInBlock: 0))
        #expect(ReaderTextAnchor(blockIndex: -3, offsetInBlock: -1) == ReaderTextAnchor(blockIndex: 0, offsetInBlock: 0))
    }

    @Test @MainActor
    func rendererBlockRangesCoverTheWholeStringInOrder() {
        let content = ReaderTextContent(format: .markdown, blocks: [
            .heading(level: 1, text: "标题"),
            .paragraph("第一段 **强调** 文字。"),
            .unorderedListItem(depth: 0, text: "条目"),
            .code("let x = 1"),
            .divider,
        ])

        let rendered = ReaderTextRenderer.render(content, settings: .default)
        let ranges = rendered.blockRanges

        #expect(ranges.count == content.blocks.count)
        #expect(ranges.first?.location == 0)
        #expect(ranges.last.map(NSMaxRange) == rendered.attributedString.length)
        for (previous, next) in zip(ranges, ranges.dropFirst()) {
            #expect(NSMaxRange(previous) == next.location)
        }
        #expect(rendered.attributedString.attributedSubstring(from: ranges[0]).string == "标题\n")
        #expect(rendered.attributedString.attributedSubstring(from: ranges[2]).string == "•\t条目\n")
    }

    @Test @MainActor
    func anchorsSurviveTypographyChangesWhereProgressFractionsDrift() {
        let content = ReaderTextContent(format: .plainText, blocks: (0..<40).map { index in
            .paragraph(String(repeating: "第 \(index) 段的正文。", count: 6))
        })
        let small = ReaderTextRenderer.render(
            content,
            settings: ReaderDisplaySettings(fontSize: 14, lineHeightMultiple: 1.2)
        )
        let offset = small.blockRanges[17].location + 8
        let anchor = ReaderTextPosition.anchor(forCharacterOffset: offset, blockRanges: small.blockRanges)

        let large = ReaderTextRenderer.render(
            content,
            settings: ReaderDisplaySettings(fontSize: 40, lineHeightMultiple: 2)
        )
        let restored = ReaderTextPosition.characterOffset(for: anchor, blockRanges: large.blockRanges)
        #expect(restored == large.blockRanges[17].location + 8)
        #expect(
            large.attributedString.attributedSubstring(from: NSRange(location: restored, length: 3)).string
                == small.attributedString.attributedSubstring(from: NSRange(location: offset, length: 3)).string
        )
    }

    @Test
    func textLocationEncodesWithAVersionAndRejectsForeignPayloads() throws {
        let location = TextReadingLocation(
            anchor: ReaderTextAnchor(blockIndex: 4, offsetInBlock: 12),
            progress: 1.7
        )
        let data = try #require(location.encoded())
        let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(payload["version"] as? Int == 2)
        #expect(location.progress == 1)
        #expect(TextReadingLocation.restore(from: data) == location)

        #expect(TextReadingLocation.restore(from: nil) == nil)
        #expect(TextReadingLocation.restore(from: Data("garbage".utf8)) == nil)
        #expect(TextReadingLocation.restore(from: Data(#"{"version":99,"anchor":{"blockIndex":0,"offsetInBlock":0},"progress":0}"#.utf8)) == nil)
        // Another format's location must not be misread as a text location.
        #expect(TextReadingLocation.restore(from: PDFReadingLocation().encoded()) == nil)
        #expect(TextReadingLocation.restore(from: EPUBReadingLocation(locatorJSON: "{}", progress: 0).encoded()) == nil)
    }

    @Test
    func epubLocationRoundTripsLocatorJSON() throws {
        let locatorJSON = #"{"href":"chapter-2.xhtml","locations":{"progression":0.25,"totalProgression":0.6},"type":"application/xhtml+xml"}"#
        let location = EPUBReadingLocation(locatorJSON: locatorJSON, progress: 0.6)
        let data = try #require(location.encoded())

        #expect(EPUBReadingLocation.restore(from: data) == location)
        #expect(EPUBReadingLocation.restore(from: nil) == nil)
        #expect(EPUBReadingLocation.restore(from: TextReadingLocation(anchor: .init(blockIndex: 0, offsetInBlock: 0), progress: 0).encoded()) == nil)
        #expect(EPUBReadingLocation(locatorJSON: "{}", progress: .nan).progress == 0)
    }

    @Test
    func pdfLocationCarriesAReflowAnchorThatCoarseUpdatesClear() throws {
        var location = PDFReadingLocation()
        #expect(location.reflowLocation == nil)

        let anchor = ReaderTextAnchor(blockIndex: 7, offsetInBlock: 3)
        location.updateReflowLocation(TextReadingLocation(anchor: anchor, progress: 0.3))
        #expect(location.reflowProgress == 0.3)
        #expect(location.reflowLocation == TextReadingLocation(anchor: anchor, progress: 0.3))

        let data = try #require(location.encoded())
        let restored = PDFReadingLocation.restore(from: data, legacyOriginalProgress: 0)
        #expect(restored == location)
        #expect(restored.reflowLocation?.anchor == anchor)

        location.updateProgress(0.9, for: .original)
        #expect(location.reflowLocation?.anchor == anchor)

        location.updateProgress(0.5, for: .reflow)
        #expect(location.reflowLocation == nil)
        #expect(location.reflowProgress == 0.5)

        // Payloads saved before anchors existed still decode.
        let legacy = Data(#"{"version":1,"mode":"reflow","reflowProgress":0.42,"originalProgress":0.8}"#.utf8)
        let migrated = PDFReadingLocation.restore(from: legacy, legacyOriginalProgress: 0)
        #expect(migrated.reflowProgress == 0.42)
        #expect(migrated.reflowLocation == nil)
    }
}
