import Foundation
import Testing
import UIKit
@testable import ImmerseRead

struct ReaderLargeTextTests {
    @Test
    func textAboveTheOldEightMiBLimitLoadsInBoundedSegments() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("large.txt")
        let paragraph = String(repeating: "Local text. ", count: 200)
        let data = Data(String(repeating: paragraph + "\n\n", count: 4_000).utf8)
        #expect(data.count > 8 * 1_024 * 1_024)
        try data.write(to: url)
        let content = try await LocalReaderTextLoader().load(document: ReaderDocument(
            id: UUID(), title: "Large", fileURL: url, format: .plainText
        ))
        #expect(content.blocks.count == 4_000)
        let segmentation = ReaderTextSegmentation(blocks: content.blocks)
        #expect(segmentation.segments.count > 500)
        #expect(segmentation.segments.allSatisfy { segment in
            content.blocks[segment.blockRange].reduce(0) { $0 + $1.estimatedLength }
                < ReaderTextSegmentation.targetSegmentLength + ReaderSemanticParser.maximumParagraphLength + 1
        })
        #expect(content.sourceMap?.migrate(.init(blockIndex: 3_999, offsetInBlock: 150)) == .init(blockIndex: 3_999, offsetInBlock: 150))
    }

    @Test
    func filesBeyondTheNewLimitAreRejectedBeforeDecoding() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("oversized-\(UUID()).txt")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: url) }
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(DocumentFileLimits.plainTextMaximumBytes + 1))
        try handle.close()
        await #expect(throws: ReaderTextLoadingError.fileTooLarge(maximumBytes: LocalReaderTextLoader.maximumFileSize)) {
            try await LocalReaderTextLoader().load(document: ReaderDocument(
                id: UUID(), title: "Oversized", fileURL: url, format: .plainText
            ))
        }
    }

    @Test @MainActor
    func segmentLayoutsEvictOldTextInsteadOfRetainingTheBook() throws {
        let content = ReaderTextContent(format: .plainText, blocks: (0..<80).map { _ in
            .paragraph(String(repeating: "word ", count: 600))
        })
        let segmentation = ReaderTextSegmentation(blocks: content.blocks)
        let store = ReaderSegmentLayoutStore(
            content: content,
            segmentation: segmentation,
            request: ReaderLayoutRequest(settings: ReaderDisplaySettings(layoutMode: .scrolling), availableSize: CGSize(width: 390, height: 700))
        )
        for index in segmentation.segments.indices { _ = try store.layout(for: index) }
        let retained = segmentation.segments.indices.filter { store.cachedLayout(for: $0) != nil }
        #expect(retained.count == ReaderSegmentLayoutStore.retainedLayoutCount)
        #expect(retained.first == segmentation.segments.count - ReaderSegmentLayoutStore.retainedLayoutCount)
    }

    @Test
    func hardSplitsKeepSupplementaryCharactersIntact() {
        let source = String(repeating: "字", count: 7_999) + "😀" + String(repeating: "文", count: 9_000)
        let blocks = ReaderSemanticParser.parse(source, format: .plainText)
        #expect(blocks.map(\.text).joined() == source)
        #expect(blocks.allSatisfy { $0.text.utf16.count <= ReaderSemanticParser.maximumParagraphLength })
    }
}
