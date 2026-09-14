import Foundation
import Testing
@testable import ImmersiveReader

struct ReaderTextSourceMapTests {
    @Test
    func legacySingleParagraphMigratesToTheSameLineAfterChapterDetection() throws {
        let source = "第一章 开始\r\n　　第一段。\r\n　　第二段😀文字。\r\n第二章 继续\r\n结尾。"
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n")
        let offset = (normalized as NSString).range(of: "😀文字").location
        let blocks = ReaderSemanticParser.parse(source, format: .plainText)
        let map = ReaderTextSourceMap(source: source, blocks: blocks)
        let restored = try #require(map.migrate(.init(blockIndex: 0, offsetInBlock: offset)))
        #expect(restored.blockIndex == 2)
        #expect((blocks[restored.blockIndex].text as NSString).substring(from: restored.offsetInBlock) == "😀文字。")
    }

    @Test
    func legacyLongParagraphMigratesAcrossHardSplits() throws {
        let source = String(repeating: "字", count: 20_000)
        let blocks = ReaderSemanticParser.parse(source, format: .plainText)
        let map = ReaderTextSourceMap(source: source, blocks: blocks)
        #expect(map.migrate(.init(blockIndex: 0, offsetInBlock: 16_025)) == .init(blockIndex: 2, offsetInBlock: 25))
        #expect(map.migrate(.init(blockIndex: 99, offsetInBlock: 0)) == nil)
    }

    @Test
    func oldVersionRemainsDecodableAndMarkedForMigration() throws {
        let data = Data(#"{"version":1,"anchor":{"blockIndex":2,"offsetInBlock":7},"progress":0.4}"#.utf8)
        let location = try #require(TextReadingLocation.restore(from: data))
        #expect(location.semanticVersion == 1)
        #expect(location.anchor == .init(blockIndex: 2, offsetInBlock: 7))
        #expect(TextReadingLocation.restore(from: location.encoded()) == location)
    }

    @Test
    func malformedNegativePersistedAnchorsCannotIndexBeforeTheDocument() throws {
        let data = Data(#"{"version":2,"anchor":{"blockIndex":-10,"offsetInBlock":-5},"progress":0}"#.utf8)
        let restored = try #require(TextReadingLocation.restore(from: data))
        #expect(restored.anchor == .init(blockIndex: 0, offsetInBlock: 0))
        let segmentation = ReaderTextSegmentation(blocks: [.paragraph("safe")])
        #expect(segmentation.progress(for: restored.anchor) == 0)
    }
}
