import Foundation

enum BookImportError: Error, Equatable, Sendable {
    case sourceMustBeFileURL
    case sourceUnavailable
    case sourceIsNotRegularFile
    case symbolicLinksAreNotSupported
    case emptyFile
    case fileTooLarge(actualBytes: Int64, maximumBytes: Int64)
    case unsupportedFormat(fileExtension: String)
    case fileSignatureMismatch(expectedFormat: BookFormat)
    case invalidArchive(expectedFormat: BookFormat)
    case unsafeArchive(description: String)
    case invalidTextEncoding
    case duplicate(contentHash: String)
    case storedFileMissing
    case unsafeStoredPath
    case identifierCollision
    case unusableCoverImage
    case storageFailure(description: String)
}

extension BookImportError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .sourceMustBeFileURL:
            String(localized: "只能导入本地文件。")
        case .sourceUnavailable:
            String(localized: "无法访问所选文件。")
        case .sourceIsNotRegularFile:
            String(localized: "所选项目不是普通文件。")
        case .symbolicLinksAreNotSupported:
            String(localized: "不支持导入符号链接。")
        case .emptyFile:
            String(localized: "文件内容为空。")
        case let .fileTooLarge(actualBytes, maximumBytes):
            String(localized: "文件大小为 \(actualBytes) 字节，超过 \(maximumBytes) 字节的导入上限。")
        case let .unsupportedFormat(fileExtension):
            fileExtension.isEmpty
                ? String(localized: "无法识别没有扩展名的文件。")
                : String(localized: "暂不支持 .\(fileExtension) 文件。")
        case let .fileSignatureMismatch(expectedFormat):
            String(localized: "文件内容与 .\(expectedFormat.preferredFileExtension) 扩展名不匹配。")
        case let .invalidArchive(expectedFormat):
            String(localized: "文件不是结构完整的 .\(expectedFormat.preferredFileExtension) 文档。")
        case let .unsafeArchive(description):
            String(localized: "压缩文档不安全：\(description)")
        case .invalidTextEncoding:
            String(localized: "文本不是有效的 UTF-8，或没有使用 BOM 标记 UTF-16 编码。")
        case .duplicate:
            String(localized: "书库中已经存在内容相同的文件。")
        case .storedFileMissing:
            String(localized: "书籍原文件已丢失。")
        case .unsafeStoredPath:
            String(localized: "书籍存储路径不安全。")
        case .identifierCollision:
            String(localized: "无法为导入文件分配唯一标识。")
        case .unusableCoverImage:
            String(localized: "这张图片无法用作封面，请换一张。")
        case let .storageFailure(description):
            String(localized: "保存文件失败：\(description)")
        }
    }
}
