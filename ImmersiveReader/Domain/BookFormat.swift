import Foundation
import UniformTypeIdentifiers

/// The single description of every document format the app accepts.
///
/// Raw values are persisted by SwiftData, so they never change. Everything
/// else the app knows about a format (accepted extensions, labels, which
/// reader features apply) is derived from here.
enum BookFormat: String, CaseIterable, Codable, Hashable, Sendable {
    case epub
    case pdf
    case plainText = "txt"
    case markdown = "md"
    case docx
    case legacyWord = "doc"

    /// Accepts persisted raw values as well as any accepted file extension.
    /// Earlier releases stored `markdown` for `.markdown` files.
    init?(rawValue: String) {
        self.init(fileExtension: rawValue)
    }

    init?(fileExtension: String) {
        let normalizedExtension = fileExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()

        guard let format = Self.allCases.first(where: {
            $0.fileExtensions.contains(normalizedExtension)
        }) else {
            return nil
        }
        self = format
    }

    /// Accepted file extensions, canonical first.
    var fileExtensions: [String] {
        switch self {
        case .epub:
            ["epub"]
        case .pdf:
            ["pdf"]
        case .plainText:
            ["txt", "text"]
        case .markdown:
            ["md", "markdown", "mdown", "mkd"]
        case .docx:
            ["docx"]
        case .legacyWord:
            ["doc"]
        }
    }

    var preferredFileExtension: String {
        fileExtensions[0]
    }

    static var importContentTypes: [UTType] {
        allCases.flatMap(\.fileExtensions).compactMap { UTType(filenameExtension: $0) }
    }

    var displayName: String {
        switch self {
        case .epub:
            "EPUB"
        case .pdf:
            "PDF"
        case .plainText:
            "TXT"
        case .markdown:
            "Markdown"
        case .docx:
            "DOCX"
        case .legacyWord:
            "DOC"
        }
    }

    /// Compact badge for the library shelf.
    var shortLabel: String {
        self == .markdown ? "MD" : displayName
    }

    var isPlainText: Bool {
        switch self {
        case .plainText, .markdown:
            true
        case .epub, .pdf, .docx, .legacyWord:
            false
        }
    }

    /// Whether the file itself can carry a cover the app knows how to find:
    /// a declared cover, an embedded picture, or a first page worth rendering.
    var canCarryCover: Bool {
        switch self {
        case .epub, .pdf, .docx:
            true
        case .plainText, .markdown, .legacyWord:
            false
        }
    }

    /// Whether the reader can change font size and line height for this format.
    var supportsTypography: Bool {
        switch self {
        case .plainText, .markdown, .epub, .docx, .pdf:
            true
        case .legacyWord:
            false
        }
    }
}

enum BookTextEncoding: String, Codable, Hashable, Sendable {
    case utf8
    case utf16LittleEndian
    case utf16BigEndian

    var foundationEncoding: String.Encoding {
        switch self {
        case .utf8:
            .utf8
        case .utf16LittleEndian:
            .utf16LittleEndian
        case .utf16BigEndian:
            .utf16BigEndian
        }
    }
}
