import SwiftUI
import UIKit

struct ReaderPageIndicator: Equatable {
    let pageIndex: Int
    let pageCount: Int
    let progress: Double
}

struct ReaderPagedTextView: UIViewControllerRepresentable {
    let store: ReaderSegmentLayoutStore
    let request: ReaderLayoutRequest
    let initialAnchor: ReaderTextAnchor
    let onLocationChange: (TextReadingLocation) -> Void
    let onIndicatorChange: (ReaderPageIndicator) -> Void
    let onFailure: (Error) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(store: store)
    }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let controller = UIPageViewController(
            transitionStyle: .scroll,
            navigationOrientation: .horizontal,
            options: [.interPageSpacing: 0]
        )
        controller.dataSource = context.coordinator
        controller.delegate = context.coordinator
        controller.view.accessibilityIdentifier = "reader.pages"
        context.coordinator.attach(controller)
        return controller
    }

    func updateUIViewController(_ controller: UIPageViewController, context: Context) {
        let coordinator = context.coordinator
        coordinator.onLocationChange = onLocationChange
        coordinator.onIndicatorChange = onIndicatorChange
        coordinator.onFailure = onFailure
        controller.view.backgroundColor = UIColor(request.settings.theme.backgroundColor)
        coordinator.apply(request: request, initialAnchor: initialAnchor)
    }

    @MainActor
    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var onLocationChange: (TextReadingLocation) -> Void = { _ in }
        var onIndicatorChange: (ReaderPageIndicator) -> Void = { _ in }
        var onFailure: (Error) -> Void = { _ in }

        private let store: ReaderSegmentLayoutStore
        private weak var controller: UIPageViewController?
        private var appliedRequest: ReaderLayoutRequest?
        private var reportTask: Task<Void, Never>?

        init(store: ReaderSegmentLayoutStore) {
            self.store = store
        }

        func attach(_ controller: UIPageViewController) {
            self.controller = controller
        }

        func apply(request: ReaderLayoutRequest, initialAnchor: ReaderTextAnchor) {
            guard request.canLayOut, request != appliedRequest else { return }
            let anchor = currentAnchor ?? initialAnchor
            appliedRequest = request
            store.reset(request: request)
            open(at: anchor)
        }

        private var visiblePageController: ReaderPageViewController? {
            controller?.viewControllers?.first as? ReaderPageViewController
        }

        var currentAnchor: ReaderTextAnchor? {
            guard let visible = visiblePageController else { return nil }
            return store.anchor(in: visible.layout, offset: visible.pageRange.location)
        }

        private func open(at anchor: ReaderTextAnchor) {
            guard let controller else { return }
            do {
                let position = try store.position(of: anchor)
                let layout = try store.layout(for: position.segmentIndex)
                let pageIndex = ReaderTextPosition.pageIndex(
                    containingCharacterAt: position.offset,
                    in: layout.pageRanges
                ) ?? 0
                let page = ReaderPageID(segmentIndex: position.segmentIndex, pageIndex: pageIndex)
                let pageController = makePageController(for: page, layout: layout)
                controller.setViewControllers([pageController], direction: .forward, animated: false)
                didShow(pageController)
            } catch {
                onFailure(error)
            }
        }

        private func didShow(_ pageController: ReaderPageViewController) {
            let page = pageController.page
            store.prefetch([page.segmentIndex + 1, page.segmentIndex - 1])
            let location = store.location(in: pageController.layout, offset: pageController.pageRange.location)
            let indicator = ReaderPageIndicator(
                pageIndex: page.pageIndex,
                pageCount: pageController.layout.pageRanges.count,
                progress: location.progress
            )
            reportTask?.cancel()
            reportTask = Task { @MainActor [weak self] in
                await Task.yield()
                guard !Task.isCancelled, let self else { return }
                onIndicatorChange(indicator)
                onLocationChange(location)
            }
        }

        private func makePageController(for page: ReaderPageID, layout: ReaderSegmentLayout) -> ReaderPageViewController {
            ReaderPageViewController(page: page, layout: layout, request: store.request)
        }

        private func pageController(adjacentTo page: ReaderPageID, forward: Bool) -> ReaderPageViewController? {
            do {
                let layout = try store.layout(for: page.segmentIndex)
                if forward, page.pageIndex + 1 < layout.pageRanges.count {
                    let next = ReaderPageID(segmentIndex: page.segmentIndex, pageIndex: page.pageIndex + 1)
                    return makePageController(for: next, layout: layout)
                }
                if !forward, page.pageIndex > 0 {
                    let previous = ReaderPageID(segmentIndex: page.segmentIndex, pageIndex: page.pageIndex - 1)
                    return makePageController(for: previous, layout: layout)
                }

                let neighbourIndex = page.segmentIndex + (forward ? 1 : -1)
                guard store.segmentation.segments.indices.contains(neighbourIndex) else { return nil }
                let neighbour = try store.layout(for: neighbourIndex)
                guard !neighbour.pageRanges.isEmpty else { return nil }
                let neighbourPage = ReaderPageID(
                    segmentIndex: neighbourIndex,
                    pageIndex: forward ? 0 : neighbour.pageRanges.count - 1
                )
                return makePageController(for: neighbourPage, layout: neighbour)
            } catch {
                onFailure(error)
                return nil
            }
        }


        func pageViewController(
            _ pageViewController: UIPageViewController,
            viewControllerBefore viewController: UIViewController
        ) -> UIViewController? {
            guard let page = (viewController as? ReaderPageViewController)?.page else { return nil }
            return pageController(adjacentTo: page, forward: false)
        }

        func pageViewController(
            _ pageViewController: UIPageViewController,
            viewControllerAfter viewController: UIViewController
        ) -> UIViewController? {
            guard let page = (viewController as? ReaderPageViewController)?.page else { return nil }
            return pageController(adjacentTo: page, forward: true)
        }


        func pageViewController(
            _ pageViewController: UIPageViewController,
            didFinishAnimating finished: Bool,
            previousViewControllers: [UIViewController],
            transitionCompleted completed: Bool
        ) {
            guard completed, let pageController = visiblePageController else { return }
            didShow(pageController)
        }
    }
}

struct ReaderPageID: Hashable {
    let segmentIndex: Int
    let pageIndex: Int
}

final class ReaderPageViewController: UIViewController {
    let page: ReaderPageID
    let layout: ReaderSegmentLayout
    private let request: ReaderLayoutRequest

    init(page: ReaderPageID, layout: ReaderSegmentLayout, request: ReaderLayoutRequest) {
        self.page = page
        self.layout = layout
        self.request = request
        super.init(nibName: nil, bundle: nil)
    }

    var pageRange: NSRange {
        layout.pageRanges.indices.contains(page.pageIndex)
            ? layout.pageRanges[page.pageIndex]
            : NSRange(location: 0, length: 0)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ReaderPageViewController is created in code")
    }

    override func loadView() {
        let textView = ReaderTextView.make(scrolling: false)
        textView.textContainerInset = request.contentInsets
        textView.backgroundColor = UIColor(request.settings.theme.backgroundColor)
        textView.attributedText = layout.text.attributedSubstring(from: pageRange)
        textView.accessibilityLabel = String(localized: "第 \(page.pageIndex + 1) 页")
        view = textView
    }
}

enum ReaderTextView {
    @MainActor
    static func make(scrolling: Bool) -> UITextView {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)
        container.widthTracksTextView = true
        container.heightTracksTextView = false
        container.lineFragmentPadding = 0

        let textView = UITextView(frame: .zero, textContainer: container)
        configure(textView, scrolling: scrolling)
        return textView
    }

    @MainActor
    static func configure(_ textView: UITextView, scrolling: Bool) {
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = scrolling
        textView.alwaysBounceVertical = scrolling
        textView.showsVerticalScrollIndicator = scrolling
        textView.adjustsFontForContentSizeCategory = false
        textView.contentInsetAdjustmentBehavior = .never
        textView.dataDetectorTypes = [.link]
        textView.accessibilityIdentifier = "reader.text"
    }
}
