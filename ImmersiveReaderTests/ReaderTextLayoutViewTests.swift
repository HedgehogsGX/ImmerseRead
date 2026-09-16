import Foundation
import Observation
import SwiftUI
import Testing
import UIKit
@testable import ImmersiveReader

@MainActor @Suite(.serialized)
struct ReaderTextLayoutViewTests {
    private let content = ReaderTextContent(
        format: .plainText,
        blocks: (0..<150).map { index in
            .paragraph("第 \(index) 段。" + String(repeating: "滚动与分页都只排版阅读位置附近的文字。", count: 15))
        }
    )

    @Test
    func scrollingModeKeepsAWindowOfSegmentsAndGrowsItWhileScrolling() async throws {
        let segmentation = ReaderTextSegmentation(blocks: content.blocks)
        #expect(segmentation.segments.count >= 3)

        let state = HarnessState(settings: ReaderDisplaySettings(layoutMode: .scrolling, fontSize: 18))
        let host = UIHostingController(rootView: Harness(content: content, state: state))
        let screen = await ReaderTestScreen.show(host)
        defer { screen.dismiss() }

        try await waitUntil { self.firstSubview(of: UITextView.self, in: host.view)?.textStorage.length ?? 0 > 0 }
        let textView = try #require(firstSubview(of: UITextView.self, in: host.view))
        let fullLength = ReaderTextRenderer.attributedString(for: content, settings: state.settings).length
        let initialLength = textView.textStorage.length
        #expect(initialLength < fullLength)
        try await waitUntil { state.location != nil }
        #expect(state.location?.anchor == ReaderTextAnchor(blockIndex: 0, offsetInBlock: 0))

        textView.setContentOffset(CGPoint(x: 0, y: textView.contentSize.height - textView.bounds.height), animated: false)
        try await waitUntil { textView.textStorage.length > initialLength }
        #expect(textView.textStorage.length < fullLength)
        try await waitUntil { (state.location?.anchor.blockIndex ?? 0) > 10 }

        let anchorBefore = try #require(state.location?.anchor)
        state.settings.fontSize = 30
        try await waitUntil { self.fontSize(in: host.view) == 30 }
        try await waitUntil { state.location != nil }
        let anchorAfter = try #require(state.location?.anchor)
        #expect(anchorAfter.blockIndex == anchorBefore.blockIndex)
        #expect(abs(anchorAfter.offsetInBlock - anchorBefore.offsetInBlock) < 40)
    }

    @Test
    func pagedModeOpensAtTheSavedAnchorAndTurnsPagesAcrossSegments() async throws {
        let segmentation = ReaderTextSegmentation(blocks: content.blocks)
        let targetBlock = segmentation.segments[1].blockRange.lowerBound + 2
        let saved = TextReadingLocation(anchor: ReaderTextAnchor(blockIndex: targetBlock, offsetInBlock: 12), progress: 0)
        let state = HarnessState(settings: ReaderDisplaySettings(layoutMode: .paged, fontSize: 18))
        let host = UIHostingController(rootView: Harness(content: content, state: state, initialLocation: saved))
        let screen = await ReaderTestScreen.show(host)
        defer { screen.dismiss() }

        try await waitUntil { self.pageController(in: host) != nil }
        let pageController = try #require(self.pageController(in: host))
        let opened = try #require(pageController.viewControllers?.first as? ReaderPageViewController)
        #expect(opened.page.segmentIndex == 1)
        try await waitUntil { state.location != nil }
        let openedAnchor = try #require(state.location?.anchor)
        #expect(openedAnchor.blockIndex <= targetBlock)
        #expect(opened.layout.pageRanges.count > 1)

        var current: ReaderPageViewController = opened
        var visited: [ReaderPageID] = [opened.page]
        while current.page.segmentIndex == 1 {
            let next = try #require(
                pageController.dataSource?.pageViewController(pageController, viewControllerAfter: current)
                    as? ReaderPageViewController
            )
            visited.append(next.page)
            current = next
        }
        #expect(current.page == ReaderPageID(segmentIndex: 2, pageIndex: 0))
        let segmentOnePages = visited.filter { $0.segmentIndex == 1 }.map(\.pageIndex)
        #expect(segmentOnePages == Array(opened.page.pageIndex ..< opened.layout.pageRanges.count))

        let firstOfSegment = try #require(
            pageController.dataSource?.pageViewController(pageController, viewControllerBefore: current)
                as? ReaderPageViewController
        )
        #expect(firstOfSegment.page.segmentIndex == 1)
        #expect(firstOfSegment.page.pageIndex == firstOfSegment.layout.pageRanges.count - 1)

        let layout = firstOfSegment.layout
        #expect(layout.pageRanges.first?.location == 0)
        #expect(layout.pageRanges.last.map(NSMaxRange) == layout.text.length)
        for (previous, next) in zip(layout.pageRanges, layout.pageRanges.dropFirst()) {
            #expect(NSMaxRange(previous) == next.location)
        }
    }

    @Test
    func switchingModesKeepsTheReadingPosition() async throws {
        let state = HarnessState(settings: ReaderDisplaySettings(layoutMode: .paged, fontSize: 18))
        let saved = TextReadingLocation(anchor: ReaderTextAnchor(blockIndex: 80, offsetInBlock: 5), progress: 0)
        let host = UIHostingController(rootView: Harness(content: content, state: state, initialLocation: saved))
        let screen = await ReaderTestScreen.show(host)
        defer { screen.dismiss() }

        try await waitUntil { state.location != nil }
        let pagedAnchor = try #require(state.location?.anchor)
        #expect(abs(pagedAnchor.blockIndex - 80) <= 1)

        state.settings.layoutMode = .scrolling
        try await waitUntil { self.firstSubview(of: ReaderWindowedTextView.self, in: host.view) != nil }
        try await waitUntil { state.location?.anchor.blockIndex == pagedAnchor.blockIndex }
        let scrollingAnchor = try #require(state.location?.anchor)
        #expect(abs(scrollingAnchor.offsetInBlock - pagedAnchor.offsetInBlock) < 40)
    }

    @Test
    func navigationJumpsToThePassageAndMarginsChangeTheActualTextView() async throws {
        let state = HarnessState(settings: ReaderDisplaySettings(layoutMode: .scrolling))
        let model = ReaderNavigationModel(document: ReaderDocument(
            id: UUID(), title: "Navigation", fileURL: URL(fileURLWithPath: "/tmp/navigation.txt"), format: .plainText
        ))
        let host = UIHostingController(rootView: Harness(content: content, state: state, navigationModel: model))
        let screen = await ReaderTestScreen.show(host)
        defer { screen.dismiss() }
        try await waitUntil { state.location != nil }
        let target = ReaderTextAnchor(blockIndex: 110, offsetInBlock: 50)
        model.requestJump(to: .text(TextReadingLocation(anchor: target, progress: 0)))
        try await waitUntil { state.location?.anchor == target }
        state.settings.margin = 40
        try await waitUntil { self.firstSubview(of: UITextView.self, in: host.view)?.textContainerInset.left == 40 }
        #expect(state.location?.anchor == target)
        #expect(firstSubview(of: UITextView.self, in: host.view)?.textContainerInset.right == 40)
    }

    @Test
    func scrollingBeyondTheWindowEvictsSegmentsWithoutJumpingBackToTheBeginning() async throws {
        let largeContent = ReaderTextContent(format: .plainText, blocks: (0..<600).map { index in
            .paragraph("Paragraph \(index). " + String(repeating: "A stable passage remains visible. ", count: 10))
        })
        let segmentation = ReaderTextSegmentation(blocks: largeContent.blocks)
        let state = HarnessState(settings: ReaderDisplaySettings(layoutMode: .scrolling, fontSize: 18))
        let host = UIHostingController(rootView: Harness(content: largeContent, state: state))
        let screen = await ReaderTestScreen.show(host)
        defer { screen.dismiss() }
        try await waitUntil { state.location != nil }
        let textView = try #require(firstSubview(of: UITextView.self, in: host.view))
        for index in 0..<6 {
            textView.layoutManager.ensureLayout(for: textView.textContainer)
            textView.layoutIfNeeded()
            textView.setContentOffset(CGPoint(x: 0, y: textView.contentSize.height - textView.bounds.height), animated: false)
            let minimumBlock = segmentation.segments[index].blockRange.lowerBound + 10
            try await waitUntil { (state.location?.anchor.blockIndex ?? 0) > minimumBlock }
            #expect(textView.textStorage.length < ReaderScrollingTextView.windowSegmentCount * (ReaderTextSegmentation.targetSegmentLength + 500))
        }
        let furthest = try #require(state.location?.anchor.blockIndex)
        for _ in 0..<4 {
            let previous = try #require(state.location?.anchor.blockIndex)
            textView.setContentOffset(.zero, animated: false)
            try await waitUntil { (state.location?.anchor.blockIndex ?? previous) < previous }
        }
        #expect(try #require(state.location?.anchor.blockIndex) < furthest)
    }

    private func pageController(in host: UIViewController) -> UIPageViewController? {
        func search(_ controller: UIViewController) -> UIPageViewController? {
            if let pageController = controller as? UIPageViewController {
                return pageController
            }
            for child in controller.children {
                if let found = search(child) {
                    return found
                }
            }
            return nil
        }
        return search(host)
    }

    private func fontSize(in view: UIView) -> CGFloat? {
        guard let textView = firstSubview(of: UITextView.self, in: view),
              let text = textView.attributedText,
              text.length > 0 else {
            return nil
        }
        return (text.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)?.pointSize
    }

    private func firstSubview<T: UIView>(of type: T.Type, in view: UIView) -> T? {
        if let matchingView = view as? T {
            return matchingView
        }
        for subview in view.subviews {
            if let matchingView = firstSubview(of: type, in: subview) {
                return matchingView
            }
        }
        return nil
    }

    private func waitUntil(line: Int = #line, _ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(6))
        while ContinuousClock.now < deadline {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(30))
        }
        throw HarnessError.timedOut(line: line)
    }
}

@MainActor @Observable
private final class HarnessState {
    var settings: ReaderDisplaySettings
    var location: TextReadingLocation?

    init(settings: ReaderDisplaySettings) {
        self.settings = settings
    }
}

@MainActor
private struct Harness: View {
    let content: ReaderTextContent
    @Bindable var state: HarnessState
    var initialLocation: TextReadingLocation? = nil
    var navigationModel: ReaderNavigationModel? = nil

    var body: some View {
        ReaderTextLayoutView(
            content: content,
            settings: state.settings,
            initialLocation: initialLocation,
            onLocationChange: { state.location = $0 },
            navigationModel: navigationModel
        )
    }
}

private enum HarnessError: Error {
    case timedOut(line: Int)
}
