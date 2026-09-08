import Foundation

enum DocumentFileLimits {
    static let plainTextMaximumBytes: Int64 = 8 * 1_024 * 1_024
    static let docxMaximumBytes: Int64 = 32 * 1_024 * 1_024
    static let pdfMaximumBytes: Int64 = 256 * 1_024 * 1_024
    static let epubMaximumBytes: Int64 = 512 * 1_024 * 1_024
    static let legacyWordMaximumBytes: Int64 = 128 * 1_024 * 1_024
    static let generalMaximumBytes = epubMaximumBytes

    static func maximumImportBytes(for format: BookFormat) -> Int64 {
        switch format {
        case .txt, .md, .markdown:
            plainTextMaximumBytes
        case .docx:
            docxMaximumBytes
        case .epub:
            epubMaximumBytes
        case .pdf:
            pdfMaximumBytes
        case .doc:
            legacyWordMaximumBytes
        }
    }
}
