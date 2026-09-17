import Foundation

/// Reader locations use UTF-16 offsets, matching TextKit and NSAttributedString.
/// Unlike page numbers, these locations do not move when the font or viewport changes.
enum ReaderTextPosition {
    static func characterOffset(for progress: Double, textLength: Int) -> Int {
        guard textLength > 1 else { return 0 }
        return Int((progress.clampedToUnitInterval * Double(textLength - 1)).rounded())
    }

    static func progress(forCharacterOffset offset: Int, textLength: Int) -> Double {
        guard textLength > 1 else { return 0 }
        let clampedOffset = min(max(offset, 0), textLength - 1)
        return Double(clampedOffset) / Double(textLength - 1)
    }

    /// The paginator returns contiguous, ordered ranges. Binary search also handles
    /// saved positions outside the document by choosing its first or last page.
    static func pageIndex(containingCharacterAt offset: Int, in pageRanges: [NSRange]) -> Int? {
        guard !pageRanges.isEmpty else { return nil }

        var lowerBound = 0
        var upperBound = pageRanges.count
        while lowerBound < upperBound {
            let middle = lowerBound + (upperBound - lowerBound) / 2
            if NSMaxRange(pageRanges[middle]) <= offset {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }
        return min(lowerBound, pageRanges.count - 1)
    }
}

extension ReaderTextPosition {
    /// Block ranges come from the renderer: contiguous, ordered, covering the whole string.
    static func anchor(forCharacterOffset offset: Int, blockRanges: [NSRange]) -> ReaderTextAnchor {
        guard let blockIndex = pageIndex(containingCharacterAt: offset, in: blockRanges) else {
            return ReaderTextAnchor(blockIndex: 0, offsetInBlock: 0)
        }
        return ReaderTextAnchor(
            blockIndex: blockIndex,
            offsetInBlock: max(0, offset - blockRanges[blockIndex].location)
        )
    }

    /// An anchor past the end of a shorter block lands at that block's end, and an
    /// anchor past the last block lands on the last block, so a document edited
    /// since the anchor was saved still reopens near the right place.
    static func characterOffset(for anchor: ReaderTextAnchor, blockRanges: [NSRange]) -> Int {
        guard !blockRanges.isEmpty else { return 0 }
        let range = blockRanges[min(anchor.blockIndex, blockRanges.count - 1)]
        return range.location + min(anchor.offsetInBlock, max(range.length - 1, 0))
    }
}
