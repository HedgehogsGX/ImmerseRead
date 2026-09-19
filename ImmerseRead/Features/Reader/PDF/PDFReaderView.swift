import PDFKit
import SwiftUI
import Combine

struct PDFReaderView: View {
    let document: ReaderDocument
    let settings: ReaderDisplaySettings
    let initialProgress: Double
    let onProgressChange: (Double) -> Void
    let navigationModel: ReaderNavigationModel?

    @State private var phase: LoadPhase = .idle
    @State private var reloadID = UUID()
    @State private var observedJumpRequest: ReaderNavigationJump?

    init(
        document: ReaderDocument,
        settings: ReaderDisplaySettings,
        initialProgress: Double = 0,
        onProgressChange: @escaping (Double) -> Void = { _ in },
        navigationModel: ReaderNavigationModel? = nil
    ) {
        self.document = document
        self.settings = settings
        self.initialProgress = min(max(initialProgress, 0), 1)
        self.onProgressChange = onProgressChange
        self.navigationModel = navigationModel
    }

    var body: some View {
        Group {
            switch phase {
            case .idle, .loading:
                ReaderLoadingView(message: String(localized: "正在打开 PDF…"))

            case .loaded(let pdfDocument):
                PDFKitReaderSurface(
                    document: pdfDocument,
                    layoutMode: settings.layoutMode,
                    theme: settings.theme,
                    initialProgress: initialProgress,
                    onProgressChange: onProgressChange,
                    navigationModel: navigationModel,
                    jumpRequest: observedJumpRequest ?? navigationModel?.jumpRequest
                )

            case .failed(let message):
                ReaderErrorView(
                    title: String(localized: "无法打开 PDF"),
                    message: message,
                    retry: { reloadID = UUID() }
                )
            }
        }
        .task(id: PDFLoadID(documentID: document.id, reloadID: reloadID)) {
            await load()
        }
        .onReceive(navigationModel?.$jumpRequest.eraseToAnyPublisher() ?? Empty().eraseToAnyPublisher()) { request in
            observedJumpRequest = request
        }
    }

    @MainActor
    private func load() async {
        phase = .loading
        do {
            let url = document.fileURL
            let data = try await Task.detached(priority: .userInitiated) {
                let isAccessingSecurityScopedResource = url.startAccessingSecurityScopedResource()
                defer {
                    if isAccessingSecurityScopedResource {
                        url.stopAccessingSecurityScopedResource()
                    }
                }
                return try Data(contentsOf: url, options: .mappedIfSafe)
            }.value

            try Task.checkCancellation()
            guard let pdfDocument = PDFDocument(data: data), pdfDocument.pageCount > 0 else {
                throw PDFLoadingError.invalidDocument
            }
            guard !pdfDocument.isLocked else {
                throw PDFLoadingError.passwordProtected
            }
            installNavigation(for: pdfDocument)
            phase = .loaded(pdfDocument)
        } catch is CancellationError {
            return
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    @MainActor
    private func installNavigation(for document: PDFDocument) {
        guard let navigationModel else { return }
        let url = self.document.fileURL
        navigationModel.update(sections: PDFNavigationSupport.sections(for: document))
        navigationModel.setSearchProvider { query in
            try await PDFNavigationSupport.search(query: query, fileURL: url)
        }
    }
}

private extension PDFReaderView {
    enum LoadPhase {
        case idle
        case loading
        case loaded(PDFDocument)
        case failed(String)
    }

    struct PDFLoadID: Hashable {
        let documentID: UUID
        let reloadID: UUID
    }

    enum PDFLoadingError: LocalizedError {
        case invalidDocument
        case passwordProtected

        var errorDescription: String? {
            switch self {
            case .invalidDocument:
                String(localized: "文件不是有效的 PDF，或没有可显示页面。")
            case .passwordProtected:
                String(localized: "首版暂不支持需要密码的 PDF。")
            }
        }
    }
}

private struct PDFKitReaderSurface: UIViewRepresentable {
    let document: PDFDocument
    let layoutMode: ReaderLayoutMode
    let theme: ReaderTheme
    let initialProgress: Double
    let onProgressChange: (Double) -> Void
    let navigationModel: ReaderNavigationModel?
    let jumpRequest: ReaderNavigationJump?

    func makeCoordinator() -> Coordinator {
        Coordinator(onProgressChange: onProgressChange)
    }

    func makeUIView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.autoScales = true
        pdfView.displayBox = .cropBox
        pdfView.displaysPageBreaks = true
        pdfView.pageBreakMargins = .init(top: 8, left: 8, bottom: 8, right: 8)
        pdfView.accessibilityIdentifier = "reader.pdf"
        context.coordinator.attach(to: pdfView)
        return pdfView
    }

    func updateUIView(_ pdfView: PDFView, context: Context) {
        context.coordinator.configure(
            onProgressChange: onProgressChange,
            initialProgress: initialProgress
        )
        context.coordinator.apply(layoutMode, to: pdfView)
        pdfView.backgroundColor = UIColor(theme.backgroundColor)
        if pdfView.document !== document {
            context.coordinator.prepareForDocumentChange()
            pdfView.document = document
            context.coordinator.restoreInitialPage(in: pdfView)
        }
        context.coordinator.applyJump(jumpRequest, model: navigationModel)
    }

    static func dismantleUIView(_ pdfView: PDFView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject {
        private weak var pdfView: PDFView?
        private var onProgressChange: (Double) -> Void
        private var initialProgress = 0.0
        private var currentLayoutMode: ReaderLayoutMode?
        private var didRestoreInitialPage = false
        private var progressTask: Task<Void, Never>?
        private var handledJumpID: UUID?

        init(onProgressChange: @escaping (Double) -> Void) {
            self.onProgressChange = onProgressChange
        }

        func attach(to pdfView: PDFView) {
            self.pdfView = pdfView
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(pageDidChange),
                name: .PDFViewPageChanged,
                object: pdfView
            )
        }

        func detach() {
            NotificationCenter.default.removeObserver(self)
            progressTask?.cancel()
            progressTask = nil
            pdfView = nil
        }

        func prepareForDocumentChange() {
            progressTask?.cancel()
            progressTask = nil
            didRestoreInitialPage = false
            handledJumpID = nil
        }

        func configure(
            onProgressChange: @escaping (Double) -> Void,
            initialProgress: Double
        ) {
            self.onProgressChange = onProgressChange
            self.initialProgress = min(max(initialProgress, 0), 1)
        }

        func applyJump(_ jumpRequest: ReaderNavigationJump?, model: ReaderNavigationModel?) {
            guard let jumpRequest, jumpRequest.id != handledJumpID,
                  let pdfView,
                  let document = pdfView.document else { return }
            var didHandleJump = false
            if case .pdfPage(let pageIndex) = jumpRequest.location,
               let page = document.page(at: pageIndex) {
                pdfView.go(to: page)
                didHandleJump = true
            } else if case .pdf(let location) = jumpRequest.location,
                      location.mode == .original {
                let pageIndex = min(
                    max(Int((Double(document.pageCount - 1) * location.originalProgress).rounded()), 0),
                    max(document.pageCount - 1, 0)
                )
                if let page = document.page(at: pageIndex) {
                    pdfView.go(to: page)
                    didHandleJump = true
                }
            }
            guard didHandleJump else { return }
            handledJumpID = jumpRequest.id
            guard let model else { return }
            Task { @MainActor in
                await Task.yield()
                model.clearJumpRequest(jumpRequest)
            }
        }

        func apply(_ layoutMode: ReaderLayoutMode, to pdfView: PDFView) {
            guard currentLayoutMode != layoutMode else {
                return
            }
            currentLayoutMode = layoutMode

            switch layoutMode {
            case .paged:
                pdfView.displayMode = .singlePage
                pdfView.displayDirection = .horizontal
                pdfView.usePageViewController(
                    true,
                    withViewOptions: [UIPageViewController.OptionsKey.interPageSpacing: 12]
                )
            case .scrolling:
                pdfView.usePageViewController(false, withViewOptions: nil)
                pdfView.displayMode = .singlePageContinuous
                pdfView.displayDirection = .vertical
            }
            pdfView.autoScales = true
        }

        func restoreInitialPage(in pdfView: PDFView) {
            guard !didRestoreInitialPage,
                  let document = pdfView.document,
                  document.pageCount > 0 else {
                return
            }

            let pageIndex = min(
                max(Int((Double(document.pageCount - 1) * initialProgress).rounded()), 0),
                document.pageCount - 1
            )
            didRestoreInitialPage = true
            if let page = document.page(at: pageIndex) {
                pdfView.go(to: page)
                scheduleProgress(for: page, in: document)
            }
        }

        @objc private func pageDidChange() {
            guard didRestoreInitialPage,
                  let pdfView,
                  let document = pdfView.document,
                  let page = pdfView.currentPage else {
                return
            }

            scheduleProgress(for: page, in: document)
        }

        private func scheduleProgress(for page: PDFPage, in document: PDFDocument) {
            let index = document.index(for: page)
            guard index != NSNotFound else { return }
            let denominator = max(document.pageCount - 1, 1)
            let progress = Double(index) / Double(denominator)
            progressTask?.cancel()
            progressTask = Task { @MainActor [weak self] in
                // PDFKit also emits page changes while SwiftUI is assigning a
                // document. Publish only after restoration and outside that update.
                await Task.yield()
                guard !Task.isCancelled, let self, self.pdfView != nil else { return }
                onProgressChange(progress)
            }
        }
    }
}
