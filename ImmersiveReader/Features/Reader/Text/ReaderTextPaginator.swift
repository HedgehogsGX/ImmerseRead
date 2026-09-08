import UIKit

enum ReaderTextPaginator {
    /// Uses TextKit's glyph layout so page boundaries track the actual font and line spacing.
    /// Only character ranges are retained; page strings are materialized lazily by the UI.
    @MainActor
    static func pageRanges(
        from text: NSAttributedString,
        contentSize: CGSize
    ) async throws -> [NSRange] {
        try Task.checkCancellation()
        guard text.length > 0 else {
            return []
        }
        guard contentSize.width >= 40, contentSize.height >= 40 else {
            return [NSRange(location: 0, length: text.length)]
        }

        let storage = NSTextStorage(attributedString: text)
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)

        var pageRanges: [NSRange] = []
        var laidOutCharacterCount = 0

        while laidOutCharacterCount < text.length {
            try Task.checkCancellation()

            let container = NSTextContainer(size: contentSize)
            container.lineFragmentPadding = 0
            container.maximumNumberOfLines = 0
            layoutManager.addTextContainer(container)
            layoutManager.ensureLayout(for: container)

            let glyphRange = layoutManager.glyphRange(for: container)
            guard glyphRange.length > 0 else {
                throw PaginationError.unableToFitText
            }

            let characterRange = layoutManager.characterRange(
                forGlyphRange: glyphRange,
                actualGlyphRange: nil
            )
            guard NSMaxRange(characterRange) > laidOutCharacterCount else {
                throw PaginationError.unableToFitText
            }
            // Keep exact character coverage even when a glyph represents several
            // UTF-16 code units (emoji, ligatures or combining marks).
            let end = min(NSMaxRange(characterRange), text.length)
            pageRanges.append(NSRange(
                location: laidOutCharacterCount,
                length: end - laidOutCharacterCount
            ))
            laidOutCharacterCount = end

            if pageRanges.count.isMultiple(of: 8) {
                await Task.yield()
            }
        }

        try Task.checkCancellation()
        return pageRanges
    }

    enum PaginationError: LocalizedError {
        case unableToFitText

        var errorDescription: String? {
            "当前页面无法容纳正文，请尝试滚动阅读或减小字号。"
        }
    }
}
