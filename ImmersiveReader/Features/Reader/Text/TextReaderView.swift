import SwiftUI
import UIKit

struct TextReaderView: View {
    let document: ReaderDocument
    let settings: ReaderDisplaySettings
    let initialProgress: Double
    let onProgressChange: (Double) -> Void

    private let loader: any ReaderTextLoading
    @State private var phase: LoadPhase = .idle
    @State private var reloadID = UUID()

    init(
        document: ReaderDocument,
        settings: ReaderDisplaySettings,
        initialProgress: Double = 0,
        onProgressChange: @escaping (Double) -> Void = { _ in },
        loader: any ReaderTextLoading = LocalReaderTextLoader()
    ) {
        self.document = document
        self.settings = settings
        self.initialProgress = initialProgress.clampedToUnitInterval
        self.onProgressChange = onProgressChange
        self.loader = loader
    }

    var body: some View {
        Group {
            switch phase {
            case .idle, .loading:
                ReaderLoadingView(message: "正在准备正文…")

            case .loaded(let content):
                ReaderTextLayoutView(
                    content: content,
                    settings: settings,
                    initialProgress: initialProgress,
                    onProgressChange: onProgressChange
                )

            case .failed(let message):
                ReaderErrorView(
                    title: "无法打开文档",
                    message: message,
                    retry: { reloadID = UUID() }
                )
            }
        }
        .task(id: ReaderTextLoadID(documentID: document.id, reloadID: reloadID)) {
            await load()
        }
    }

    @MainActor
    private func load() async {
        phase = .loading
        do {
            let content = try await loader.load(document: document)
            try Task.checkCancellation()
            phase = .loaded(content)
        } catch is CancellationError {
            return
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}

private extension TextReaderView {
    enum LoadPhase {
        case idle
        case loading
        case loaded(ReaderTextContent)
        case failed(String)
    }

    struct ReaderTextLoadID: Hashable {
        let documentID: UUID
        let reloadID: UUID
    }
}

struct ReaderTextLayoutView: View {
    let content: ReaderTextContent
    let settings: ReaderDisplaySettings
    let initialProgress: Double
    let onProgressChange: (Double) -> Void

    @State private var phase: LayoutPhase = .loading
    @State private var pageIndex = 0
    @State private var currentProgress: Double
    @State private var currentCharacterOffset: Int?
    @State private var activeRenderID: UUID?
    @State private var retryID = UUID()

    init(
        content: ReaderTextContent,
        settings: ReaderDisplaySettings,
        initialProgress: Double,
        onProgressChange: @escaping (Double) -> Void
    ) {
        self.content = content
        self.settings = settings
        self.initialProgress = initialProgress.clampedToUnitInterval
        self.onProgressChange = onProgressChange
        _currentProgress = State(initialValue: initialProgress.clampedToUnitInterval)
    }

    var body: some View {
        GeometryReader { proxy in
            let request = LayoutRequest(
                settings: settings,
                availableSize: proxy.size,
                retryID: retryID
            )

            Group {
                switch phase {
                case .loading:
                    ReaderLoadingView(message: "正在排版…")

                case .ready(let layout):
                    if layout.request.settings.layoutMode == .scrolling {
                        ReaderAttributedTextView(
                            attributedText: layout.fullText,
                            allowsScrolling: true,
                            theme: layout.request.settings.theme,
                            contentInsets: Self.contentInsets,
                            initialCharacterOffset: currentCharacterOffset ?? 0,
                            onPositionChange: { offset in
                                reportPosition(offset, in: layout)
                            }
                        )
                    } else {
                        pagedContent(layout)
                    }

                case .failed(let message):
                    ReaderErrorView(
                        title: "无法完成排版",
                        message: message,
                        retry: { retryID = UUID() }
                    )
                }
            }
            .task(id: request) {
                await render(for: request)
            }
        }
        .onChange(of: content) { _, _ in
            activeRenderID = nil
            currentCharacterOffset = nil
            currentProgress = initialProgress
            phase = .loading
            retryID = UUID()
        }
    }

    @ViewBuilder
    private func pagedContent(_ layout: Layout) -> some View {
        if layout.pageRanges.isEmpty {
            ContentUnavailableView("没有正文", systemImage: "doc.text")
        } else {
            TabView(selection: Binding(
                get: { pageIndex },
                set: { selectPage($0, in: layout) }
            )) {
                ForEach(layout.pageRanges.indices, id: \.self) { index in
                    ReaderAttributedTextView(
                        attributedText: layout.fullText.attributedSubstring(
                            from: layout.pageRanges[index]
                        ),
                        allowsScrolling: false,
                        theme: layout.request.settings.theme,
                        contentInsets: Self.contentInsets,
                        initialCharacterOffset: 0,
                        onPositionChange: { _ in }
                    )
                    .tag(index)
                    .accessibilityLabel(
                        "第 \(index + 1) 页，共 \(layout.pageRanges.count) 页"
                    )
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .overlay(alignment: .bottomTrailing) {
                Text("\(pageIndex + 1) / \(layout.pageRanges.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.thinMaterial, in: Capsule())
                    .padding(14)
                    .accessibilityHidden(true)
            }
        }
    }

    @MainActor
    private func render(for request: LayoutRequest) async {
        guard request.textContentSize(insets: Self.contentInsets).width >= 40,
              request.textContentSize(insets: Self.contentInsets).height >= 40 else { return }

        let previousLayout: Layout?
        if case .ready(let layout) = phase {
            guard layout.request != request else { return }
            previousLayout = layout
        } else {
            previousLayout = nil
        }

        let renderID = UUID()
        activeRenderID = renderID
        do {
            // Keep the visible page while a slider is moving, coalescing intermediate
            // values instead of flashing a full-screen loading view on every tick.
            if previousLayout != nil {
                try await Task.sleep(for: .milliseconds(120))
            } else {
                await Task.yield()
            }
            try Task.checkCancellation()

            let attributedText = ReaderTextRenderer.attributedString(
                for: content,
                settings: request.settings
            )
            let pageRanges: [NSRange]
            if request.settings.layoutMode == .paged {
                if let previousLayout,
                   previousLayout.request.hasSamePagination(as: request) {
                    // A color-only theme change does not need another TextKit pass.
                    pageRanges = previousLayout.pageRanges
                } else {
                    pageRanges = try await ReaderTextPaginator.pageRanges(
                        from: attributedText,
                        contentSize: request.textContentSize(insets: Self.contentInsets)
                    )
                }
            } else {
                pageRanges = []
            }

            try Task.checkCancellation()
            guard activeRenderID == renderID else { return }

            let savedOffset = currentCharacterOffset ?? ReaderTextPosition.characterOffset(
                for: currentProgress,
                textLength: attributedText.length
            )
            let anchor = min(max(savedOffset, 0), max(attributedText.length - 1, 0))
            let restoredPage = ReaderTextPosition.pageIndex(
                containingCharacterAt: anchor,
                in: pageRanges
            ) ?? 0

            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                currentCharacterOffset = anchor
                pageIndex = restoredPage
                phase = .ready(.init(
                    id: renderID,
                    request: request,
                    fullText: attributedText,
                    pageRanges: pageRanges
                ))
            }
        } catch is CancellationError {
            // A newer typography request (or leaving the reader) is expected.
            return
        } catch {
            guard !Task.isCancelled, activeRenderID == renderID else { return }
            phase = .failed(error.localizedDescription)
        }
    }

    @MainActor
    private func selectPage(_ index: Int, in layout: Layout) {
        guard case .ready(let visibleLayout) = phase,
              visibleLayout.id == layout.id,
              layout.pageRanges.indices.contains(index),
              index != pageIndex else { return }

        pageIndex = index
        reportPosition(
            layout.pageRanges[index].location,
            in: layout
        )
    }

    @MainActor
    private func reportPosition(_ offset: Int, in layout: Layout) {
        guard case .ready(let visibleLayout) = phase, visibleLayout.id == layout.id else { return }
        currentCharacterOffset = min(max(offset, 0), max(layout.fullText.length - 1, 0))
        // Persist the visible text location even on the final page. Forcing 100%
        // there would discard its anchor and reopen at a different passage after reflow.
        let progress = ReaderTextPosition.progress(
            forCharacterOffset: offset,
            textLength: layout.fullText.length
        )
        currentProgress = progress
        onProgressChange(progress)
    }

    private static let contentInsets = UIEdgeInsets(top: 28, left: 24, bottom: 46, right: 24)
}

private extension ReaderTextLayoutView {
    enum LayoutPhase {
        case loading
        case ready(Layout)
        case failed(String)
    }

    struct Layout {
        let id: UUID
        let request: LayoutRequest
        let fullText: NSAttributedString
        let pageRanges: [NSRange]
    }

    struct LayoutRequest: Hashable {
        let settings: ReaderDisplaySettings
        let width: Int
        let height: Int
        let retryID: UUID

        init(settings: ReaderDisplaySettings, availableSize: CGSize, retryID: UUID) {
            self.settings = settings
            width = max(0, Int(availableSize.width.rounded()))
            height = max(0, Int(availableSize.height.rounded()))
            self.retryID = retryID
        }

        func hasSamePagination(as other: Self) -> Bool {
            settings.layoutMode == .paged
                && other.settings.layoutMode == .paged
                && settings.fontSize == other.settings.fontSize
                && settings.lineHeightMultiple == other.settings.lineHeightMultiple
                && width == other.width
                && height == other.height
        }

        func textContentSize(insets: UIEdgeInsets) -> CGSize {
            CGSize(
                width: max(0, Double(width) - insets.left - insets.right),
                height: max(0, Double(height) - insets.top - insets.bottom)
            )
        }
    }
}

private struct ReaderAttributedTextView: UIViewRepresentable {
    let attributedText: NSAttributedString
    let allowsScrolling: Bool
    let theme: ReaderTheme
    let contentInsets: UIEdgeInsets
    let initialCharacterOffset: Int
    let onPositionChange: (Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPositionChange: onPositionChange)
    }

    func makeUIView(context: Context) -> ReaderPositionTextView {
        // Use the same TextKit generation as the paginator so measured page ranges
        // match the rendered text, including the user-selected UIFont point sizes.
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)
        container.widthTracksTextView = true
        container.heightTracksTextView = false
        let textView = ReaderPositionTextView(frame: .zero, textContainer: container)
        textView.delegate = context.coordinator
        textView.isEditable = false
        textView.isSelectable = true
        textView.alwaysBounceVertical = allowsScrolling
        textView.showsVerticalScrollIndicator = allowsScrolling
        textView.textContainer.lineFragmentPadding = 0
        // Reader typography is explicitly controlled by its font-size setting.
        textView.adjustsFontForContentSizeCategory = false
        textView.contentInsetAdjustmentBehavior = .never
        textView.dataDetectorTypes = [.link]
        textView.accessibilityIdentifier = "reader.text"
        textView.onLayout = { [weak coordinator = context.coordinator] view in
            coordinator?.restoreIfNeeded(in: view)
        }
        return textView
    }

    func updateUIView(_ textView: ReaderPositionTextView, context: Context) {
        let textChanged = context.coordinator.beginUpdate(
            in: textView,
            attributedText: attributedText,
            onPositionChange: onPositionChange,
            initialCharacterOffset: initialCharacterOffset,
            enabled: allowsScrolling
        )

        textView.isScrollEnabled = allowsScrolling
        textView.alwaysBounceVertical = allowsScrolling
        textView.showsVerticalScrollIndicator = allowsScrolling
        textView.textContainerInset = contentInsets
        textView.backgroundColor = UIColor(theme.backgroundColor)

        if textChanged {
            textView.attributedText = attributedText
        }
        context.coordinator.finishUpdate(in: textView)
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        private var onPositionChange: (Int) -> Void
        private var renderedText: NSAttributedString?
        private var pendingCharacterOffset: Int?
        private var hasRestoredInitialPosition = false
        private var isProgressEnabled = false
        private var isRestoring = false
        private var isUpdating = false
        private var lastReportedOffset: Int?
        private var pendingReportedOffset: Int?
        private var reportTask: Task<Void, Never>?

        init(onPositionChange: @escaping (Int) -> Void) {
            self.onPositionChange = onPositionChange
        }

        func beginUpdate(
            in textView: UITextView,
            attributedText: NSAttributedString,
            onPositionChange: @escaping (Int) -> Void,
            initialCharacterOffset: Int,
            enabled: Bool
        ) -> Bool {
            isUpdating = true
            self.onPositionChange = onPositionChange
            isProgressEnabled = enabled

            let textChanged = renderedText !== attributedText
                && renderedText?.isEqual(to: attributedText) != true
            if textChanged {
                reportTask?.cancel()
                reportTask = nil
                pendingReportedOffset = nil

                // Capture from the old layout before assigning the new font. A raw
                // contentOffset or scroll percentage would drift on a long document.
                let isSameDocument = renderedText?.string == attributedText.string
                if enabled, hasRestoredInitialPosition, isSameDocument {
                    pendingCharacterOffset = visibleCharacterOffset(in: textView)
                        ?? initialCharacterOffset
                } else if enabled {
                    pendingCharacterOffset = initialCharacterOffset
                }
                lastReportedOffset = nil
            }
            renderedText = attributedText
            return textChanged
        }

        func finishUpdate(in textView: UITextView) {
            isUpdating = false
            restoreIfNeeded(in: textView)
        }

        func restoreIfNeeded(in textView: UITextView) {
            guard isProgressEnabled, !isUpdating, !isRestoring,
                  let savedOffset = pendingCharacterOffset,
                  textView.bounds.width > 0, textView.bounds.height > 0,
                  textView.textStorage.length > 0 else { return }

            isRestoring = true
            defer { isRestoring = false }
            textView.layoutManager.ensureLayout(for: textView.textContainer)
            textView.layoutIfNeeded()

            let offset = min(max(savedOffset, 0), textView.textStorage.length - 1)
            let glyphRange = textView.layoutManager.glyphRange(
                forCharacterRange: NSRange(location: offset, length: 1),
                actualCharacterRange: nil
            )
            guard glyphRange.length > 0 else { return }

            let lineRect = textView.layoutManager.lineFragmentRect(
                forGlyphAt: glyphRange.location,
                effectiveRange: nil
            )
            let maximumOffset = max(0, textView.contentSize.height - textView.bounds.height)
            let targetOffset = offset == 0 ? 0 : lineRect.minY + textView.textContainerInset.top
            textView.setContentOffset(
                CGPoint(x: 0, y: min(max(targetOffset, 0), maximumOffset)),
                animated: false
            )
            pendingCharacterOffset = nil
            hasRestoredInitialPosition = true
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard isProgressEnabled, !isRestoring, !isUpdating,
                  hasRestoredInitialPosition, pendingCharacterOffset == nil,
                  let textView = scrollView as? UITextView,
                  let offset = visibleCharacterOffset(in: textView) else { return }

            guard offset != lastReportedOffset else { return }

            lastReportedOffset = offset
            pendingReportedOffset = offset
            guard reportTask == nil else { return }
            reportTask = Task { @MainActor [weak self] in
                // UIKit can also call its scroll delegate during a SwiftUI update.
                // Coalescing on the next turn avoids publishing state from that update.
                await Task.yield()
                guard !Task.isCancelled, let self else { return }
                reportTask = nil
                guard let offset = pendingReportedOffset else { return }
                pendingReportedOffset = nil
                onPositionChange(offset)
            }
        }

        private func visibleCharacterOffset(in textView: UITextView) -> Int? {
            guard textView.textStorage.length > 0, textView.bounds.width > 0 else { return nil }
            let point = CGPoint(
                x: 0,
                y: max(0, textView.contentOffset.y - textView.textContainerInset.top + 1)
            )
            let offset = textView.layoutManager.characterIndex(
                for: point,
                in: textView.textContainer,
                fractionOfDistanceBetweenInsertionPoints: nil
            )
            return min(max(offset, 0), textView.textStorage.length - 1)
        }
    }
}

private final class ReaderPositionTextView: UITextView {
    var onLayout: ((UITextView) -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?(self)
    }
}

extension Double {
    var clampedToUnitInterval: Double {
        guard isFinite else {
            return 0
        }
        return min(max(self, 0), 1)
    }
}
