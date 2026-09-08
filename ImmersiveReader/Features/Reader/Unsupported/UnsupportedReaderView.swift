import SwiftUI

struct UnsupportedReaderView: View {
    let document: ReaderDocument

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: "doc.badge.ellipsis")
        } description: {
            Text(message)
        }
        .accessibilityIdentifier("reader.unsupported.\(document.format.rawValue)")
    }

    private var title: String {
        switch document.format {
        case .docx:
            "DOCX 尚未转换"
        case .legacyWord:
            "暂不支持旧版 DOC 阅读"
        case .epub, .pdf, .plainText, .markdown:
            "暂不支持此文档"
        }
    }

    private var message: String {
        switch document.format {
        case .docx:
            "导入层需要先将 DOCX 清洗并转换为内部 EPUB，再把转换后的文件交给阅读器。原始 DOCX 会继续保留。"
        case .legacyWord:
            "请先在 Word 或 Pages 中另存为 DOCX 或 PDF 后重新导入。首版不会在设备上解析旧的二进制 DOC 格式。"
        case .epub, .pdf, .plainText, .markdown:
            "当前阅读器无法打开这个文档。"
        }
    }
}
