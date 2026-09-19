import Foundation

struct DOCXConversionResult: Hashable, Sendable {
    let sanitizedHTML: String
    let plainText: String
    let readerContent: ReaderTextContent
    let warnings: [String]
}

@MainActor
protocol DOCXConverting {
    func convert(document: ReaderDocument) async throws -> DOCXConversionResult
}

enum DOCXConversionError: LocalizedError, Equatable {
    case unsupportedFormat(BookFormat)
    case notARegularFile
    case symbolicLinkNotSupported
    case fileUnavailable
    case emptyDocument
    case fileTooLarge(maximumBytes: Int64)
    case convertedContentTooLarge(maximumBytes: Int)
    case mammothResourceMissing
    case mammothResourceUnreadable
    case mammothRuntimeUnavailable
    case conversionFailed
    case malformedConversionResponse
    case sanitizationFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let format):
            String(localized: "暂不支持将 \(format.displayName) 作为 DOCX 读取。")
        case .notARegularFile:
            String(localized: "选择的项目不是可读取的文件。")
        case .symbolicLinkNotSupported:
            String(localized: "为保护本地文件安全，不能通过符号链接读取 DOCX。")
        case .fileUnavailable:
            String(localized: "无法读取 DOCX 文件，请确认文件仍然存在。")
        case .emptyDocument:
            String(localized: "DOCX 没有可显示的正文。")
        case .fileTooLarge(let maximumBytes):
            String(localized: "DOCX 超过 \(maximumBytes / 1_024 / 1_024) MB 的设备端转换限制。")
        case .convertedContentTooLarge(let maximumBytes):
            String(localized: "转换后的正文超过 \(maximumBytes / 1_024 / 1_024) MB 的显示限制。")
        case .mammothResourceMissing, .mammothResourceUnreadable, .mammothRuntimeUnavailable:
            String(localized: "应用内置的 DOCX 转换组件不可用，请重新安装或更新应用。")
        case .conversionFailed:
            String(localized: "DOCX 内容损坏，或包含当前转换器无法处理的结构。")
        case .malformedConversionResponse:
            String(localized: "DOCX 转换器返回了无法识别的结果。")
        case .sanitizationFailed:
            String(localized: "DOCX 正文无法完成安全清洗。")
        }
    }
}
