import Foundation
import SwiftUI
import Testing
import UIKit
@testable import ImmerseRead

@MainActor
struct ReaderColorRenderingTests {
    @Test
    func sourceColorComponentsAreFiniteAndClamped() {
        let invalid = ReaderTextColor(red: .nan, green: .infinity, blue: -.infinity, alpha: .nan)
        #expect(invalid == ReaderTextColor(red: 0, green: 1, blue: 0, alpha: 1))
        #expect(ReaderTextColor(red: -2, green: 3, blue: 0.25, alpha: 2)
            == ReaderTextColor(red: 0, green: 1, blue: 0.25, alpha: 1))
        #expect(ReaderTextColor(red: 1, green: 0, blue: 0, alpha: -1).alpha == 0)
    }

    @Test
    func coloredNamesKeepExactSourceColorWhileUnmarkedTextUsesTheTheme() throws {
        let text = "阿澄：这是对白。"
        let sourceColor = ReaderTextColor(red: 0.71, green: 0.16, blue: 0.28, alpha: 0.85)
        let nameRange = (text as NSString).range(of: "阿澄")
        let content = styledContent(text, range: nameRange, color: sourceColor)

        for theme in [ReaderTheme.light, .sepia] {
            let rendered = ReaderTextRenderer.attributedString(
                for: content,
                settings: ReaderDisplaySettings(theme: theme)
            )
            try expectColor(in: rendered, at: nameRange.location, equals: sourceColor)
            try expectColor(
                in: rendered,
                at: NSMaxRange(nameRange),
                equals: components(of: theme.textColor)
            )
            #expect(rendered.string == text + "\n")
        }
    }

    @Test
    func resizingTextChangesActualFontWithoutDiscardingColorOrLineBreaks() throws {
        let text = "阿澄：第一行。\n第二行刻意换行。"
        let nameRange = (text as NSString).range(of: "阿澄")
        let color = ReaderTextColor(red: 0.12, green: 0.42, blue: 0.67)
        let content = styledContent(text, range: nameRange, color: color)

        for (fontSize, lineHeight) in [(14.0, 1.2), (26.0, 1.6), (40.0, 2.0)] {
            let rendered = ReaderTextRenderer.attributedString(
                for: content,
                settings: ReaderDisplaySettings(
                    fontSize: fontSize,
                    lineHeightMultiple: lineHeight,
                    theme: .light
                )
            )
            let font = try #require(rendered.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
            let paragraph = try #require(
                rendered.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
            )
            #expect(Double(font.pointSize) == fontSize)
            #expect(Double(paragraph.lineHeightMultiple) == lineHeight)
            #expect(rendered.string == text + "\n")
            try expectColor(in: rendered, at: 0, equals: color)
        }
    }

    @Test
    func UTF16OffsetsDoNotShiftColorsAfterEmoji() throws {
        let text = "👩🏽‍💻 阿澄：你好。"
        let emojiRange = (text as NSString).range(of: "👩🏽‍💻")
        let nameRange = (text as NSString).range(of: "阿澄")
        let nameColor = ReaderTextColor(red: 0.75, green: 0.15, blue: 0.25)
        let emojiColor = ReaderTextColor(red: 0.1, green: 0.35, blue: 0.65)
        let content = ReaderTextContent(format: .pdf, blocks: [
            .styledParagraph(ReaderStyledText(text: text, styles: [
                ReaderTextStyleSpan(range: emojiRange, color: emojiColor),
                ReaderTextStyleSpan(range: nameRange, color: nameColor)
            ]))
        ])
        let rendered = ReaderTextRenderer.attributedString(
            for: content,
            settings: ReaderDisplaySettings(theme: .light)
        )

        #expect(emojiRange.length > 1)
        #expect(nameRange.location > 2)
        try expectColor(in: rendered, at: 0, equals: emojiColor)
        try expectColor(in: rendered, at: NSMaxRange(emojiRange) - 1, equals: emojiColor)
        try expectColor(in: rendered, at: nameRange.location, equals: nameColor)
        try expectColor(in: rendered, at: NSMaxRange(nameRange), equals: components(of: .black))
    }

    @Test
    func invalidRangesAreIgnoredWithoutOverflowOrColorBleeding() throws {
        let text = "😀名字"
        let invalidRanges = [
            NSRange(location: NSNotFound, length: 1),
            NSRange(location: Int.max - 1, length: 100),
            NSRange(location: -1, length: 2),
            NSRange(location: 0, length: -1),
            NSRange(location: 2, length: Int.max),
            NSRange(location: 0, length: 99),
            NSRange(location: 2, length: 0),
            NSRange(location: 1, length: 1),
            NSRange(location: 0, length: 1)
        ]
        let content = ReaderTextContent(format: .pdf, blocks: [
            .styledParagraph(ReaderStyledText(
                text: text,
                styles: invalidRanges.map {
                    ReaderTextStyleSpan(range: $0, color: ReaderTextColor(red: 1, green: 0, blue: 0))
                }
            ))
        ])
        let rendered = ReaderTextRenderer.attributedString(
            for: content,
            settings: ReaderDisplaySettings(theme: .light)
        )

        #expect(rendered.string == text + "\n")
        for offset in 0..<rendered.length {
            try expectColor(in: rendered, at: offset, equals: components(of: .black))
        }
    }

    @Test
    func coloredSpansSurvivePageSubstringsAndRePagination() async throws {
        let text = String(repeating: "阿澄：这一段使用同一种说话者颜色，也能够调整字号。", count: 100)
        let color = ReaderTextColor(red: 0.13, green: 0.47, blue: 0.39)
        let content = styledContent(
            text,
            range: NSRange(location: 0, length: (text as NSString).length),
            color: color
        )
        var pageCounts: [Int] = []
        for fontSize in [16.0, 30.0] {
            let rendered = ReaderTextRenderer.attributedString(
                for: content,
                settings: ReaderDisplaySettings(fontSize: fontSize, theme: .light)
            )
            let pages = try await ReaderTextPaginator.pageRanges(
                from: rendered,
                contentSize: CGSize(width: 280, height: 420)
            )
            pageCounts.append(pages.count)
            #expect(pages.count > 1)
            #expect(pages.map { rendered.attributedSubstring(from: $0).string }.joined() == rendered.string)

            let styledRange = NSRange(location: 0, length: (text as NSString).length)
            for range in pages {
                let intersection = NSIntersectionRange(range, styledRange)
                guard intersection.length > 0 else { continue }
                let page = rendered.attributedSubstring(from: range)
                try expectColor(in: page, at: intersection.location - range.location, equals: color)
                try expectColor(in: page, at: NSMaxRange(intersection) - range.location - 1, equals: color)
            }
        }
        #expect(pageCounts[1] > pageCounts[0])
    }

    @Test
    func darkThemeBrightensLowContrastColorWithoutTurningEverySpeakerWhite() throws {
        let source = ReaderTextColor(red: 0.52, green: 0.08, blue: 0.15)
        let content = styledContent("名字：对白。", range: NSRange(location: 0, length: 2), color: source)
        let rendered = ReaderTextRenderer.attributedString(
            for: content,
            settings: ReaderDisplaySettings(theme: .dark)
        )
        let adjusted = try components(of: color(in: rendered, at: 0))
        let background = try components(of: UIColor(ReaderTheme.dark.backgroundColor))

        #expect(adjusted.red > source.red)
        #expect(adjusted.red > adjusted.blue)
        #expect(adjusted.blue > adjusted.green)
        #expect(adjusted.green < 0.9)
        #expect(contrast(adjusted, background) >= 4.49)
        #expect(adjusted.alpha == source.alpha)
        try expectColor(in: rendered, at: 2, equals: components(of: ReaderTheme.dark.textColor))
    }

    @Test
    func alreadyReadableSourceColorIsUnchangedInDarkTheme() throws {
        let source = ReaderTextColor(red: 0.5, green: 0.9, blue: 0.65)
        let rendered = ReaderTextRenderer.attributedString(
            for: styledContent("名字", range: NSRange(location: 0, length: 2), color: source),
            settings: ReaderDisplaySettings(theme: .dark)
        )
        try expectColor(in: rendered, at: 0, equals: source)
    }

    @Test
    func systemThemeSourceAndDefaultTextRespondToTheActualTrait() throws {
        let source = ReaderTextColor(red: 0.15, green: 0.22, blue: 0.57)
        let rendered = ReaderTextRenderer.attributedString(
            for: styledContent("名字：对白。", range: NSRange(location: 0, length: 2), color: source),
            settings: ReaderDisplaySettings(theme: .system)
        )
        let name = try color(in: rendered, at: 0)
        let body = try color(in: rendered, at: 2)
        try expectColor(in: rendered, at: 0, equals: source, style: .light)
        let darkName = try components(of: name, style: .dark)
        #expect(darkName.blue > darkName.red)
        #expect(darkName.green < 0.9)
        #expect(darkName != source)

        for style in [UIUserInterfaceStyle.light, .dark] {
            #expect(try components(of: body, style: style) == components(of: .label, style: style))
        }
        #expect(try components(of: body, style: .light) != components(of: body, style: .dark))
    }

    private func styledContent(_ text: String, range: NSRange, color: ReaderTextColor) -> ReaderTextContent {
        ReaderTextContent(format: .pdf, blocks: [
            .styledParagraph(ReaderStyledText(text: text, styles: [
                ReaderTextStyleSpan(range: range, color: color)
            ]))
        ])
    }

    private func color(in text: NSAttributedString, at offset: Int) throws -> UIColor {
        try #require(text.attribute(.foregroundColor, at: offset, effectiveRange: nil) as? UIColor)
    }

    private func components(of color: UIColor, style: UIUserInterfaceStyle = .light) throws -> ReaderTextColor {
        let resolved = color.resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        try #require(resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha))
        return ReaderTextColor(red: red, green: green, blue: blue, alpha: alpha)
    }

    private func expectColor(
        in text: NSAttributedString,
        at offset: Int,
        equals expected: ReaderTextColor,
        style: UIUserInterfaceStyle = .light
    ) throws {
        let actual = try components(of: color(in: text, at: offset), style: style)
        #expect(abs(actual.red - expected.red) < 0.00001)
        #expect(abs(actual.green - expected.green) < 0.00001)
        #expect(abs(actual.blue - expected.blue) < 0.00001)
        #expect(abs(actual.alpha - expected.alpha) < 0.00001)
    }

    private func contrast(_ foreground: ReaderTextColor, _ background: ReaderTextColor) -> Double {
        func linear(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        func luminance(_ color: ReaderTextColor) -> Double {
            linear(color.red) * 0.2126 + linear(color.green) * 0.7152 + linear(color.blue) * 0.0722
        }
        return (luminance(foreground) + 0.05) / (luminance(background) + 0.05)
    }
}
