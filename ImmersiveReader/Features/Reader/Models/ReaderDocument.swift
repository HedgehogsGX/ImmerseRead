import Foundation

/// A reader input that is intentionally independent from the library persistence model.
struct ReaderDocument: Identifiable, Hashable, Sendable {
    let id: UUID
    let title: String
    let fileURL: URL
    let format: ReaderFormat

    init(id: UUID, title: String, fileURL: URL, format: ReaderFormat) {
        self.id = id
        self.title = title
        self.fileURL = fileURL
        self.format = format
    }

    /// Creates a document when the file extension maps to a supported import format.
    init?(id: UUID, title: String, fileURL: URL) {
        guard let format = ReaderFormat(fileURL: fileURL) else {
            return nil
        }

        self.init(id: id, title: title, fileURL: fileURL, format: format)
    }
}

enum ReaderFormat: String, CaseIterable, Hashable, Sendable {
    case epub
    case pdf
    case plainText
    case markdown
    case docx
    case legacyWord

    init?(fileURL: URL) {
        self.init(fileExtension: fileURL.pathExtension)
    }

    init?(fileExtension: String) {
        let normalizedExtension = fileExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()

        switch normalizedExtension {
        case "epub":
            self = .epub
        case "pdf":
            self = .pdf
        case "txt", "text":
            self = .plainText
        case "md", "markdown", "mdown", "mkd":
            self = .markdown
        case "docx":
            self = .docx
        case "doc":
            self = .legacyWord
        default:
            return nil
        }
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

    var supportsTypography: Bool {
        switch self {
        case .plainText, .markdown, .epub, .docx, .pdf:
            true
        case .legacyWord:
            false
        }
    }
}
