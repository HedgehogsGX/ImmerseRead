import UIKit

struct ReaderLayoutRequest: Hashable, Sendable {
    let settings: ReaderDisplaySettings
    let width: Int
    let height: Int

    var contentInsets: UIEdgeInsets {
        let margin = settings.margin.isFinite
            ? min(max(settings.margin, ReaderDisplaySettings.marginRange.lowerBound), ReaderDisplaySettings.marginRange.upperBound)
            : ReaderDisplaySettings.default.margin
        return UIEdgeInsets(top: 28, left: margin, bottom: 46, right: margin)
    }

    init(settings: ReaderDisplaySettings, availableSize: CGSize) {
        self.settings = settings
        width = max(0, Int(availableSize.width.rounded()))
        height = max(0, Int(availableSize.height.rounded()))
    }

    var contentSize: CGSize {
        CGSize(
            width: max(0, Double(width) - contentInsets.left - contentInsets.right),
            height: max(0, Double(height) - contentInsets.top - contentInsets.bottom)
        )
    }

    var canLayOut: Bool {
        contentSize.width >= 40 && contentSize.height >= 40
    }
}

struct ReaderSegmentLayout {
    let segmentIndex: Int
    let rendered: ReaderRenderedText
    let pageRanges: [NSRange]

    var text: NSAttributedString {
        rendered.attributedString
    }
}

@MainActor
final class ReaderSegmentLayoutStore {
    static let retainedLayoutCount = 6

    let content: ReaderTextContent
    let segmentation: ReaderTextSegmentation
    private(set) var request: ReaderLayoutRequest

    private var layouts: [Int: ReaderSegmentLayout] = [:]
    private var recentlyUsed: [Int] = []
    private var prefetchTasks: [Int: Task<Void, Never>] = [:]

    init(content: ReaderTextContent, segmentation: ReaderTextSegmentation, request: ReaderLayoutRequest) {
        self.content = content
        self.segmentation = segmentation
        self.request = request
    }

    var segmentCount: Int {
        segmentation.segments.count
    }

    func reset(request: ReaderLayoutRequest) {
        guard request != self.request else { return }
        self.request = request
        cancelPrefetches()
        layouts.removeAll()
        recentlyUsed.removeAll()
    }

    func cachedLayout(for segmentIndex: Int) -> ReaderSegmentLayout? {
        guard let layout = layouts[segmentIndex] else { return nil }
        touch(segmentIndex)
        return layout
    }

    func layout(for segmentIndex: Int) throws -> ReaderSegmentLayout {
        if let layout = cachedLayout(for: segmentIndex) {
            return layout
        }
        prefetchTasks.removeValue(forKey: segmentIndex)?.cancel()
        let rendered = render(segmentIndex)
        let pageRanges = request.settings.layoutMode == .paged
            ? try ReaderTextPaginator.pageRangesNow(from: rendered.attributedString, contentSize: request.contentSize)
            : []
        return store(ReaderSegmentLayout(segmentIndex: segmentIndex, rendered: rendered, pageRanges: pageRanges))
    }

    func prefetch(_ segmentIndices: [Int]) {
        for segmentIndex in segmentIndices
        where segmentation.segments.indices.contains(segmentIndex)
            && layouts[segmentIndex] == nil
            && prefetchTasks[segmentIndex] == nil {
            let request = self.request
            prefetchTasks[segmentIndex] = Task(priority: .utility) { [weak self] in
                await Task.yield()
                guard let self, !Task.isCancelled, self.request == request else { return }
                let rendered = self.render(segmentIndex)
                let pageRanges: [NSRange]
                do {
                    pageRanges = request.settings.layoutMode == .paged
                        ? try await ReaderTextPaginator.pageRanges(from: rendered.attributedString, contentSize: request.contentSize)
                        : []
                } catch {
                    self.prefetchTasks.removeValue(forKey: segmentIndex)
                    return
                }
                guard !Task.isCancelled, self.request == request else { return }
                self.prefetchTasks.removeValue(forKey: segmentIndex)
                if self.layouts[segmentIndex] == nil {
                    self.store(ReaderSegmentLayout(segmentIndex: segmentIndex, rendered: rendered, pageRanges: pageRanges))
                }
            }
        }
    }

    func cancelPrefetches() {
        prefetchTasks.values.forEach { $0.cancel() }
        prefetchTasks.removeAll()
    }


    func position(of anchor: ReaderTextAnchor) throws -> (segmentIndex: Int, offset: Int) {
        let blockIndex = min(anchor.blockIndex, max(content.blocks.count - 1, 0))
        let segmentIndex = segmentation.segmentIndex(containingBlock: blockIndex)
        let layout = try self.layout(for: segmentIndex)
        let localBlockIndex = blockIndex - segmentation.segments[segmentIndex].blockRange.lowerBound
        let offset = ReaderTextPosition.characterOffset(
            for: ReaderTextAnchor(blockIndex: localBlockIndex, offsetInBlock: anchor.offsetInBlock),
            blockRanges: layout.rendered.blockRanges
        )
        return (segmentIndex, offset)
    }

    func anchor(in layout: ReaderSegmentLayout, offset: Int) -> ReaderTextAnchor {
        let local = ReaderTextPosition.anchor(forCharacterOffset: offset, blockRanges: layout.rendered.blockRanges)
        return ReaderTextAnchor(
            blockIndex: segmentation.segments[layout.segmentIndex].blockRange.lowerBound + local.blockIndex,
            offsetInBlock: local.offsetInBlock
        )
    }

    func location(in layout: ReaderSegmentLayout, offset: Int) -> TextReadingLocation {
        let anchor = anchor(in: layout, offset: offset)
        return TextReadingLocation(anchor: anchor, progress: segmentation.progress(for: anchor))
    }


    private func render(_ segmentIndex: Int) -> ReaderRenderedText {
        let segment = segmentation.segments[segmentIndex]
        return ReaderTextRenderer.render(
            ReaderTextContent(format: content.format, blocks: Array(content.blocks[segment.blockRange])),
            settings: request.settings
        )
    }

    @discardableResult
    private func store(_ layout: ReaderSegmentLayout) -> ReaderSegmentLayout {
        layouts[layout.segmentIndex] = layout
        touch(layout.segmentIndex)
        while recentlyUsed.count > Self.retainedLayoutCount, let evicted = recentlyUsed.first {
            recentlyUsed.removeFirst()
            layouts.removeValue(forKey: evicted)
        }
        return layout
    }

    private func touch(_ segmentIndex: Int) {
        recentlyUsed.removeAll { $0 == segmentIndex }
        recentlyUsed.append(segmentIndex)
    }
}
