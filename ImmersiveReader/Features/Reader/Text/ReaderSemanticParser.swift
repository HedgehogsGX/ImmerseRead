import Foundation

enum ReaderSemanticBlock: Hashable, Codable, Sendable {
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

    static let maximumParagraphLength = 8_000

    private static func parsePlainText(_ source: String) -> [ReaderSemanticBlock] {
        let lines = source.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        let usesBlankLineParagraphs = usesBlankLineParagraphs(lines)
        var blocks: [ReaderSemanticBlock] = []
        var paragraph: [Substring] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            let text = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            paragraph.removeAll(keepingCapacity: true)
            guard !text.isEmpty else { return }
            for piece in splitLongParagraph(text) {
                blocks.append(.paragraph(piece))
            }
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                flushParagraph()
            } else if isChapterHeading(trimmed) {
                flushParagraph()
                blocks.append(.heading(level: 2, text: trimmed))
            } else {
                paragraph.append(line)
                if !usesBlankLineParagraphs {
                    flushParagraph()
                }
            }
        }
        flushParagraph()
        return blocks
    }

    private static func usesBlankLineParagraphs(_ lines: [Substring]) -> Bool {
        var textLineCount = 0
        var blankLineCount = 0
        var pendingBlankLines = 0
        for line in lines {
            if line.allSatisfy(\.isWhitespace) {
                pendingBlankLines += 1
            } else {
                if textLineCount > 0 {
                    blankLineCount += pendingBlankLines
                }
                pendingBlankLines = 0
                textLineCount += 1
            }
        }
        guard textLineCount > 1 else { return true }
        return Double(blankLineCount) / Double(textLineCount) >= 0.1
    }

    private static var chapterHeadingPatterns: [Regex<Substring>] { [
        /^第[0-9零〇一二三四五六七八九十百千两]+[章节回卷部集篇](?:[\s：:、．.].*)?$/,
        /^(?:卷[0-9零〇一二三四五六七八九十百千两]+|序章|序言|前言|引子|楔子|尾声|后记|終章|终章|番外(?:篇)?)(?:[\s：:、．.].*)?$/,
        /^(?:Chapter|CHAPTER|Part|PART|Book|BOOK)\s+(?:[0-9]+|[IVXLCivxlc]+|[A-Za-z]+)(?:[\s:.\-–—].*)?$/,
        /^(?:Prologue|Epilogue|PROLOGUE|EPILOGUE|Interlude|INTERLUDE)(?:[\s:.\-–—].*)?$/,
    ] }

    static func isChapterHeading(_ line: String) -> Bool {
        guard line.count <= 40, !line.contains("\n") else { return false }
        return chapterHeadingPatterns.contains { line.wholeMatch(of: $0) != nil }
    }

    private static func splitLongParagraph(_ text: String) -> [String] {
        guard text.utf16.count > maximumParagraphLength else { return [text] }
        var pieces: [String] = []
        var current = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.utf16.count > maximumParagraphLength {
                if !current.isEmpty {
                    pieces.append(current)
                    current = ""
                }
                pieces.append(contentsOf: splitLongLine(line))
            } else if !current.isEmpty, current.utf16.count + line.utf16.count + 1 > maximumParagraphLength {
                pieces.append(current)
                current = String(line)
            } else {
                current = current.isEmpty ? String(line) : current + "\n" + line
            }
        }
        if !current.isEmpty {
            pieces.append(current)
        }
        return pieces
    }

    private static func splitLongLine(_ line: Substring) -> [String] {
        var pieces: [String] = []
        var current = ""
        var sentence = ""
        var currentLength = 0
        var sentenceLength = 0
        let sentenceTerminators: Set<Character> = ["。", "！", "？", "!", "?", ".", "…", "”", "\""]

        func flushSentence() {
            guard !sentence.isEmpty else { return }
            if !current.isEmpty, currentLength + sentenceLength > maximumParagraphLength {
                pieces.append(current)
                current = ""
                currentLength = 0
            }
            current += sentence
            currentLength += sentenceLength
            sentence = ""
            sentenceLength = 0
        }

        for character in line {
            let length = String(character).utf16.count
            if sentenceLength + length > maximumParagraphLength {
                flushSentence()
            }
            sentence.append(character)
            sentenceLength += length
            if sentenceTerminators.contains(character) || sentenceLength >= maximumParagraphLength {
                flushSentence()
            }
        }
        flushSentence()
        if !current.isEmpty {
            pieces.append(current)
        }
        return pieces
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
