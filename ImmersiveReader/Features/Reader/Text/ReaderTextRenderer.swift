import Foundation
import SwiftUI
import UIKit

/// Rendered text plus the range each semantic block occupies in it, so reading
/// positions can be expressed as block anchors instead of rendered offsets.
struct ReaderRenderedText {
    let attributedString: NSAttributedString
    let blockRanges: [NSRange]
}

enum ReaderTextRenderer {
    @MainActor
    static func render(
        _ content: ReaderTextContent,
        settings: ReaderDisplaySettings
    ) -> ReaderRenderedText {
        let result = NSMutableAttributedString(string: "")
        var blockRanges: [NSRange] = []
        blockRanges.reserveCapacity(content.blocks.count)
        var sourceColors: [ReaderTextColor: UIColor] = [:]

        for block in content.blocks {
            let blockStart = result.length
            append(
                block,
                usesMarkdownInlineFormatting: content.format == .markdown,
                settings: settings,
                sourceColors: &sourceColors,
                to: result
            )
            blockRanges.append(NSRange(location: blockStart, length: result.length - blockStart))
        }

        return ReaderRenderedText(
            attributedString: result.copy() as? NSAttributedString ?? result,
            blockRanges: blockRanges
        )
    }

    @MainActor
    static func attributedString(
        for content: ReaderTextContent,
        settings: ReaderDisplaySettings
    ) -> NSAttributedString {
        render(content, settings: settings).attributedString
    }

    @MainActor
    private static func append(
        _ block: ReaderSemanticBlock,
        usesMarkdownInlineFormatting: Bool,
        settings: ReaderDisplaySettings,
        sourceColors: inout [ReaderTextColor: UIColor],
        to result: NSMutableAttributedString
    ) {
        let bodyFont = UIFont.systemFont(ofSize: settings.fontSize)
        let textColor = settings.theme.textColor
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineHeightMultiple = settings.lineHeightMultiple
        paragraphStyle.paragraphSpacing = settings.fontSize * 0.72
        paragraphStyle.lineBreakMode = .byWordWrapping

        let text: String
        let font: UIFont
        let prefix: String
        var sourceStyles: [ReaderTextStyleSpan] = []
        var additionalAttributes: [NSAttributedString.Key: Any] = [:]

        switch block {
        case .heading(let level, let value):
            text = value
            prefix = ""
            let scale: Double = switch level {
            case 1: 1.62
            case 2: 1.42
            case 3: 1.24
            default: 1.1
            }
            font = .systemFont(ofSize: settings.fontSize * scale, weight: .bold)
            paragraphStyle.paragraphSpacingBefore = settings.fontSize * 0.45
            paragraphStyle.paragraphSpacing = settings.fontSize * 0.7

        case .paragraph(let value):
            text = value
            prefix = ""
            font = bodyFont

        case .styledParagraph(let value):
            text = value.text
            prefix = ""
            font = bodyFont
            sourceStyles = value.styles

        case .unorderedListItem(let depth, let value):
            text = value
            prefix = "•\t"
            font = bodyFont
            configureListParagraphStyle(paragraphStyle, depth: depth, fontSize: settings.fontSize)

        case .orderedListItem(let depth, let ordinal, let value):
            text = value
            prefix = "\(ordinal).\t"
            font = bodyFont
            configureListParagraphStyle(paragraphStyle, depth: depth, fontSize: settings.fontSize)

        case .blockQuote(let value):
            text = value
            prefix = "│  "
            font = .italicSystemFont(ofSize: settings.fontSize)
            paragraphStyle.firstLineHeadIndent = settings.fontSize * 0.7
            paragraphStyle.headIndent = settings.fontSize * 0.7

        case .code(let value):
            text = value
            prefix = ""
            font = .monospacedSystemFont(ofSize: max(13, settings.fontSize * 0.84), weight: .regular)
            paragraphStyle.lineHeightMultiple = 1.35
            paragraphStyle.firstLineHeadIndent = settings.fontSize * 0.7
            paragraphStyle.headIndent = settings.fontSize * 0.7
            additionalAttributes[.backgroundColor] = codeBackgroundColor(for: settings.theme)

        case .divider:
            text = "•••"
            prefix = ""
            font = .systemFont(ofSize: settings.fontSize, weight: .regular)
            paragraphStyle.alignment = .center
            paragraphStyle.paragraphSpacing = settings.fontSize
        }

        let blockStart = result.length
        if !prefix.isEmpty {
            result.append(NSAttributedString(
                string: prefix,
                attributes: [.font: font, .foregroundColor: textColor]
            ))
        }

        if usesMarkdownInlineFormatting, block.supportsInlineMarkdown {
            result.append(inlineMarkdown(text, baseFont: font, textColor: textColor))
        } else {
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: textColor
            ]
            attributes.merge(additionalAttributes) { _, new in new }
            let styledText = NSMutableAttributedString(string: text, attributes: attributes)
            let utf16Text = text as NSString
            for span in sourceStyles where isValid(span.range, in: utf16Text) {
                let foreground: UIColor
                if let cached = sourceColors[span.color] {
                    foreground = cached
                } else {
                    foreground = sourceForegroundColor(span.color, theme: settings.theme)
                    sourceColors[span.color] = foreground
                }
                styledText.addAttribute(
                    .foregroundColor,
                    value: foreground,
                    range: span.range
                )
            }
            result.append(styledText)
        }

        result.append(NSAttributedString(string: "\n", attributes: [
            .font: font,
            .foregroundColor: textColor
        ]))

        let blockRange = NSRange(location: blockStart, length: result.length - blockStart)
        result.addAttribute(.paragraphStyle, value: paragraphStyle, range: blockRange)
        for (key, value) in additionalAttributes {
            result.addAttribute(key, value: value, range: blockRange)
        }
    }

    private static func isValid(_ range: NSRange, in text: NSString) -> Bool {
        // Check with subtraction before adding offsets: malformed imported ranges
        // can contain NSNotFound or values whose sum would overflow Int.
        guard range.location >= 0,
              range.length > 0,
              range.location <= text.length,
              range.length <= text.length - range.location else {
            return false
        }
        return isUTF16Boundary(range.location, in: text)
            && isUTF16Boundary(range.location + range.length, in: text)
    }

    private static func isUTF16Boundary(_ offset: Int, in text: NSString) -> Bool {
        guard offset > 0, offset < text.length else { return true }
        let previous = text.character(at: offset - 1)
        let next = text.character(at: offset)
        return !(0xD800...0xDBFF).contains(previous) || !(0xDC00...0xDFFF).contains(next)
    }

    @MainActor
    private static func sourceForegroundColor(_ color: ReaderTextColor, theme: ReaderTheme) -> UIColor {
        let original = uiColor(color)
        switch theme {
        case .light, .sepia:
            return original
        case .dark:
            return readableColor(color, against: UIColor(theme.backgroundColor))
        case .system:
            // Keep a dynamic attribute, so existing attributed pages follow a trait
            // change without flattening source colors into the theme's label color.
            let darkBackground = UIColor.systemBackground.resolvedColor(
                with: UITraitCollection(userInterfaceStyle: .dark)
            )
            let darkColor = readableColor(color, against: darkBackground)
            return UIColor { traits in
                traits.userInterfaceStyle == .dark ? darkColor : original
            }
        }
    }

    private static func uiColor(_ color: ReaderTextColor) -> UIColor {
        UIColor(red: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
    }

    private static func readableColor(_ source: ReaderTextColor, against background: UIColor) -> UIColor {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard background.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return uiColor(source)
        }
        let backgroundColor = ReaderTextColor(red: red, green: green, blue: blue)
        let minimumContrast = 4.5
        guard source.alpha > 0,
              contrast(of: source, against: backgroundColor) < minimumContrast else {
            return uiColor(source)
        }

        // The smallest white mix that reaches readable contrast retains the source
        // hue family. Cap the adjustment instead of washing faint colors out to white.
        var lowerBound = 0.0
        var upperBound = 0.75
        for _ in 0..<18 {
            let amount = (lowerBound + upperBound) / 2
            if contrast(of: lightened(source, amount: amount), against: backgroundColor) < minimumContrast {
                lowerBound = amount
            } else {
                upperBound = amount
            }
        }
        return uiColor(lightened(source, amount: upperBound))
    }

    private static func lightened(_ color: ReaderTextColor, amount: Double) -> ReaderTextColor {
        ReaderTextColor(
            red: color.red + (1 - color.red) * amount,
            green: color.green + (1 - color.green) * amount,
            blue: color.blue + (1 - color.blue) * amount,
            alpha: color.alpha
        )
    }

    private static func contrast(of foreground: ReaderTextColor, against background: ReaderTextColor) -> Double {
        let visible = ReaderTextColor(
            red: foreground.red * foreground.alpha + background.red * (1 - foreground.alpha),
            green: foreground.green * foreground.alpha + background.green * (1 - foreground.alpha),
            blue: foreground.blue * foreground.alpha + background.blue * (1 - foreground.alpha)
        )
        let foregroundLuminance = luminance(of: visible)
        let backgroundLuminance = luminance(of: background)
        return (max(foregroundLuminance, backgroundLuminance) + 0.05)
            / (min(foregroundLuminance, backgroundLuminance) + 0.05)
    }

    private static func luminance(of color: ReaderTextColor) -> Double {
        func linear(_ component: Double) -> Double {
            component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.red) + 0.7152 * linear(color.green) + 0.0722 * linear(color.blue)
    }

    @MainActor
    private static func inlineMarkdown(
        _ source: String,
        baseFont: UIFont,
        textColor: UIColor
    ) -> NSAttributedString {
        let parsed: AttributedString
        do {
            parsed = try AttributedString(
                markdown: source,
                options: .init(
                    interpretedSyntax: .inlineOnlyPreservingWhitespace,
                    failurePolicy: .returnPartiallyParsedIfPossible
                )
            )
        } catch {
            return NSAttributedString(
                string: source,
                attributes: [.font: baseFont, .foregroundColor: textColor]
            )
        }

        let result = NSMutableAttributedString(string: "")
        for run in parsed.runs {
            let value = String(parsed[run.range].characters)
            var attributes: [NSAttributedString.Key: Any] = [
                .font: styledFont(base: baseFont, intent: run.inlinePresentationIntent),
                .foregroundColor: textColor
            ]

            if run.inlinePresentationIntent?.contains(.strikethrough) == true {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if let link = run.link {
                attributes[.link] = link
            }
            if run.inlinePresentationIntent?.contains(.code) == true {
                attributes[.backgroundColor] = UIColor.secondarySystemFill
            }

            result.append(NSAttributedString(string: value, attributes: attributes))
        }
        return result
    }

    @MainActor
    private static func styledFont(base: UIFont, intent: InlinePresentationIntent?) -> UIFont {
        guard let intent else {
            return base
        }
        if intent.contains(.code) {
            return .monospacedSystemFont(ofSize: base.pointSize * 0.92, weight: .regular)
        }

        var traits = base.fontDescriptor.symbolicTraits
        if intent.contains(.stronglyEmphasized) {
            traits.insert(.traitBold)
        }
        if intent.contains(.emphasized) {
            traits.insert(.traitItalic)
        }

        guard let descriptor = base.fontDescriptor.withSymbolicTraits(traits) else {
            return base
        }
        return UIFont(descriptor: descriptor, size: base.pointSize)
    }

    private static func configureListParagraphStyle(
        _ style: NSMutableParagraphStyle,
        depth: Int,
        fontSize: Double
    ) {
        let indentation = fontSize * (1.45 + Double(depth) * 1.1)
        style.firstLineHeadIndent = fontSize * Double(depth) * 1.1
        style.headIndent = indentation
        style.tabStops = [NSTextTab(textAlignment: .left, location: indentation)]
    }

    @MainActor
    private static func codeBackgroundColor(for theme: ReaderTheme) -> UIColor {
        switch theme {
        case .dark:
            UIColor(white: 1, alpha: 0.1)
        case .system:
            .secondarySystemFill
        case .light, .sepia:
            UIColor(white: 0, alpha: 0.07)
        }
    }
}

private extension ReaderSemanticBlock {
    var supportsInlineMarkdown: Bool {
        switch self {
        case .heading, .paragraph, .unorderedListItem, .orderedListItem, .blockQuote:
            true
        case .styledParagraph, .code, .divider:
            false
        }
    }
}
