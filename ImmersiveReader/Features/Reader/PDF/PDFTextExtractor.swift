import Foundation
import PDFKit

struct PDFReflowContent: Hashable, Codable, Sendable {
    let textContent: ReaderTextContent
    let pageCount: Int
    /// One-based source page numbers. Callers must disclose these omissions.
    let pagesWithoutText: [Int]
    /// Index of the first reflowed block taken from each zero-based source page.
    /// A page that contributed no text shares the index of the next page that
    /// did, so navigating to it lands on the text that follows it.
    let pageStartBlockIndices: [Int]

    init(
        textContent: ReaderTextContent,
        pageCount: Int,
        pagesWithoutText: [Int],
        pageStartBlockIndices: [Int] = []
    ) {
        self.textContent = textContent
        self.pageCount = pageCount
        self.pagesWithoutText = pagesWithoutText
        self.pageStartBlockIndices = pageStartBlockIndices
    }

    /// Where a source page begins in the reflowed text, so the contents list can
    /// move within the text instead of sending the reader to the original layout.
    /// `nil` when this content carries no page mapping at all.
    func blockIndex(forPage pageIndex: Int) -> Int? {
        guard pageStartBlockIndices.indices.contains(pageIndex),
              !textContent.blocks.isEmpty else {
            return nil
        }
        return min(pageStartBlockIndices[pageIndex], textContent.blocks.count - 1)
    }
}

protocol PDFTextExtracting: Sendable {
    func extract(document: ReaderDocument) async throws -> PDFReflowContent
}

/// Extracts text already present in a PDF; it does not perform OCR or infer column order.
struct PDFTextExtractor: PDFTextExtracting {
    /// Identifies the extraction output format for on-disk caches. Bump it whenever
    /// the extractor or normalizer would produce different blocks for the same file.
    static let extractionVersion = 2

    static let defaultMaximumFileSize = DocumentFileLimits.pdfMaximumBytes
    /// Raw extracted text budget. Sized so the paragraph cap below is what a
    /// long book actually runs into, rather than this.
    static let defaultMaximumExtractedUTF8Bytes = 64 * 1_024 * 1_024
    static let defaultMaximumPageCount = 5_000
    static let defaultMaximumParagraphCount = 500_000
    static let defaultMaximumStyleRunCount = PDFStyledTextNormalizer.defaultMaximumStyleRunCount

    private let maximumFileSize: Int64
    private let maximumExtractedUTF8Bytes: Int
    private let maximumPageCount: Int
    private let maximumParagraphCount: Int
    private let maximumStyleRunCount: Int

    init(
        maximumFileSize: Int64 = PDFTextExtractor.defaultMaximumFileSize,
        maximumExtractedUTF8Bytes: Int = PDFTextExtractor.defaultMaximumExtractedUTF8Bytes,
        maximumPageCount: Int = PDFTextExtractor.defaultMaximumPageCount,
        maximumParagraphCount: Int = PDFTextExtractor.defaultMaximumParagraphCount,
        maximumStyleRunCount: Int = PDFTextExtractor.defaultMaximumStyleRunCount
    ) {
        self.maximumFileSize = max(1, maximumFileSize)
        self.maximumExtractedUTF8Bytes = max(1, maximumExtractedUTF8Bytes)
        self.maximumPageCount = max(1, maximumPageCount)
        self.maximumParagraphCount = max(1, maximumParagraphCount)
        self.maximumStyleRunCount = max(1, maximumStyleRunCount)
    }

    func extract(document: ReaderDocument) async throws -> PDFReflowContent {
        try Task.checkCancellation()
        guard document.format == .pdf else {
            throw PDFTextExtractionError.unsupportedFormat(document.format)
        }

        // PDFDocument and PDFPage never leave this synchronous worker. In particular,
        // they are not shared with the main-actor PDFView used for original layout.
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try autoreleasepool {
                try self.extractFile(at: document.fileURL)
            }
        }

        return try await withTaskCancellationHandler {
            let result = try await worker.value
            try Task.checkCancellation()
            return result
        } onCancel: {
            worker.cancel()
        }
    }

    private func extractFile(at fileURL: URL) throws -> PDFReflowContent {
        guard fileURL.isFileURL else {
            throw PDFTextExtractionError.notARegularFile
        }

        let isAccessing = fileURL.startAccessingSecurityScopedResource()
        defer {
            if isAccessing {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }

        try validateFile(at: fileURL)
        try Task.checkCancellation()
        guard let pdfDocument = PDFDocument(url: fileURL) else {
            throw PDFTextExtractionError.invalidDocument
        }
        guard !pdfDocument.isLocked else {
            throw PDFTextExtractionError.passwordProtected
        }
        guard pdfDocument.allowsCopying else {
            throw PDFTextExtractionError.copyingNotAllowed
        }

        let pageCount = pdfDocument.pageCount
        guard pageCount > 0 else {
            throw PDFTextExtractionError.invalidDocument
        }
        guard pageCount <= maximumPageCount else {
            throw PDFTextExtractionError.tooManyPages(maximumPages: maximumPageCount)
        }

        var blocks: [ReaderSemanticBlock] = []
        var pagesWithoutText: [Int] = []
        var pageStartBlockIndices: [Int] = []
        pageStartBlockIndices.reserveCapacity(pageCount)
        var extractedUTF8Bytes = 0
        var extractedStyleRunCount = 0

        for pageIndex in 0 ..< pageCount {
            try Task.checkCancellation()
            let previousBlockCount = blocks.count
            pageStartBlockIndices.append(previousBlockCount)
            try autoreleasepool {
                guard let page = pdfDocument.page(at: pageIndex) else {
                    throw PDFTextExtractionError.invalidPage(pageNumber: pageIndex + 1)
                }
                // PDFKit's synchronous extraction cannot be interrupted here. Our
                // cancellation and size checks apply after this call returns, not
                // to PDFKit's own transient allocations while parsing this page.
                let source = page.attributedString ?? NSAttributedString(string: page.string ?? "")
                try Task.checkCancellation()

                // Budget raw output, not only the smaller normalized result.
                let pageUTF8Bytes = source.string.utf8.count
                guard pageUTF8Bytes <= maximumExtractedUTF8Bytes - extractedUTF8Bytes else {
                    throw PDFTextExtractionError.extractedTextTooLarge(
                        maximumBytes: maximumExtractedUTF8Bytes
                    )
                }
                extractedUTF8Bytes += pageUTF8Bytes

                try PDFStyledTextNormalizer.forEachParagraph(
                    in: source,
                    boundsForRange: { range in
                        guard range.length > 0,
                              NSMaxRange(range) <= page.numberOfCharacters else { return nil }
                        return page.selection(for: range)?.bounds(for: page)
                    },
                    maximumStyleRunCount: maximumStyleRunCount
                ) { paragraph in
                    guard blocks.count < maximumParagraphCount else {
                        throw PDFTextExtractionError.tooManyParagraphs(
                            maximumParagraphs: maximumParagraphCount
                        )
                    }
                    guard paragraph.styles.count <= maximumStyleRunCount - extractedStyleRunCount else {
                        throw PDFTextExtractionError.tooManyStyleRuns(maximumRuns: maximumStyleRunCount)
                    }
                    extractedStyleRunCount += paragraph.styles.count
                    if paragraph.styles.isEmpty {
                        blocks.append(.paragraph(paragraph.text))
                    } else {
                        blocks.append(.styledParagraph(paragraph))
                    }
                }
            }
            if blocks.count == previousBlockCount {
                pagesWithoutText.append(pageIndex + 1)
            }
        }

        try Task.checkCancellation()
        guard !blocks.isEmpty else {
            throw PDFTextExtractionError.noExtractableText
        }

        return PDFReflowContent(
            textContent: ReaderTextContent(format: .pdf, blocks: blocks),
            pageCount: pageCount,
            pagesWithoutText: pagesWithoutText,
            pageStartBlockIndices: pageStartBlockIndices
        )
    }

    private func validateFile(at fileURL: URL) throws {
        do {
            let values = try fileURL.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
            )
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw PDFTextExtractionError.notARegularFile
            }
            guard let fileSize = values.fileSize, fileSize > 0 else {
                throw PDFTextExtractionError.invalidDocument
            }
            guard Int64(fileSize) <= maximumFileSize else {
                throw PDFTextExtractionError.fileTooLarge(maximumBytes: maximumFileSize)
            }

            let handle = try FileHandle(forReadingFrom: fileURL)
            defer { try? handle.close() }
            let signature = try handle.read(upToCount: 5)
            guard signature == Data("%PDF-".utf8) else {
                throw PDFTextExtractionError.invalidDocument
            }
        } catch let error as PDFTextExtractionError {
            throw error
        } catch {
            throw PDFTextExtractionError.unreadableFile
        }
    }
}

enum PDFTextExtractionError: LocalizedError, Equatable, Sendable {
    case unsupportedFormat(BookFormat)
    case notARegularFile
    case unreadableFile
    case invalidDocument
    case passwordProtected
    case copyingNotAllowed
    case fileTooLarge(maximumBytes: Int64)
    case tooManyPages(maximumPages: Int)
    case tooManyParagraphs(maximumParagraphs: Int)
    case tooManyStyleRuns(maximumRuns: Int)
    case extractedTextTooLarge(maximumBytes: Int)
    case invalidPage(pageNumber: Int)
    case noExtractableText

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let format):
            String(localized: "无法将 \(format.displayName) 按 PDF 提取正文。")
        case .notARegularFile:
            String(localized: "选择的项目不是可读取的 PDF 文件。")
        case .unreadableFile:
            String(localized: "暂时无法读取 PDF，请确认文件仍然存在且可以访问。")
        case .invalidDocument:
            String(localized: "PDF 已损坏或没有可读取的页面。")
        case .passwordProtected:
            String(localized: "这份 PDF 需要密码，目前无法提取正文。可以尝试查看原版式。")
        case .copyingNotAllowed:
            String(localized: "这份 PDF 不允许复制正文，无法进行文字重排。可以查看原版式。")
        case .fileTooLarge(let maximumBytes):
            String(localized: "PDF 超过 \(maximumBytes / 1_024 / 1_024) MB 的文字重排限制，可以查看原版式。")
        case .tooManyPages(let maximumPages):
            String(localized: "PDF 超过 \(maximumPages) 页，暂不支持文字重排。可以查看原版式。")
        case .tooManyParagraphs(let maximumParagraphs):
            String(localized: "PDF 正文超过 \(maximumParagraphs) 段，暂不支持文字重排。可以查看原版式。")
        case .tooManyStyleRuns(let maximumRuns):
            String(localized: "PDF 的颜色片段超过 \(maximumRuns) 处，暂不支持文字重排。可以查看原版式。")
        case .extractedTextTooLarge(let maximumBytes):
            String(localized: "PDF 正文超过 \(maximumBytes / 1_024 / 1_024) MB 的文字重排限制，可以查看原版式。")
        case .invalidPage(let pageNumber):
            String(localized: "无法读取 PDF 第 \(pageNumber) 页，未继续生成不完整正文。可以尝试查看原版式。")
        case .noExtractableText:
            String(localized: "这份 PDF 没有可提取的正文，可能是扫描件或图片。当前尚未提供 OCR，请查看原版式。")
        }
    }
}

/// Compatibility entry point for plain-text cleanup. Use the same normalizer as
/// styled PDF extraction so whitespace and soft-hyphen tests exercise production logic.
enum PDFTextNormalizer {
    static func paragraphs(
        from source: String,
        maximumParagraphCount: Int = PDFTextExtractor.defaultMaximumParagraphCount
    ) throws -> [String] {
        try PDFStyledTextNormalizer.paragraphs(
            from: NSAttributedString(string: source),
            maximumParagraphCount: maximumParagraphCount
        ).map(\.text)
    }

    static func forEachParagraph(
        in source: String,
        _ receive: (String) throws -> Void
    ) throws {
        try PDFStyledTextNormalizer.forEachParagraph(in: NSAttributedString(string: source)) {
            try receive($0.text)
        }
    }
}
