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
    case storageFailure(description: String)
}

extension BookImportError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .sourceMustBeFileURL:
            "只能导入本地文件。"
        case .sourceUnavailable:
            "无法访问所选文件。"
        case .sourceIsNotRegularFile:
            "所选项目不是普通文件。"
        case .symbolicLinksAreNotSupported:
            "不支持导入符号链接。"
        case .emptyFile:
            "文件内容为空。"
        case let .fileTooLarge(actualBytes, maximumBytes):
            "文件大小为 \(actualBytes) 字节，超过 \(maximumBytes) 字节的导入上限。"
        case let .unsupportedFormat(fileExtension):
            fileExtension.isEmpty
                ? "无法识别没有扩展名的文件。"
                : "暂不支持 .\(fileExtension) 文件。"
        case let .fileSignatureMismatch(expectedFormat):
            "文件内容与 .\(expectedFormat.preferredFileExtension) 扩展名不匹配。"
        case let .invalidArchive(expectedFormat):
            "文件不是结构完整的 .\(expectedFormat.preferredFileExtension) 文档。"
        case let .unsafeArchive(description):
            "压缩文档不安全：\(description)"
        case .invalidTextEncoding:
            "文本不是有效的 UTF-8，或没有使用 BOM 标记 UTF-16 编码。"
        case .duplicate:
            "书库中已经存在内容相同的文件。"
        case .storedFileMissing:
            "书籍原文件已丢失。"
        case .unsafeStoredPath:
            "书籍存储路径不安全。"
        case .identifierCollision:
            "无法为导入文件分配唯一标识。"
        case let .storageFailure(description):
            "保存文件失败：\(description)"
        }
    }
}
