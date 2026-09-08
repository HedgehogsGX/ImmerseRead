import Foundation

struct ReaderTextContent: Hashable, Sendable {
    let format: BookFormat
    let blocks: [ReaderSemanticBlock]
}

protocol ReaderTextLoading: Sendable {
    func load(document: ReaderDocument) async throws -> ReaderTextContent
}

struct LocalReaderTextLoader: ReaderTextLoading {
    static let maximumFileSize = Int(DocumentFileLimits.plainTextMaximumBytes)

    func load(document: ReaderDocument) async throws -> ReaderTextContent {
        guard document.format == .plainText || document.format == .markdown else {
            throw ReaderTextLoadingError.unsupportedFormat(document.format)
        }

        let data = try await Task.detached(priority: .userInitiated) {
            try Self.readData(from: document.fileURL)
        }.value

        guard !data.isEmpty else {
            throw ReaderTextLoadingError.emptyDocument
        }

        guard let source = Self.decode(data) else {
            throw ReaderTextLoadingError.unknownTextEncoding
        }

        try Task.checkCancellation()
        let blocks = ReaderSemanticParser.parse(source, format: document.format)
        guard !blocks.isEmpty else {
            throw ReaderTextLoadingError.emptyDocument
        }

        return ReaderTextContent(format: document.format, blocks: blocks)
    }

    private static func readData(from url: URL) throws -> Data {
        let isAccessingSecurityScopedResource = url.startAccessingSecurityScopedResource()
        defer {
            if isAccessingSecurityScopedResource {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else {
            throw ReaderTextLoadingError.notARegularFile
        }

        if let fileSize = values.fileSize, fileSize > maximumFileSize {
            throw ReaderTextLoadingError.fileTooLarge(maximumBytes: maximumFileSize)
        }

        return try Data(contentsOf: url, options: .mappedIfSafe)
    }

    private static func decode(_ data: Data) -> String? {
        if let value = String(data: data, encoding: .utf8) {
            return value.removingUnicodeByteOrderMark
        }

        for encoding in [String.Encoding.utf16, .utf16LittleEndian, .utf16BigEndian] {
            if let value = String(data: data, encoding: encoding) {
                return value.removingUnicodeByteOrderMark
            }
        }

        return nil
    }
}

enum ReaderTextLoadingError: LocalizedError, Equatable {
    case unsupportedFormat(BookFormat)
    case notARegularFile
    case fileTooLarge(maximumBytes: Int)
    case unknownTextEncoding
    case emptyDocument

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let format):
            "暂不支持将 \(format.displayName) 作为纯文本读取。"
        case .notARegularFile:
            "选择的项目不是可读取的文件。"
        case .fileTooLarge(let maximumBytes):
            "文本文件超过 \(maximumBytes / 1_024 / 1_024) MB 的首版限制。"
        case .unknownTextEncoding:
            "无法识别文本编码；当前支持 UTF-8 和 UTF-16。"
        case .emptyDocument:
            "文档没有可显示的正文。"
        }
    }
}

private extension String {
    var removingUnicodeByteOrderMark: String {
        first == "\u{FEFF}" ? String(dropFirst()) : self
    }
}
