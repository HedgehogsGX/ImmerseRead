import UIKit

enum ReaderTextPaginator {
    @MainActor
    static func pageRanges(
        from text: NSAttributedString,
        contentSize: CGSize
    ) async throws -> [NSRange] {
        try Task.checkCancellation()
        guard let session = Session(text: text, contentSize: contentSize) else {
            return text.length > 0 ? [NSRange(location: 0, length: text.length)] : []
        }

        var pageRanges: [NSRange] = []
        while let range = try session.nextPage() {
            pageRanges.append(range)
            if pageRanges.count.isMultiple(of: 8) {
                await Task.yield()
                try Task.checkCancellation()
            }
        }
        return pageRanges
    }

    @MainActor
    static func pageRangesNow(
        from text: NSAttributedString,
        contentSize: CGSize
    ) throws -> [NSRange] {
        guard let session = Session(text: text, contentSize: contentSize) else {
            return text.length > 0 ? [NSRange(location: 0, length: text.length)] : []
        }

        var pageRanges: [NSRange] = []
        while let range = try session.nextPage() {
            pageRanges.append(range)
        }
        return pageRanges
    }

    @MainActor
    private final class Session {
        private let text: NSAttributedString
        private let contentSize: CGSize
        private let storage: NSTextStorage
        private let layoutManager = NSLayoutManager()
        private var laidOutCharacterCount = 0

        init?(text: NSAttributedString, contentSize: CGSize) {
            guard text.length > 0, contentSize.width >= 40, contentSize.height >= 40 else {
                return nil
            }
            self.text = text
            self.contentSize = contentSize
            storage = NSTextStorage(attributedString: text)
            storage.addLayoutManager(layoutManager)
        }

        func nextPage() throws -> NSRange? {
            guard laidOutCharacterCount < text.length else {
                return nil
            }

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
            let end = min(NSMaxRange(characterRange), text.length)
            let range = NSRange(location: laidOutCharacterCount, length: end - laidOutCharacterCount)
            laidOutCharacterCount = end
            return range
        }
    }

    enum PaginationError: LocalizedError {
        case unableToFitText

        var errorDescription: String? {
            String(localized: "当前页面无法容纳正文，请尝试滚动阅读或减小字号。")
        }
    }
}
