import SwiftUI

struct PDFDocumentReaderView: View {
    let document: ReaderDocument
    @Binding var settings: ReaderDisplaySettings
    @Binding var location: PDFReadingLocation

    private let extractor: any PDFTextExtracting
    @State private var phase: ExtractionPhase = .idle
    @State private var retryID = UUID()
    @State private var extractedDocumentID: UUID?

    init(
        document: ReaderDocument,
        settings: Binding<ReaderDisplaySettings>,
        location: Binding<PDFReadingLocation>,
        extractor: any PDFTextExtracting = PDFTextExtractor()
    ) {
        self.document = document
        _settings = settings
        _location = location
        self.extractor = extractor
    }

    var body: some View {
        VStack(spacing: 0) {
            modeControl

            switch location.mode {
            case .reflow:
                reflowSurface

            case .original:
                PDFReaderView(
                    document: document,
                    settings: settings,
                    initialProgress: location.originalProgress,
                    onProgressChange: reportOriginalProgress
                )
            }
        }
        .task(id: ExtractionRequest(documentID: document.id, mode: location.mode, retryID: retryID)) {
            await extractTextIfNeeded()
        }
    }

    private var modeControl: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("PDF 阅读模式", selection: $location.mode) {
                ForEach(PDFReadingMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("reader.pdf.mode")

            Text(location.mode == .reflow
                 ? "保留文字强调色，可直接调字号；图片和扫描内容不做 OCR，请查看原版。"
                 : "保留 PDF 页面布局；要单独调整字号，请切换正文阅读。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(settings.theme.backgroundColor)
    }

    @ViewBuilder
    private var reflowSurface: some View {
        switch phase {
        case .idle, .loading:
            ReaderLoadingView(message: "正在提取 PDF 文字…")
                .accessibilityIdentifier("reader.pdf.extracting")

        case .ready(let content):
            VStack(spacing: 0) {
                if !content.pagesWithoutText.isEmpty {
                    missingPagesNotice(content.pagesWithoutText)
                }

                ReaderTextLayoutView(
                    content: content.textContent,
                    settings: settings,
                    initialLocation: location.reflowLocation,
                    initialProgress: location.reflowProgress,
                    onLocationChange: reportReflowLocation
                )

                Divider()

                ReaderFontSizeControls(settings: $settings)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .background(.bar)
            }
            .accessibilityIdentifier("reader.pdf.reflow")

        case .failed(let failure):
            ContentUnavailableView {
                Label(failure.title, systemImage: "doc.text.magnifyingglass")
            } description: {
                Text(failure.message)
            } actions: {
                Button("查看原版") {
                    location.mode = .original
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("reader.pdf.showOriginal")

                Button("重新提取") {
                    retryID = UUID()
                }
                .buttonStyle(.bordered)
            }
            .accessibilityIdentifier("reader.pdf.reflowUnavailable")
        }
    }

    private func missingPagesNotice(_ pageNumbers: [Int]) -> some View {
        let visiblePages = pageNumbers.prefix(6).map(String.init).joined(separator: "、")
        let suffix = pageNumbers.count > 6 ? "等 \(pageNumbers.count) 页" : "页"

        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Text("第 \(visiblePages) \(suffix)没有可提取文字，可能含图片或扫描内容，未纳入正文。")
                .font(.caption)
            Spacer(minLength: 0)
            Button("看原版") {
                location.mode = .original
            }
            .font(.caption.weight(.semibold))
            .fixedSize()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.08))
        .accessibilityIdentifier("reader.pdf.missingTextPages")
    }

    @MainActor
    private func extractTextIfNeeded() async {
        if extractedDocumentID != document.id {
            extractedDocumentID = document.id
            phase = .idle
        }
        guard location.mode == .reflow else {
            return
        }
        if case .ready = phase {
            return
        }

        phase = .loading
        do {
            let content = try await extractor.extract(document: document)
            try Task.checkCancellation()
            phase = .ready(content)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else {
                return
            }

            let title: String
            if let extractionError = error as? PDFTextExtractionError,
               case .noExtractableText = extractionError {
                title = "这份 PDF 没有可提取的文字"
            } else {
                title = "暂时无法重排这份 PDF"
            }
            phase = .failed(ExtractionFailure(title: title, message: error.localizedDescription))
        }
    }

    @MainActor
    private func reportReflowLocation(_ reflowLocation: TextReadingLocation) {
        location.updateReflowLocation(reflowLocation)
    }

    @MainActor
    private func reportOriginalProgress(_ progress: Double) {
        location.updateProgress(progress, for: .original)
    }
}

private extension PDFDocumentReaderView {
    enum ExtractionPhase {
        case idle
        case loading
        case ready(PDFReflowContent)
        case failed(ExtractionFailure)
    }

    struct ExtractionFailure {
        let title: String
        let message: String
    }

    struct ExtractionRequest: Hashable {
        let documentID: UUID
        let mode: PDFReadingMode
        let retryID: UUID
    }
}

#Preview("PDF 正文阅读") {
    PDFReaderPreview(hasText: true)
}

#Preview("PDF 无文字层") {
    PDFReaderPreview(hasText: false)
}

private struct PDFReaderPreview: View {
    let hasText: Bool
    @State private var settings = ReaderDisplaySettings.default
    @State private var location = PDFReadingLocation()

    var body: some View {
        PDFDocumentReaderView(
            document: ReaderDocument(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                title: "阅读样例",
                fileURL: URL(fileURLWithPath: "/preview/sample.pdf"),
                format: .pdf
            ),
            settings: $settings,
            location: $location,
            extractor: PreviewPDFTextExtractor(hasText: hasText)
        )
    }
}

private struct PreviewPDFTextExtractor: PDFTextExtracting {
    let hasText: Bool

    func extract(document: ReaderDocument) async throws -> PDFReflowContent {
        guard hasText else {
            throw PDFTextExtractionError.noExtractableText
        }
        return PDFReflowContent(
            textContent: ReaderTextContent(format: .pdf, blocks: [
                .heading(level: 1, text: "让文字适应屏幕"),
                .styledParagraph(ReaderStyledText(
                    text: "讲述者 正文阅读会保留原文件的文字强调色。调节下方的字号，文字会重新换行与分页，人名的颜色仍然保留。",
                    styles: [ReaderTextStyleSpan(
                        range: NSRange(location: 0, length: 3),
                        color: ReaderTextColor(red: 0.62, green: 0.20, blue: 0.16)
                    )]
                )),
                .paragraph("你的原文件保持不变。需要查看图片或原始布局时，可以随时切换回原版式。"),
            ]),
            pageCount: 2,
            pagesWithoutText: []
        )
    }
}
