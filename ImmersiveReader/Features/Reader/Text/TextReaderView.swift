import SwiftUI
import UIKit
import Combine

struct TextReaderView: View {
    let document: ReaderDocument
    let settings: ReaderDisplaySettings
    let initialLocation: TextReadingLocation?
    let initialProgress: Double
    let onLocationChange: (TextReadingLocation) -> Void
    let navigationModel: ReaderNavigationModel?

    private let loader: any ReaderTextLoading
    @State private var phase: LoadPhase = .idle
    @State private var reloadID = UUID()

    init(
        document: ReaderDocument,
        settings: ReaderDisplaySettings,
        initialLocation: TextReadingLocation? = nil,
        initialProgress: Double = 0,
        onLocationChange: @escaping (TextReadingLocation) -> Void = { _ in },
        navigationModel: ReaderNavigationModel? = nil,
        loader: any ReaderTextLoading = LocalReaderTextLoader()
    ) {
        self.document = document
        self.settings = settings
        self.initialLocation = initialLocation
        self.initialProgress = initialProgress.clampedToUnitInterval
        self.onLocationChange = onLocationChange
        self.navigationModel = navigationModel
        self.loader = loader
    }

    var body: some View {
        Group {
            switch phase {
            case .idle, .loading:
                ReaderLoadingView(message: String(localized: "正在准备正文…"))

            case .loaded(let content):
                ReaderTextLayoutView(
                    content: content,
                    settings: settings,
                    initialLocation: initialLocation,
                    initialProgress: initialProgress,
                    onLocationChange: onLocationChange,
                    navigationModel: navigationModel
                )

            case .failed(let message):
                ReaderErrorView(
                    title: String(localized: "无法打开文档"),
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
    let initialLocation: TextReadingLocation?
    let initialProgress: Double
    let onLocationChange: (TextReadingLocation) -> Void
    let navigationModel: ReaderNavigationModel?

    @State private var session: Session
    @State private var appliedRequest: ReaderLayoutRequest?
    @State private var currentAnchor: ReaderTextAnchor?
    @State private var indicator: ReaderPageIndicator?
    @State private var failure: String?
    @State private var retryID = UUID()
    @State private var jumpID = UUID()

    init(
        content: ReaderTextContent,
        settings: ReaderDisplaySettings,
        initialLocation: TextReadingLocation? = nil,
        initialProgress: Double = 0,
        onLocationChange: @escaping (TextReadingLocation) -> Void,
        navigationModel: ReaderNavigationModel? = nil
    ) {
        self.content = content
        self.settings = settings
        self.initialLocation = initialLocation
        self.initialProgress = initialProgress.clampedToUnitInterval
        self.onLocationChange = onLocationChange
        self.navigationModel = navigationModel
        _session = State(initialValue: Session(content: content))
    }

    var body: some View {
        GeometryReader { proxy in
            let request = ReaderLayoutRequest(settings: settings, availableSize: proxy.size)

            Group {
                if session.segmentation.isEmpty {
                    ContentUnavailableView("没有正文", systemImage: "doc.text")
                } else if let failure {
                    ReaderErrorView(
                        title: String(localized: "无法完成排版"),
                        message: failure,
                        retry: {
                            self.failure = nil
                            retryID = UUID()
                        }
                    )
                } else if let appliedRequest, appliedRequest.canLayOut {
                    readingSurface(for: appliedRequest)
                } else {
                    ReaderLoadingView(message: String(localized: "正在排版…"))
                }
            }
            .task(id: RequestID(request: request, retryID: retryID)) {
                if appliedRequest != nil {
                    try? await Task.sleep(for: .milliseconds(120))
                }
                guard !Task.isCancelled else { return }
                appliedRequest = request
            }
        }
        .onChange(of: content) { _, newContent in
            session = Session(content: newContent)
            currentAnchor = nil
            indicator = nil
            failure = nil
            appliedRequest = nil
            retryID = UUID()
        }
        .task(id: session.id) {
            navigationModel?.update(content: content)
        }
        .onReceive(navigationModel?.$jumpRequest.eraseToAnyPublisher() ?? Empty().eraseToAnyPublisher()) { request in
            guard let request, request.id != jumpID else { return }
            let location: TextReadingLocation?
            switch request.location {
            case .text(let target): location = target
            case .pdf(let target) where target.mode == .reflow: location = target.reflowLocation
            default: location = nil
            }
            guard let location else { return }
            currentAnchor = restoredAnchor(for: location)
            jumpID = request.id
            Task { @MainActor in
                await Task.yield()
                navigationModel?.clearJumpRequest(request)
            }
        }
    }

    @ViewBuilder
    private func readingSurface(for request: ReaderLayoutRequest) -> some View {
        let anchor = currentAnchor ?? openingAnchor
        if request.settings.layoutMode == .scrolling {
            ReaderScrollingTextView(
                store: session.store(for: request),
                request: request,
                initialAnchor: anchor,
                onLocationChange: report,
                onFailure: { failure = $0.localizedDescription }
            )
            .id(SurfaceID(sessionID: session.id, jumpID: jumpID))
        } else {
            ReaderPagedTextView(
                store: session.store(for: request),
                request: request,
                initialAnchor: anchor,
                onLocationChange: report,
                onIndicatorChange: { indicator = $0 },
                onFailure: { failure = $0.localizedDescription }
            )
            .id(SurfaceID(sessionID: session.id, jumpID: jumpID))
            .overlay(alignment: .bottomTrailing) {
                if let indicator {
                    Text("\(indicator.pageIndex + 1) / \(indicator.pageCount) · \(indicator.progress.formatted(.percent.precision(.fractionLength(0))))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.thinMaterial, in: Capsule())
                        .padding(14)
                        .accessibilityLabel("本节第 \(indicator.pageIndex + 1) 页，共 \(indicator.pageCount) 页，全文进度 \(indicator.progress.formatted(.percent.precision(.fractionLength(0))))")
                }
            }
        }
    }

    private var openingAnchor: ReaderTextAnchor {
        guard let initialLocation else {
            return session.segmentation.anchor(forProgress: initialProgress)
        }
        return restoredAnchor(for: initialLocation)
    }

    private func restoredAnchor(for location: TextReadingLocation) -> ReaderTextAnchor {
        if content.format == .plainText, location.semanticVersion == 1 {
            return content.sourceMap?.migrate(location.anchor)
                ?? session.segmentation.anchor(forProgress: location.progress)
        }
        return location.anchor
    }

    private func report(_ location: TextReadingLocation) {
        currentAnchor = location.anchor
        onLocationChange(location)
    }

    @MainActor
    private final class Session {
        let id = UUID()
        let content: ReaderTextContent
        let segmentation: ReaderTextSegmentation
        private var layoutStore: ReaderSegmentLayoutStore?

        init(content: ReaderTextContent) {
            self.content = content
            segmentation = ReaderTextSegmentation(blocks: content.blocks)
        }

        func store(for request: ReaderLayoutRequest) -> ReaderSegmentLayoutStore {
            if let layoutStore {
                return layoutStore
            }
            let store = ReaderSegmentLayoutStore(content: content, segmentation: segmentation, request: request)
            layoutStore = store
            return store
        }
    }

    private struct RequestID: Hashable {
        let request: ReaderLayoutRequest
        let retryID: UUID
    }

    private struct SurfaceID: Hashable {
        let sessionID: UUID
        let jumpID: UUID
    }
}
