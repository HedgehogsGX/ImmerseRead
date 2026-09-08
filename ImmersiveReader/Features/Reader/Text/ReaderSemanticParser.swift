import Foundation

enum ReaderSemanticBlock: Hashable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case styledParagraph(ReaderStyledText)
    case unorderedListItem(depth: Int, text: String)
    case orderedListItem(depth: Int, ordinal: Int, text: String)
    case blockQuote(String)
    case code(String)
    case divider
}

enum ReaderSemanticParser {
    static func parse(_ source: String, format: BookFormat) -> [ReaderSemanticBlock] {
        switch format {
        case .plainText:
            parsePlainText(source)
        case .markdown:
            parseMarkdown(source)
        case .epub, .pdf, .docx, .legacyWord:
            []
        }
    }

    private static func parsePlainText(_ source: String) -> [ReaderSemanticBlock] {
        let lines = normalizedLines(source)
        var blocks: [ReaderSemanticBlock] = []
        var paragraph: [String] = []

        func flushParagraph() {
            let text = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                blocks.append(.paragraph(text))
            }
            paragraph.removeAll(keepingCapacity: true)
        }

        for line in lines {
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                flushParagraph()
            } else {
                paragraph.append(line)
            }
        }
        flushParagraph()
        return blocks
    }

    private static func parseMarkdown(_ source: String) -> [ReaderSemanticBlock] {
        let lines = normalizedLines(source)
        var blocks: [ReaderSemanticBlock] = []
        var paragraph: [String] = []
        var codeLines: [String] = []
        var fenceMarker: Character?

        func flushParagraph() {
            let text = paragraph.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                blocks.append(.paragraph(text))
            }
            paragraph.removeAll(keepingCapacity: true)
        }

        func flushCode() {
            blocks.append(.code(codeLines.joined(separator: "\n")))
            codeLines.removeAll(keepingCapacity: true)
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if let marker = fenceMarker {
                if isFence(trimmed, marker: marker) {
                    flushCode()
                    fenceMarker = nil
                } else {
                    codeLines.append(line)
                }
                continue
            }

            if let marker = openingFenceMarker(trimmed) {
                flushParagraph()
                fenceMarker = marker
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                continue
            }

            if let level = setextHeadingLevel(trimmed), !paragraph.isEmpty {
                let text = paragraph.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                paragraph.removeAll(keepingCapacity: true)
                blocks.append(.heading(level: level, text: text))
                continue
            }

            if let heading = hashHeading(trimmed) {
                flushParagraph()
                blocks.append(.heading(level: heading.level, text: heading.text))
                continue
            }

            if isDivider(trimmed) {
                flushParagraph()
                blocks.append(.divider)
                continue
            }

            if let item = unorderedListItem(in: line) {
                flushParagraph()
                blocks.append(.unorderedListItem(depth: item.depth, text: item.text))
                continue
            }

            if let item = orderedListItem(in: line) {
                flushParagraph()
                blocks.append(.orderedListItem(depth: item.depth, ordinal: item.ordinal, text: item.text))
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                let text = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                if !text.isEmpty {
                    blocks.append(.blockQuote(text))
                }
                continue
            }

            paragraph.append(trimmed)
        }

        flushParagraph()
        if fenceMarker != nil {
            flushCode()
        }
        return blocks
    }

    private static func normalizedLines(_ source: String) -> [String] {
        source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
    }

    private static func hashHeading(_ line: String) -> (level: Int, text: String)? {
        let count = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(count) else {
            return nil
        }

        let contentStart = line.index(line.startIndex, offsetBy: count)
        guard contentStart < line.endIndex, line[contentStart].isWhitespace else {
            return nil
        }

        let content = line[contentStart...]
            .trimmingCharacters(in: .whitespaces)
            .replacingTrailingMarkdownHashes()
        return content.isEmpty ? nil : (count, content)
    }

    private static func setextHeadingLevel(_ line: String) -> Int? {
        let compact = line.filter { !$0.isWhitespace }
        guard compact.count >= 3, let first = compact.first, compact.allSatisfy({ $0 == first }) else {
            return nil
        }
        return first == "=" ? 1 : (first == "-" ? 2 : nil)
    }

    private static func unorderedListItem(in line: String) -> (depth: Int, text: String)? {
        let indent = line.prefix(while: { $0 == " " || $0 == "\t" }).count
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2,
              let marker = trimmed.first,
              ["-", "*", "+"].contains(marker),
              trimmed.dropFirst().first?.isWhitespace == true else {
            return nil
        }

        let text = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : (max(0, indent / 2), text)
    }

    private static func orderedListItem(in line: String) -> (depth: Int, ordinal: Int, text: String)? {
        let indent = line.prefix(while: { $0 == " " || $0 == "\t" }).count
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let digits = trimmed.prefix(while: { $0.isNumber })
        guard !digits.isEmpty,
              let ordinal = Int(digits),
              let punctuationIndex = trimmed.index(trimmed.startIndex, offsetBy: digits.count, limitedBy: trimmed.endIndex),
              punctuationIndex < trimmed.endIndex,
              trimmed[punctuationIndex] == "." else {
            return nil
        }

        let textStart = trimmed.index(after: punctuationIndex)
        guard textStart < trimmed.endIndex, trimmed[textStart].isWhitespace else {
            return nil
        }

        let text = trimmed[textStart...].trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : (max(0, indent / 2), ordinal, text)
    }

    private static func openingFenceMarker(_ line: String) -> Character? {
        guard let first = line.first, first == "`" || first == "~" else {
            return nil
        }
        return isFence(line, marker: first) ? first : nil
    }

    private static func isFence(_ line: String, marker: Character) -> Bool {
        line.prefix(while: { $0 == marker }).count >= 3
    }

    private static func isDivider(_ line: String) -> Bool {
        let compact = line.filter { !$0.isWhitespace }
        guard compact.count >= 3, let marker = compact.first, ["-", "*", "_"].contains(marker) else {
            return false
        }
        return compact.allSatisfy { $0 == marker }
    }
}

private extension String {
    func replacingTrailingMarkdownHashes() -> String {
        var result = trimmingCharacters(in: .whitespaces)
        while result.last == "#" {
            result.removeLast()
        }
        return result.trimmingCharacters(in: .whitespaces)
    }
}
