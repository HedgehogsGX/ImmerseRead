import Foundation

struct ReaderTextSegment: Hashable, Sendable {
    let blockRange: Range<Int>
}

struct ReaderTextSegmentation: Hashable, Sendable {
    static let targetSegmentLength = 12_000
    static let minimumSegmentLength = 2_000

    let segments: [ReaderTextSegment]
    let blockStarts: [Int]
    let totalLength: Int

    init(blocks: [ReaderSemanticBlock]) {
        var segments: [ReaderTextSegment] = []
        var blockStarts: [Int] = []
        blockStarts.reserveCapacity(blocks.count)

        var segmentStart = 0
        var segmentLength = 0
        var total = 0
        for (index, block) in blocks.enumerated() {
            blockStarts.append(total)
            let startsChapter = block.isMajorHeading && segmentLength >= Self.minimumSegmentLength
            if index > segmentStart, startsChapter || segmentLength >= Self.targetSegmentLength {
                segments.append(ReaderTextSegment(blockRange: segmentStart ..< index))
                segmentStart = index
                segmentLength = 0
            }
            let length = block.estimatedLength
            segmentLength += length
            total += length
        }
        if segmentStart < blocks.count {
            segments.append(ReaderTextSegment(blockRange: segmentStart ..< blocks.count))
        }

        self.segments = segments
        self.blockStarts = blockStarts
        totalLength = total
    }

    var isEmpty: Bool {
        segments.isEmpty
    }

    func segmentIndex(containingBlock blockIndex: Int) -> Int {
        guard !segments.isEmpty else { return 0 }
        var lowerBound = 0
        var upperBound = segments.count
        while lowerBound < upperBound {
            let middle = lowerBound + (upperBound - lowerBound) / 2
            if segments[middle].blockRange.upperBound <= blockIndex {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }
        return min(lowerBound, segments.count - 1)
    }

    func progress(for anchor: ReaderTextAnchor) -> Double {
        guard totalLength > 0, !blockStarts.isEmpty else { return 0 }
        let blockIndex = min(anchor.blockIndex, blockStarts.count - 1)
        let blockLength = (blockIndex + 1 < blockStarts.count ? blockStarts[blockIndex + 1] : totalLength)
            - blockStarts[blockIndex]
        let offset = blockStarts[blockIndex] + min(anchor.offsetInBlock, max(blockLength - 1, 0))
        return (Double(offset) / Double(totalLength)).clampedToUnitInterval
    }

    func anchor(forProgress progress: Double) -> ReaderTextAnchor {
        guard totalLength > 0, !blockStarts.isEmpty else {
            return ReaderTextAnchor(blockIndex: 0, offsetInBlock: 0)
        }
        let target = min(Int((progress.clampedToUnitInterval * Double(totalLength)).rounded()), totalLength - 1)
        var lowerBound = 0
        var upperBound = blockStarts.count
        while lowerBound < upperBound {
            let middle = lowerBound + (upperBound - lowerBound) / 2
            if blockStarts[middle] <= target {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }
        let blockIndex = max(0, lowerBound - 1)
        return ReaderTextAnchor(blockIndex: blockIndex, offsetInBlock: target - blockStarts[blockIndex])
    }
}

extension ReaderSemanticBlock {
    var text: String {
        switch self {
        case .heading(_, let text), .paragraph(let text), .blockQuote(let text), .code(let text),
             .unorderedListItem(_, let text), .orderedListItem(_, _, let text):
            text
        case .styledParagraph(let styled):
            styled.text
        case .divider:
            ""
        }
    }

    var estimatedLength: Int {
        text.utf16.count + 1
    }

    var isMajorHeading: Bool {
        if case .heading(let level, _) = self {
            return level <= 2
        }
        return false
    }
}
