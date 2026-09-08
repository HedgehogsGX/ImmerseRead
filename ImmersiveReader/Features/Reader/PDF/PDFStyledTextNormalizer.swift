import Foundation
import CoreGraphics
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Keeps the PDF's meaningful inline colors while removing physical line wraps.
/// PDFKit objects and attributed strings remain confined to the extraction worker;
/// only plain text, UTF-16 ranges, and RGBA values leave it.
enum PDFStyledTextNormalizer {
    static let defaultMaximumStyleRunCount = 100_000

    static func paragraphs(
        from source: NSAttributedString,
        boundsForRange: ((NSRange) -> CGRect?)? = nil,
        maximumParagraphCount: Int = 20_000
    ) throws -> [ReaderStyledText] {
        let limit = max(1, maximumParagraphCount)
        var paragraphs: [ReaderStyledText] = []
        try forEachParagraph(in: source, boundsForRange: boundsForRange) { paragraph in
            guard paragraphs.count < limit else {
                throw PDFTextExtractionError.tooManyParagraphs(maximumParagraphs: limit)
            }
            paragraphs.append(paragraph)
        }
        return paragraphs
    }

    static func forEachParagraph(
        in source: NSAttributedString,
        boundsForRange: ((NSRange) -> CGRect?)? = nil,
        maximumStyleRunCount: Int = defaultMaximumStyleRunCount,
        _ receive: (ReaderStyledText) throws -> Void
    ) throws {
        try Task.checkCancellation()
        let text = source.string as NSString
        let sourceStyles = try colorSpans(in: source, limit: max(1, maximumStyleRunCount))
        let layout = try LineLayout(text: text, boundsForRange: boundsForRange)
        var paragraph = StyledBuilder()
        var previousLine: NormalizedLine?
        var styleIndex = 0

        func flushParagraph() throws {
            guard !paragraph.text.isEmpty else { return }
            try receive(ReaderStyledText(text: paragraph.text, styles: paragraph.styles))
            paragraph = StyledBuilder()
            previousLine = nil
        }

        try forEachLine(in: text) { range, explicitParagraphEnd in
            let line = try normalizedLine(
                in: text,
                range: range,
                sourceStyles: sourceStyles,
                styleIndex: &styleIndex,
                bounds: layout.bounds[range] ?? boundsForRange?(range)
            )
            guard !line.content.text.isEmpty else {
                try flushParagraph()
                return true
            }

            if let previousLine, shouldStartParagraph(line, after: previousLine, layout: layout) {
                try flushParagraph()
            }
            if !paragraph.text.isEmpty,
               previousLine?.endsWithSoftHyphen != true,
               needsSpace(between: paragraph.text, and: line.content.text) {
                paragraph.append(" ", color: nil)
            }
            paragraph.append(line.content)
            previousLine = line
            if explicitParagraphEnd {
                try flushParagraph()
            }
            return true
        }
        try flushParagraph()
        try Task.checkCancellation()
    }

    private static func colorSpans(
        in source: NSAttributedString,
        limit: Int
    ) throws -> [ReaderTextStyleSpan] {
        var spans: [ReaderTextStyleSpan] = []
        var exceededLimit = false
        source.enumerateAttribute(
            .foregroundColor,
            in: NSRange(location: 0, length: source.length)
        ) { value, range, stop in
            if Task.isCancelled {
                stop.pointee = true
                return
            }
            guard let color = sourceColor(value) else { return }
            guard spans.count < limit else {
                exceededLimit = true
                stop.pointee = true
                return
            }
            spans.append(ReaderTextStyleSpan(range: range, color: color))
        }
        try Task.checkCancellation()
        guard !exceededLimit else {
            throw PDFTextExtractionError.tooManyStyleRuns(maximumRuns: limit)
        }
        return spans
    }

    private static func sourceColor(_ value: Any?) -> ReaderTextColor? {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        #if canImport(UIKit)
        guard let color = value as? UIColor,
              let sRGB = CGColorSpace(name: CGColorSpace.sRGB),
              let converted = color.cgColor.converted(to: sRGB, intent: .relativeColorimetric, options: nil),
              let components = converted.components, components.count == 4 else { return nil }
        red = components[0]
        green = components[1]
        blue = components[2]
        alpha = components[3]
        #elseif canImport(AppKit)
        guard let color = (value as? NSColor)?.usingColorSpace(.sRGB) else { return nil }
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        #else
        return nil
        #endif

        // Black/gray/white are ordinary ink, not a speaker palette. Let them
        // follow the reading theme (including a PDF cover with white lettering).
        let spread = max(red, green, blue) - min(red, green, blue)
        guard alpha > 0.01, spread > 0.025 else { return nil }
        return ReaderTextColor(
            red: Double(red), green: Double(green), blue: Double(blue), alpha: Double(alpha)
        )
    }

    private static func normalizedLine(
        in source: NSString,
        range: NSRange,
        sourceStyles: [ReaderTextStyleSpan],
        styleIndex: inout Int,
        bounds: CGRect?
    ) throws -> NormalizedLine {
        var builder = StyledBuilder()
        var sourceOffset = range.location
        var pendingSpace = false
        var pendingSpaceColor: ReaderTextColor?
        var endsWithSoftHyphen = false
        var scalarCount = 0

        for scalar in source.substring(with: range).unicodeScalars {
            scalarCount += 1
            if scalarCount.isMultiple(of: 4_096) { try Task.checkCancellation() }
            while styleIndex < sourceStyles.count,
                  NSMaxRange(sourceStyles[styleIndex].range) <= sourceOffset {
                styleIndex += 1
            }
            let color: ReaderTextColor?
            if styleIndex < sourceStyles.count,
               NSLocationInRange(sourceOffset, sourceStyles[styleIndex].range) {
                color = sourceStyles[styleIndex].color
            } else {
                color = nil
            }
            sourceOffset += scalar.value > 0xFFFF ? 2 : 1

            switch scalar.value {
            case 0, 0xFEFF, 0x200B:
                continue
            case 0x00AD:
                endsWithSoftHyphen = !builder.text.isEmpty
            default:
                if scalar.properties.isWhitespace {
                    pendingSpace = !builder.text.isEmpty
                    pendingSpaceColor = color
                } else {
                    if pendingSpace {
                        builder.append(" ", color: pendingSpaceColor)
                        pendingSpace = false
                    }
                    builder.append(String(scalar), color: color)
                    endsWithSoftHyphen = false
                }
            }
        }
        return NormalizedLine(
            content: builder,
            bounds: validBounds(bounds),
            endsWithSoftHyphen: endsWithSoftHyphen
        )
    }

    private static func shouldStartParagraph(
        _ line: NormalizedLine,
        after previous: NormalizedLine,
        layout: LineLayout
    ) -> Bool {
        // A discretionary hyphen is direct evidence that these physical lines
        // continue the same word, even if the continuation starts with color.
        if previous.endsWithSoftHyphen { return false }
        // A short accent + delimiter + neutral dialogue is a structural cue,
        // not a list of known names. A colored word at a wrapped line's start,
        // or a whole colored paragraph, is not sufficient evidence.
        if hasSpeakerPrefix(line, after: previous) {
            return true
        }
        guard let currentBounds = line.bounds, let previousBounds = previous.bounds else {
            return false
        }
        let advance = previousBounds.midY - currentBounds.midY
        if advance <= 0 { return true }
        if let typicalAdvance = layout.typicalAdvance,
           advance > typicalAdvance * 1.22 + 0.5 {
            return true
        }
        // Compare with the previous line, not the page's global leftmost ink.
        // Narration and dialogue may use different margins; a consistently
        // indented dialogue continuation is still the same paragraph.
        if currentBounds.minX - previousBounds.minX > max(currentBounds.height * 0.4, 3) {
            return true
        }
        if abs(currentBounds.height - previousBounds.height)
            > max(currentBounds.height, previousBounds.height) * 0.25 {
            return true
        }
        return false
    }

    private static func hasSpeakerPrefix(_ line: NormalizedLine, after previous: NormalizedLine) -> Bool {
        guard let prefix = line.content.styles.first,
              prefix.range.location == 0,
              prefix.range.length <= 32,
              prefix.range.length < line.content.length else { return false }

        if let previousStyle = previous.content.styles.last,
           NSMaxRange(previousStyle.range) == previous.content.length,
           previousStyle.color == prefix.color {
            return false
        }

        let text = line.content.text as NSString
        let prefixText = text.substring(with: prefix.range)
        var cursor = NSMaxRange(prefix.range)
        var hasDelimiter = prefixText.last?.isWhitespace == true
            || prefixText.last == ":" || prefixText.last == "："
        while cursor < text.length {
            let unit = text.character(at: cursor)
            let isSpace = UnicodeScalar(unit).map { $0.properties.isWhitespace } ?? false
            guard isSpace || unit == 0x003A || unit == 0xFF1A else { break }
            hasDelimiter = true
            cursor += 1
        }
        guard hasDelimiter, cursor < text.length else { return false }
        return !line.content.styles.contains { NSLocationInRange(cursor, $0.range) }
    }

    /// Enumerates UTF-16 line ranges without allocating an array for every line.
    private static func forEachLine(
        in text: NSString,
        _ receive: (NSRange, Bool) throws -> Bool
    ) throws {
        var lineStart = 0
        var cursor = 0
        while cursor < text.length {
            if cursor.isMultiple(of: 4_096) { try Task.checkCancellation() }
            let unit = text.character(at: cursor)
            switch unit {
            case 0x000A, 0x000D, 0x2028, 0x2029, 0x000C:
                let range = NSRange(location: lineStart, length: cursor - lineStart)
                guard try receive(range, unit == 0x2029 || unit == 0x000C) else { return }
                if unit == 0x000D, cursor + 1 < text.length,
                   text.character(at: cursor + 1) == 0x000A {
                    cursor += 1
                }
                lineStart = cursor + 1
            default:
                break
            }
            cursor += 1
        }
        _ = try receive(NSRange(location: lineStart, length: text.length - lineStart), false)
    }

    private static func validBounds(_ bounds: CGRect?) -> CGRect? {
        guard let bounds, !bounds.isNull, !bounds.isInfinite,
              bounds.origin.x.isFinite, bounds.origin.y.isFinite,
              bounds.width.isFinite, bounds.height.isFinite,
              bounds.width > 0, bounds.height > 0 else { return nil }
        return bounds
    }

    private struct LineLayout {
        var bounds: [NSRange: CGRect] = [:]
        var typicalAdvance: CGFloat?

        init(text: NSString, boundsForRange: ((NSRange) -> CGRect?)?) throws {
            guard let boundsForRange else { return }
            var orderedBounds: [CGRect] = []
            try forEachLine(in: text) { range, _ in
                if range.length > 0, let rect = validBounds(boundsForRange(range)) {
                    bounds[range] = rect
                    orderedBounds.append(rect)
                }
                // A bounded sample suffices for ordinary line leading.
                // Adversarial tiny-line pages must not allocate millions of rectangles.
                return orderedBounds.count < 512
            }
            guard !orderedBounds.isEmpty else { return }
            let heights = orderedBounds.map(\.height).sorted()
            let bodyHeight = heights[heights.count / 2]
            let bodyBounds = orderedBounds.filter { abs($0.height - bodyHeight) <= bodyHeight * 0.25 }
            typicalAdvance = zip(bodyBounds, bodyBounds.dropFirst()).compactMap { previous, next in
                let advance = previous.midY - next.midY
                guard advance >= bodyHeight * 0.85, advance <= bodyHeight * 4 else { return nil }
                return advance
            }.min()
        }
    }

    private struct NormalizedLine {
        let content: StyledBuilder
        let bounds: CGRect?
        let endsWithSoftHyphen: Bool
    }

    private struct StyledBuilder {
        var text = ""
        var styles: [ReaderTextStyleSpan] = []
        var length = 0

        mutating func append(_ value: String, color: ReaderTextColor?) {
            let addedLength = value.utf16.count
            if let color { appendStyle(color, at: length, length: addedLength) }
            text.append(value)
            length += addedLength
        }

        mutating func append(_ other: Self) {
            for style in other.styles {
                appendStyle(style.color, at: length + style.range.location, length: style.range.length)
            }
            text.append(other.text)
            length += other.length
        }

        private mutating func appendStyle(_ color: ReaderTextColor, at location: Int, length: Int) {
            guard length > 0 else { return }
            if let previous = styles.last,
               previous.color == color, NSMaxRange(previous.range) == location {
                styles[styles.count - 1] = ReaderTextStyleSpan(
                    range: NSRange(location: previous.range.location, length: previous.range.length + length),
                    color: color
                )
            } else {
                styles.append(ReaderTextStyleSpan(range: NSRange(location: location, length: length), color: color))
            }
        }
    }

    private static func needsSpace(between previous: String, and next: String) -> Bool {
        guard let last = previous.last, let first = next.first else { return false }
        if isEastAsianCharacter(last) || isEastAsianCharacter(first) { return false }
        if last == "-", previous.startIndex != previous.index(before: previous.endIndex),
           first.isLetter || first.isNumber { return false }
        if "([{“".contains(last) || ".,!?;:)]}%”".contains(first) { return false }
        return true
    }

    private static func isEastAsianCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x2E80 ... 0x303F, 0x3040 ... 0x312F, 0x31A0 ... 0x31BF,
                 0x31F0 ... 0x31FF, 0x3400 ... 0x4DBF, 0x4E00 ... 0x9FFF,
                 0xA960 ... 0xA97F, 0xAC00 ... 0xD7AF, 0xF900 ... 0xFAFF,
                 0xFF01 ... 0xFF60, 0x20000 ... 0x323AF:
                true
            default:
                false
            }
        }
    }
}
