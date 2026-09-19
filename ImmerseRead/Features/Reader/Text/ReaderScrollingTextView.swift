import SwiftUI
import UIKit

struct ReaderScrollingTextView: UIViewRepresentable {
    static let windowSegmentCount = 4

    let store: ReaderSegmentLayoutStore
    let request: ReaderLayoutRequest
    let initialAnchor: ReaderTextAnchor
    let onLocationChange: (TextReadingLocation) -> Void
    let onFailure: (Error) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(store: store)
    }

    func makeUIView(context: Context) -> ReaderWindowedTextView {
        let textView = ReaderWindowedTextView.make()
        textView.textContainerInset = request.contentInsets
        textView.delegate = context.coordinator
        textView.onLayout = { [weak coordinator = context.coordinator] view in
            coordinator?.textViewDidLayout(view)
        }
        context.coordinator.attach(textView)
        return textView
    }

    func updateUIView(_ textView: ReaderWindowedTextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onLocationChange = onLocationChange
        coordinator.onFailure = onFailure
        textView.backgroundColor = UIColor(request.settings.theme.backgroundColor)
        coordinator.apply(request: request, initialAnchor: initialAnchor)
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var onLocationChange: (TextReadingLocation) -> Void = { _ in }
        var onFailure: (Error) -> Void = { _ in }

        private let store: ReaderSegmentLayoutStore
        private weak var textView: ReaderWindowedTextView?
        private var appliedRequest: ReaderLayoutRequest?
        private var window: [WindowEntry] = []
        private var pendingStorageOffset: Int?
        private var isAdjusting = false
        private var lastReportedAnchor: ReaderTextAnchor?
        private var pendingLocation: TextReadingLocation?
        private var reportTask: Task<Void, Never>?

        init(store: ReaderSegmentLayoutStore) {
            self.store = store
        }

        func attach(_ textView: ReaderWindowedTextView) {
            self.textView = textView
        }

        func apply(request: ReaderLayoutRequest, initialAnchor: ReaderTextAnchor) {
            guard request.canLayOut, request != appliedRequest else { return }
            let anchor = lastReportedAnchor ?? currentAnchor ?? initialAnchor
            appliedRequest = request
            store.reset(request: request)
            textView?.textContainerInset = request.contentInsets
            rebuild(at: anchor)
        }

        var currentAnchor: ReaderTextAnchor? {
            guard let textView, let offset = visibleStorageOffset(in: textView),
                  let entry = entry(containing: offset) else { return nil }
            return store.anchor(in: entry.layout, offset: offset - entry.start)
        }

        private func rebuild(at anchor: ReaderTextAnchor) {
            guard let textView else { return }
            do {
                let position = try store.position(of: anchor)
                let layout = try store.layout(for: position.segmentIndex)
                isAdjusting = true
                window = [WindowEntry(layout: layout, start: 0)]
                textView.attributedText = layout.text
                textView.contentOffset = .zero
                isAdjusting = false
                pendingStorageOffset = position.offset
                lastReportedAnchor = anchor
                textViewDidLayout(textView)
            } catch {
                onFailure(error)
            }
        }

        func textViewDidLayout(_ textView: UITextView) {
            guard !isAdjusting, textView.bounds.width > 0, textView.bounds.height > 0,
                  textView.textStorage.length > 0 else { return }
            if let pendingStorageOffset {
                self.pendingStorageOffset = nil
                scroll(textView, toStorageOffset: pendingStorageOffset)
                if let anchor = lastReportedAnchor {
                    publish(TextReadingLocation(anchor: anchor, progress: store.segmentation.progress(for: anchor)))
                }
            }
            extendWindowIfNeeded(in: textView)
        }


        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard !isAdjusting, pendingStorageOffset == nil,
                  let textView = scrollView as? ReaderWindowedTextView else { return }
            extendWindowIfNeeded(in: textView)
            reportVisibleLocation(in: textView)
        }


        private func extendWindowIfNeeded(in textView: UITextView) {
            guard !isAdjusting, let first = window.first, let last = window.last,
                  let visibleOffset = visibleStorageOffset(in: textView),
                  let visibleIndex = window.firstIndex(where: { $0.contains(visibleOffset) }) else { return }
            let viewportHeight = textView.bounds.height
            let distanceToEnd = textView.contentSize.height - (textView.contentOffset.y + viewportHeight)
            let isFull = window.count >= ReaderScrollingTextView.windowSegmentCount
            store.prefetch([window[visibleIndex].layout.segmentIndex + 1, window[visibleIndex].layout.segmentIndex - 1])

            if distanceToEnd < viewportHeight, last.layout.segmentIndex + 1 < store.segmentCount {
                if isFull {
                    guard visibleIndex >= 2 else { return }
                    dropFirst(from: textView)
                }
                append(segmentIndex: last.layout.segmentIndex + 1, to: textView)
            } else if textView.contentOffset.y < viewportHeight, first.layout.segmentIndex > 0 {
                if isFull {
                    guard visibleIndex <= window.count - 3 else { return }
                    dropLast(from: textView)
                }
                prepend(segmentIndex: first.layout.segmentIndex - 1, to: textView)
            }
        }

        private func append(segmentIndex: Int, to textView: UITextView) {
            do {
                let layout = try store.layout(for: segmentIndex)
                isAdjusting = true
                defer { isAdjusting = false }
                let start = textView.textStorage.length
                let contentOffset = textView.contentOffset
                textView.textStorage.append(layout.text)
                window.append(WindowEntry(layout: layout, start: start))
                textView.layoutManager.ensureLayout(for: textView.textContainer)
                textView.layoutIfNeeded()
                textView.setContentOffset(contentOffset, animated: false)
            } catch {
                onFailure(error)
            }
        }

        private func prepend(segmentIndex: Int, to textView: UITextView) {
            do {
                let layout = try store.layout(for: segmentIndex)
                isAdjusting = true
                defer { isAdjusting = false }
                let insertedLength = layout.text.length
                let contentOffset = textView.contentOffset
                textView.textStorage.insert(layout.text, at: 0)
                for index in window.indices {
                    window[index].start += insertedLength
                }
                window.insert(WindowEntry(layout: layout, start: 0), at: 0)
                let insertedHeight = shift(in: textView, ofCharacterAt: insertedLength)
                textView.layoutIfNeeded()
                textView.setContentOffset(CGPoint(x: contentOffset.x, y: contentOffset.y + insertedHeight), animated: false)
            } catch {
                onFailure(error)
            }
        }

        private func dropFirst(from textView: UITextView) {
            isAdjusting = true
            defer { isAdjusting = false }
            let removed = window.removeFirst()
            let shift = shift(in: textView, ofCharacterAt: removed.length)
            let contentOffset = textView.contentOffset
            textView.textStorage.deleteCharacters(in: NSRange(location: 0, length: removed.length))
            for index in window.indices {
                window[index].start -= removed.length
            }
            textView.layoutIfNeeded()
            textView.setContentOffset(CGPoint(x: contentOffset.x, y: max(0, contentOffset.y - shift)), animated: false)
        }

        private func dropLast(from textView: UITextView) {
            isAdjusting = true
            defer { isAdjusting = false }
            let removed = window.removeLast()
            let contentOffset = textView.contentOffset
            textView.textStorage.deleteCharacters(in: NSRange(location: removed.start, length: removed.length))
            textView.layoutIfNeeded()
            textView.setContentOffset(contentOffset, animated: false)
        }

        private func shift(in textView: UITextView, ofCharacterAt offset: Int) -> CGFloat {
            let layoutManager = textView.layoutManager
            let clampedOffset = min(max(offset, 0), max(textView.textStorage.length - 1, 0))
            layoutManager.ensureLayout(forCharacterRange: NSRange(location: 0, length: clampedOffset + 1))
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: clampedOffset)
            return layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil).minY
        }


        private func scroll(_ textView: UITextView, toStorageOffset offset: Int) {
            isAdjusting = true
            defer { isAdjusting = false }
            textView.layoutManager.ensureLayout(for: textView.textContainer)
            textView.layoutIfNeeded()
            let maximumOffset = max(0, textView.contentSize.height - textView.bounds.height)
            let targetOffset = offset == 0
                ? 0
                : shift(in: textView, ofCharacterAt: offset) + textView.textContainerInset.top
            textView.setContentOffset(
                CGPoint(x: 0, y: min(max(targetOffset, 0), maximumOffset)),
                animated: false
            )
        }

        private func visibleStorageOffset(in textView: UITextView) -> Int? {
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

        private func entry(containing storageOffset: Int) -> WindowEntry? {
            window.first { $0.contains(storageOffset) } ?? window.last
        }

        private func reportVisibleLocation(in textView: UITextView) {
            guard let offset = visibleStorageOffset(in: textView),
                  let entry = entry(containing: offset) else { return }
            let location = store.location(in: entry.layout, offset: offset - entry.start)
            guard location.anchor != lastReportedAnchor else { return }

            lastReportedAnchor = location.anchor
            publish(location)
        }

        private func publish(_ location: TextReadingLocation) {
            pendingLocation = location
            guard reportTask == nil else { return }
            reportTask = Task { @MainActor [weak self] in
                await Task.yield()
                guard !Task.isCancelled, let self else { return }
                reportTask = nil
                guard let location = pendingLocation else { return }
                pendingLocation = nil
                onLocationChange(location)
            }
        }

        private struct WindowEntry {
            let layout: ReaderSegmentLayout
            var start: Int

            var length: Int {
                layout.text.length
            }

            func contains(_ storageOffset: Int) -> Bool {
                storageOffset >= start && storageOffset < start + length
            }
        }
    }
}

final class ReaderWindowedTextView: UITextView {
    var onLayout: ((UITextView) -> Void)?

    @MainActor
    static func make() -> ReaderWindowedTextView {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)
        container.widthTracksTextView = true
        container.heightTracksTextView = false
        container.lineFragmentPadding = 0

        let textView = ReaderWindowedTextView(frame: .zero, textContainer: container)
        ReaderTextView.configure(textView, scrolling: true)
        return textView
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?(self)
    }
}
