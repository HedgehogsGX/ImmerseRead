import Foundation
import Testing
import UIKit
@testable import ImmerseRead

struct ReaderTypographyTests {
    @Test @MainActor
    func selectedFontFamilyChangesNativeFontAndMarginsExposeContentInsets() throws {
        let content = ReaderTextContent(format: .plainText, blocks: [.paragraph("Typography")])
        let system = ReaderTextRenderer.attributedString(
            for: content,
            settings: ReaderDisplaySettings(fontFamily: .system, margin: 20)
        )
        let serif = ReaderTextRenderer.attributedString(
            for: content,
            settings: ReaderDisplaySettings(fontFamily: .serif, margin: 32)
        )

        let systemFont = try #require(system.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        let serifFont = try #require(serif.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)

        #expect(systemFont.familyName != serifFont.familyName)
        let request = ReaderLayoutRequest(
            settings: ReaderDisplaySettings(fontFamily: .serif, margin: 32),
            availableSize: CGSize(width: 390, height: 700)
        )
        #expect(request.contentInsets.left == 32)
        #expect(request.contentInsets.right == 32)
        #expect(request.contentSize.width == 326)
    }

    @Test @MainActor
    func fontSettingChangesActualFontPointSizeAndParagraphSpacing() throws {
        let content = ReaderTextContent(format: .plainText, blocks: [.paragraph("可重排的正文")])
        let small = ReaderTextRenderer.attributedString(
            for: content,
            settings: ReaderDisplaySettings(fontSize: 16, lineHeightMultiple: 1.3)
        )
        let large = ReaderTextRenderer.attributedString(
            for: content,
            settings: ReaderDisplaySettings(fontSize: 30, lineHeightMultiple: 1.8)
        )

        let smallFont = try #require(small.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        let largeFont = try #require(large.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        let smallParagraph = try #require(
            small.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        )
        let largeParagraph = try #require(
            large.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        )

        #expect(smallFont.pointSize == 16)
        #expect(largeFont.pointSize == 30)
        #expect(smallParagraph.lineHeightMultiple == 1.3)
        #expect(largeParagraph.lineHeightMultiple == 1.8)
        #expect(largeParagraph.paragraphSpacing > smallParagraph.paragraphSpacing)
        #expect(small.string == large.string)
    }

    @Test @MainActor
    func largerFontsCreateMorePagesAndBothLayoutsCoverEveryCharacter() async throws {
        let content = sampleContent
        let smallText = ReaderTextRenderer.attributedString(
            for: content,
            settings: ReaderDisplaySettings(fontSize: 16)
        )
        let largeText = ReaderTextRenderer.attributedString(
            for: content,
            settings: ReaderDisplaySettings(fontSize: 30)
        )
        let viewport = CGSize(width: 300, height: 480)
        let smallPages = try await ReaderTextPaginator.pageRanges(from: smallText, contentSize: viewport)
        let largePages = try await ReaderTextPaginator.pageRanges(from: largeText, contentSize: viewport)

        #expect(smallPages.count > 1)
        #expect(largePages.count > smallPages.count)
        expectFullCoverage(smallPages, text: smallText)
        expectFullCoverage(largePages, text: largeText)
    }

    @Test @MainActor
    func reflowKeepsTheSavedCharacterInTheSelectedPage() async throws {
        let content = sampleContent
        let originalText = ReaderTextRenderer.attributedString(
            for: content,
            settings: ReaderDisplaySettings(fontSize: 18)
        )
        let originalPages = try await ReaderTextPaginator.pageRanges(
            from: originalText,
            contentSize: CGSize(width: 300, height: 480)
        )
        let page = try #require(originalPages.dropFirst(originalPages.count / 2).first)
        let anchor = page.location + min(17, page.length - 1)

        for fontSize in [32.0, 22.0, 14.0, 28.0] {
            let text = ReaderTextRenderer.attributedString(
                for: content,
                settings: ReaderDisplaySettings(fontSize: fontSize, lineHeightMultiple: 1.7)
            )
            let pages = try await ReaderTextPaginator.pageRanges(
                from: text,
                contentSize: CGSize(width: 280, height: 430)
            )
            let selectedPage = try #require(
                ReaderTextPosition.pageIndex(containingCharacterAt: anchor, in: pages)
            )

            #expect(text.string == originalText.string)
            #expect(NSLocationInRange(anchor, pages[selectedPage]))
        }
    }

    @Test
    func characterProgressRoundTripsWithoutDependingOnPageCount() {
        let length = 75_431
        for offset in [0, 1, 170, 15_711, length - 1] {
            let progress = ReaderTextPosition.progress(forCharacterOffset: offset, textLength: length)
            #expect(ReaderTextPosition.characterOffset(for: progress, textLength: length) == offset)
        }
        #expect(ReaderTextPosition.characterOffset(for: .nan, textLength: length) == 0)
        #expect(ReaderTextPosition.characterOffset(for: -1, textLength: length) == 0)
        #expect(ReaderTextPosition.characterOffset(for: 2, textLength: length) == length - 1)
        #expect(ReaderTextPosition.characterOffset(for: 0.5, textLength: 0) == 0)
        #expect(ReaderTextPosition.progress(forCharacterOffset: 10, textLength: 0) == 0)
    }

    @Test
    func pageLookupHonorsExactBoundariesAndClampsSavedLocations() {
        let pages = [
            NSRange(location: 0, length: 100),
            NSRange(location: 100, length: 80),
            NSRange(location: 180, length: 20)
        ]

        #expect(ReaderTextPosition.pageIndex(containingCharacterAt: -10, in: pages) == 0)
        #expect(ReaderTextPosition.pageIndex(containingCharacterAt: 99, in: pages) == 0)
        #expect(ReaderTextPosition.pageIndex(containingCharacterAt: 100, in: pages) == 1)
        #expect(ReaderTextPosition.pageIndex(containingCharacterAt: 179, in: pages) == 1)
        #expect(ReaderTextPosition.pageIndex(containingCharacterAt: 180, in: pages) == 2)
        #expect(ReaderTextPosition.pageIndex(containingCharacterAt: 999, in: pages) == 2)
        #expect(ReaderTextPosition.pageIndex(containingCharacterAt: 0, in: []) == nil)
    }

    @Test @MainActor
    func cancelledPaginationDoesNotPublishAPartialLayout() async throws {
        let text = ReaderTextRenderer.attributedString(for: sampleContent, settings: .default)
        let task = Task { @MainActor in
            try await ReaderTextPaginator.pageRanges(
                from: text,
                contentSize: CGSize(width: 280, height: 430)
            )
        }
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Cancelled pagination unexpectedly completed")
        } catch is CancellationError {
            // A replaced font-size request is a normal cancellation, not a reader error.
        }
    }

    private var sampleContent: ReaderTextContent {
        ReaderTextContent(
            format: .plainText,
            blocks: (0..<32).map { index in
                .paragraph("第 \(index + 1) 段。" + String(
                    repeating: "调节字号后正文应重新换行分页，而不是放大整张纸。Mixed text, e\u{301} and 👩🏽‍💻。",
                    count: 5
                ))
            }
        )
    }

    private func expectFullCoverage(_ ranges: [NSRange], text: NSAttributedString) {
        #expect(ranges.first?.location == 0)
        #expect(ranges.last.map(NSMaxRange) == text.length)
        #expect(ranges.allSatisfy { $0.length > 0 })
        for (previous, next) in zip(ranges, ranges.dropFirst()) {
            #expect(NSMaxRange(previous) == next.location)
        }
        let reconstructed = ranges.map { text.attributedSubstring(from: $0).string }.joined()
        #expect(reconstructed == text.string)
    }
}
