import Foundation
import Testing
import UIKit
@testable import ImmersiveReader

struct ReaderTextSegmentationTests {
    @Test
    func bodyTextIsCutIntoContiguousSegmentsNearTheTargetLength() {
        let blocks = (0..<400).map { index in
            ReaderSemanticBlock.paragraph(String(repeating: "第\(index)段。", count: 40))
        }
        let segmentation = ReaderTextSegmentation(blocks: blocks)

        #expect(segmentation.segments.count > 1)
        #expect(segmentation.segments.first?.blockRange.lowerBound == 0)
        #expect(segmentation.segments.last?.blockRange.upperBound == blocks.count)
        for (previous, next) in zip(segmentation.segments, segmentation.segments.dropFirst()) {
            #expect(previous.blockRange.upperBound == next.blockRange.lowerBound)
        }
        for segment in segmentation.segments.dropLast() {
            let length = blocks[segment.blockRange].reduce(0) { $0 + $1.estimatedLength }
            #expect(length >= ReaderTextSegmentation.targetSegmentLength)
            #expect(length < ReaderTextSegmentation.targetSegmentLength + blocks[segment.blockRange.upperBound - 1].estimatedLength)
        }
        #expect(segmentation.totalLength == blocks.reduce(0) { $0 + $1.estimatedLength })
    }

    @Test
    func majorHeadingsStartSegmentsUnlessTheCurrentOneIsTiny() {
        let body = String(repeating: "正文。", count: 800)
        let blocks: [ReaderSemanticBlock] = [
            .heading(level: 1, text: "书名"),
            .paragraph("很短的前言。"),
            .heading(level: 2, text: "第一章"),
            .paragraph(body),
            .heading(level: 3, text: "小节"),
            .paragraph(body),
            .heading(level: 2, text: "第二章"),
            .paragraph(body),
        ]
        let segmentation = ReaderTextSegmentation(blocks: blocks)

        #expect(segmentation.segments.map(\.blockRange) == [0 ..< 6, 6 ..< 8])
        #expect(segmentation.segmentIndex(containingBlock: 0) == 0)
        #expect(segmentation.segmentIndex(containingBlock: 5) == 0)
        #expect(segmentation.segmentIndex(containingBlock: 6) == 1)
        #expect(segmentation.segmentIndex(containingBlock: 99) == 1)
    }

    @Test
    func progressAndAnchorsRoundTripOnTheEstimatedScale() {
        let blocks = (0..<50).map { ReaderSemanticBlock.paragraph(String(repeating: "\($0)", count: 100)) }
        let segmentation = ReaderTextSegmentation(blocks: blocks)

        let anchor = ReaderTextAnchor(blockIndex: 25, offsetInBlock: 50)
        let progress = segmentation.progress(for: anchor)
        let expectedOffset = blocks[..<25].reduce(0) { $0 + $1.estimatedLength } + 50
        #expect(progress == Double(expectedOffset) / Double(segmentation.totalLength))
        #expect(segmentation.anchor(forProgress: progress) == anchor)

        #expect(segmentation.progress(for: ReaderTextAnchor(blockIndex: 0, offsetInBlock: 0)) == 0)
        #expect(segmentation.progress(for: ReaderTextAnchor(blockIndex: 999, offsetInBlock: 999)) < 1)
        #expect(segmentation.anchor(forProgress: 0) == ReaderTextAnchor(blockIndex: 0, offsetInBlock: 0))
        #expect(segmentation.anchor(forProgress: 1).blockIndex == 49)
        #expect(ReaderTextSegmentation(blocks: []).isEmpty)
    }

    @Test @MainActor
    func layoutStoreLaysOutOneSegmentAtATimeAndMapsAnchorsBothWays() throws {
        let blocks = (0..<200).map { ReaderSemanticBlock.paragraph(String(repeating: "段落\($0)。", count: 30)) }
        let content = ReaderTextContent(format: .plainText, blocks: blocks)
        let segmentation = ReaderTextSegmentation(blocks: blocks)
        let request = ReaderLayoutRequest(
            settings: ReaderDisplaySettings(layoutMode: .paged, fontSize: 18),
            availableSize: CGSize(width: 390, height: 700)
        )
        let store = ReaderSegmentLayoutStore(content: content, segmentation: segmentation, request: request)
        #expect(store.segmentCount > 2)

        let anchor = ReaderTextAnchor(blockIndex: 120, offsetInBlock: 7)
        let position = try store.position(of: anchor)
        #expect(position.segmentIndex == segmentation.segmentIndex(containingBlock: 120))
        let layout = try store.layout(for: position.segmentIndex)
        #expect(!layout.pageRanges.isEmpty)
        #expect(store.anchor(in: layout, offset: position.offset) == anchor)
        #expect(store.cachedLayout(for: position.segmentIndex) != nil)
        #expect(store.cachedLayout(for: 0) == nil)

        store.reset(request: ReaderLayoutRequest(
            settings: ReaderDisplaySettings(layoutMode: .paged, fontSize: 30),
            availableSize: CGSize(width: 390, height: 700)
        ))
        #expect(store.cachedLayout(for: position.segmentIndex) == nil)
        let larger = try store.position(of: anchor)
        let largerLayout = try store.layout(for: larger.segmentIndex)
        #expect(largerLayout.pageRanges.count > layout.pageRanges.count)
        #expect(store.anchor(in: largerLayout, offset: larger.offset) == anchor)
    }

    @Test
    func plainTextWithoutBlankLinesTreatsEveryLineAsAParagraph() {
        let blocks = ReaderSemanticParser.parse(
            "　　第一段正文。\n　　第二段正文。\n　　第三段正文。",
            format: .plainText
        )
        #expect(blocks == [
            .paragraph("第一段正文。"),
            .paragraph("第二段正文。"),
            .paragraph("第三段正文。"),
        ])

        let hardWrapped = ReaderSemanticParser.parse(
            "Line one of a\nwrapped paragraph.\n\nSecond paragraph.",
            format: .plainText
        )
        #expect(hardWrapped == [
            .paragraph("Line one of a\nwrapped paragraph."),
            .paragraph("Second paragraph."),
        ])
    }

    @Test
    func plainTextChapterHeadingsBecomeHeadings() {
        let blocks = ReaderSemanticParser.parse(
            "第一章 初见\n他走进门。\n第二章\n第三章的故事还没有开始。\nChapter 2: The Road\nCHAPTER XII\n尾声\n",
            format: .plainText
        )
        #expect(blocks == [
            .heading(level: 2, text: "第一章 初见"),
            .paragraph("他走进门。"),
            .heading(level: 2, text: "第二章"),
            .paragraph("第三章的故事还没有开始。"),
            .heading(level: 2, text: "Chapter 2: The Road"),
            .heading(level: 2, text: "CHAPTER XII"),
            .heading(level: 2, text: "尾声"),
        ])
        #expect(!ReaderSemanticParser.isChapterHeading("第一章" + String(repeating: "很长", count: 30)))
        #expect(!ReaderSemanticParser.isChapterHeading("Chapter"))
    }

    @Test
    func oversizedParagraphsAreSplitAtSentenceBoundaries() {
        let sentence = String(repeating: "很", count: 500) + "。"
        let giant = String(repeating: sentence, count: 40)
        let blocks = ReaderSemanticParser.parse(giant, format: .plainText)

        #expect(blocks.count > 1)
        #expect(blocks.allSatisfy { $0.text.utf16.count <= ReaderSemanticParser.maximumParagraphLength })
        #expect(blocks.allSatisfy { $0.text.hasSuffix("。") })
        #expect(blocks.map(\.text).joined() == giant)

        let noPunctuation = String(repeating: "字", count: 20_000)
        let hardCut = ReaderSemanticParser.parse(noPunctuation, format: .plainText)
        #expect(hardCut.count == 3)
        #expect(hardCut.map(\.text).joined() == noPunctuation)
    }
}
