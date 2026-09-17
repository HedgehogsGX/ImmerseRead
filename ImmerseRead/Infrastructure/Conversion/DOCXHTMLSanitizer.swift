import Foundation
import SwiftSoup

enum DOCXHTMLSanitizer {
    struct Output: Hashable, Sendable {
        let html: String
        let plainText: String
        let blocks: [ReaderSemanticBlock]
    }

    /// Sanitizes Mammoth output before any converted content reaches a reader surface.
    ///
    /// The allowlist intentionally contains no attributes. Links therefore keep only their
    /// visible label, while URLs, styles, identifiers and event handlers are discarded.
    static func sanitize(_ source: String, maximumUTF8Bytes: Int) throws -> Output {
        guard source.utf8.count <= maximumUTF8Bytes else {
            throw DOCXConversionError.convertedContentTooLarge(maximumBytes: maximumUTF8Bytes)
        }

        let allowlist = try Whitelist.none()
            .addTags(
                "a",
                "b",
                "blockquote",
                "br",
                "caption",
                "code",
                "dd",
                "dl",
                "dt",
                "em",
                "h1",
                "h2",
                "h3",
                "h4",
                "h5",
                "h6",
                "hr",
                "i",
                "li",
                "ol",
                "p",
                "pre",
                "s",
                "strike",
                "strong",
                "sub",
                "sup",
                "table",
                "tbody",
                "td",
                "tfoot",
                "th",
                "thead",
                "tr",
                "u",
                "ul"
            )

        guard let html = try SwiftSoup.clean(source, "", allowlist) else {
            throw DOCXConversionError.sanitizationFailed
        }
        guard html.utf8.count <= maximumUTF8Bytes else {
            throw DOCXConversionError.convertedContentTooLarge(maximumBytes: maximumUTF8Bytes)
        }

        let blocks = try semanticBlocks(from: html)
        return Output(
            html: html,
            plainText: plainText(from: blocks),
            blocks: blocks
        )
    }

    private static func semanticBlocks(from html: String) throws -> [ReaderSemanticBlock] {
        let document = try SwiftSoup.parseBodyFragment(html)
        guard let body = document.body() else {
            return []
        }

        var blocks: [ReaderSemanticBlock] = []
        for element in body.children().array() {
            try append(element, listDepth: 0, to: &blocks)
        }
        return blocks
    }

    private static func append(
        _ element: Element,
        listDepth: Int,
        to blocks: inout [ReaderSemanticBlock]
    ) throws {
        let tag = element.tagName().lowercased()

        if let headingLevel = headingLevel(for: tag) {
            appendIfPresent(try normalizedText(in: element)) {
                blocks.append(.heading(level: headingLevel, text: $0))
            }
            return
        }

        switch tag {
        case "p", "dt", "dd":
            appendIfPresent(try normalizedText(in: element)) {
                blocks.append(.paragraph($0))
            }

        case "ul":
            try appendList(element, ordered: false, depth: listDepth, to: &blocks)

        case "ol":
            try appendList(element, ordered: true, depth: listDepth, to: &blocks)

        case "blockquote":
            appendIfPresent(try normalizedText(in: element)) {
                blocks.append(.blockQuote($0))
            }

        case "pre":
            appendIfPresent(try normalizedText(in: element)) {
                blocks.append(.code($0))
            }

        case "table":
            try appendTable(element, to: &blocks)

        case "hr":
            blocks.append(.divider)

        case "br":
            break

        default:
            let children = element.children().array()
            if children.isEmpty {
                appendIfPresent(try normalizedText(in: element)) {
                    blocks.append(.paragraph($0))
                }
            } else {
                for child in children {
                    try append(child, listDepth: listDepth, to: &blocks)
                }
            }
        }
    }

    private static func appendList(
        _ list: Element,
        ordered: Bool,
        depth: Int,
        to blocks: inout [ReaderSemanticBlock]
    ) throws {
        var ordinal = 1
        for item in list.children().array() where item.tagName().lowercased() == "li" {
            let text = try listItemText(item)
            if !text.isEmpty {
                if ordered {
                    blocks.append(.orderedListItem(depth: depth, ordinal: ordinal, text: text))
                } else {
                    blocks.append(.unorderedListItem(depth: depth, text: text))
                }
            }

            for child in item.children().array() {
                switch child.tagName().lowercased() {
                case "ul":
                    try appendList(child, ordered: false, depth: depth + 1, to: &blocks)
                case "ol":
                    try appendList(child, ordered: true, depth: depth + 1, to: &blocks)
                default:
                    continue
                }
            }
            ordinal += 1
        }
    }

    private static func listItemText(_ item: Element) throws -> String {
        let fragment = try SwiftSoup.parseBodyFragment(try item.html())
        for nestedList in try fragment.select("ul, ol").array() {
            try nestedList.remove()
        }
        return try normalizedText(in: fragment)
    }

    private static func appendTable(
        _ table: Element,
        to blocks: inout [ReaderSemanticBlock]
    ) throws {
        if let caption = table.children().array().first(where: {
            $0.tagName().lowercased() == "caption"
        }) {
            appendIfPresent(try normalizedText(in: caption)) {
                blocks.append(.paragraph($0))
            }
        }

        for row in try table.select("tr").array() {
            let cells = try row.children().array()
                .filter { ["th", "td"].contains($0.tagName().lowercased()) }
                .map { try normalizedText(in: $0) }
                .filter { !$0.isEmpty }
            if !cells.isEmpty {
                blocks.append(.paragraph(cells.joined(separator: "\t")))
            }
        }
    }

    private static func normalizedText(in element: Element) throws -> String {
        try normalizedWhitespace(element.text(trimAndNormaliseWhitespace: false))
    }

    private static func normalizedText(in document: Document) throws -> String {
        try normalizedWhitespace(document.text(trimAndNormaliseWhitespace: false))
    }

    private static func normalizedWhitespace(_ source: String) -> String {
        source
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private static func appendIfPresent(
        _ text: String,
        append: (String) -> Void
    ) {
        if !text.isEmpty {
            append(text)
        }
    }

    private static func headingLevel(for tag: String) -> Int? {
        guard tag.count == 2, tag.first == "h", let last = tag.last,
              let level = Int(String(last)), (1 ... 6).contains(level) else {
            return nil
        }
        return level
    }

    private static func plainText(from blocks: [ReaderSemanticBlock]) -> String {
        blocks.map { block in
            switch block {
            case .heading(_, let text), .paragraph(let text), .blockQuote(let text), .code(let text):
                text
            case .styledParagraph(let value):
                value.text
            case .unorderedListItem(let depth, let text):
                String(repeating: "  ", count: depth) + "• " + text
            case .orderedListItem(let depth, let ordinal, let text):
                String(repeating: "  ", count: depth) + "\(ordinal). " + text
            case .divider:
                "———"
            }
        }
        .joined(separator: "\n\n")
    }
}
