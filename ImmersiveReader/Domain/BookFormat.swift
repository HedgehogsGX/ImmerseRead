import Foundation

enum BookFormat: String, CaseIterable, Codable, Hashable, Sendable {
    case epub
    case pdf
    case txt
    case md
    case markdown
    case docx
    case doc

    init?(fileExtension: String) {
        let normalizedExtension = fileExtension
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()

        self.init(rawValue: normalizedExtension)
    }

    var preferredFileExtension: String {
        switch self {
        case .markdown:
            "markdown"
        default:
            rawValue
        }
    }

    var isReflowable: Bool {
        switch self {
        case .epub, .txt, .md, .markdown, .docx:
            true
        case .pdf, .doc:
            false
        }
    }

    var isPlainText: Bool {
        switch self {
        case .txt, .md, .markdown:
            true
        case .epub, .pdf, .docx, .doc:
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
