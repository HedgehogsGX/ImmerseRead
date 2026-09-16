import Combine
import Foundation
import Observation
import PDFKit
import SwiftUI
import Testing
import UIKit
@testable import ImmersiveReader

@MainActor @Suite(.serialized)
struct PDFNavigationTests {
    @Test @MainActor
    func emptyOutlineFallsBackToEveryPage() throws {
        let document = try #require(makeDocument(pageCount: 3))
        let sections = PDFNavigationSupport.sections(for: document)
        #expect(sections.map(\.location) == [.pdfPage(0), .pdfPage(1), .pdfPage(2)])
        #expect(sections.map(\.title) == (1...3).map { String(localized: "第 \($0) 页") })
    }

    @Test @MainActor
    func searchReturnsPageLocationsAndSnippets() async throws {
        let document = try #require(makeTextDocument())
        let results = try await PDFNavigationSupport.search(query: "needle", in: document)
        #expect(results.count == 1)
        #expect(results.first?.location == .pdfPage(1))
        #expect(results.first?.snippet.localizedCaseInsensitiveContains("needle") == true)
    }

    @Test @MainActor
    func originalModeRestoresPageAndRoutesNavigationJumps() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PDFNavigationHostTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("reader.pdf")
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 300, height: 400))
        let data = renderer.pdfData { context in
            for page in 0 ..< 3 {
                context.beginPage()
                NSString(string: "Page \(page + 1)").draw(at: CGPoint(x: 20, y: 20), withAttributes: [.font: UIFont.systemFont(ofSize: 18)])
            }
        }
        try data.write(to: fileURL, options: .atomic)

        let document = ReaderDocument(id: UUID(), title: "PDF", fileURL: fileURL, format: .pdf)
        let model = ReaderNavigationModel(document: document, bookmarkStore: ReaderBookmarkStore(directory: directory))
        let state = PDFOriginalHarnessState()
        state.location = PDFReadingLocation(mode: .original, originalProgress: 1)
        let host = UIHostingController(rootView: PDFOriginalHarness(document: document, state: state, navigationModel: model))
        let screen = await ReaderTestScreen.show(host)
        defer { screen.dismiss() }

        try await waitUntil { self.pdfView(in: host.view)?.document != nil }
        let pdfView = try #require(self.pdfView(in: host.view))
        try await waitUntil {
            guard let document = pdfView.document, let page = pdfView.currentPage else { return false }
            return document.index(for: page) == 2
        }
        #expect(state.location.originalProgress == 1)
        model.requestJump(to: .pdfPage(0))
        try await waitUntil {
            guard let document = pdfView.document, let page = pdfView.currentPage else { return false }
            return document.index(for: page) == 0
        }
        try await waitUntil { model.jumpRequest == nil }
    }

    @Test @MainActor
    func extractionRecordsWhereEachPageStartsInTheReflowedText() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PDFPageMapTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("reader.pdf")
        try Self.pagedPDFData().write(to: fileURL, options: .atomic)

        let content = try await PDFTextExtractor().extract(
            document: ReaderDocument(id: UUID(), title: "PDF", fileURL: fileURL, format: .pdf)
        )

        #expect(content.pageStartBlockIndices == [0, 1, 2])
        #expect(content.blockIndex(forPage: 2) == 2)
        #expect(content.blockIndex(forPage: 9) == nil)
        // A map-less content (an older cache) has nothing to offer.
        #expect(PDFReflowContent(
            textContent: content.textContent,
            pageCount: content.pageCount,
            pagesWithoutText: []
        ).blockIndex(forPage: 0) == nil)
    }

    @Test @MainActor
    func contentsJumpMovesTheReflowedTextInsteadOfShowingTheOriginal() async throws {
        let fixture = try await ContentsJumpFixture.make()
        defer { fixture.remove() }

        try await fixture.waitUntilTextIsOnScreen()
        // The contents list addresses source pages even for a reflowed PDF.
        #expect(fixture.model.sections.map(\.location) == [.pdfPage(0), .pdfPage(1), .pdfPage(2)])

        fixture.model.requestJump(to: .pdfPage(2))

        // The page resolves into the reflowed text, exactly once, and the text
        // stays on screen instead of being replaced by the original pages.
        try await fixture.waitUntil { fixture.model.jumpRequest == nil }
        #expect(fixture.recorder.textJumpBlockIndices == [ContentsJumpFixture.thirdPageBlock])
        #expect(fixture.location.mode == .reflow)
        #expect(fixture.location.reflowProgress > 0)
        #expect(fixture.hasTextSurface)
        #expect(fixture.pdfView == nil)
    }

    @Test @MainActor
    func contentsJumpDuringExtractionWaitsForTheTextInsteadOfShowingTheOriginal() async throws {
        let fixture = try await ContentsJumpFixture.make(holdExtraction: true)
        defer { fixture.remove() }

        try await fixture.waitUntil { fixture.gate.didStart }
        fixture.model.requestJump(to: .pdfPage(2))
        try await Task.sleep(for: .milliseconds(120))
        // Still extracting: the reader waits for its text rather than switching.
        #expect(fixture.location.mode == .reflow)
        #expect(fixture.location.reflowAnchor == nil)
        #expect(fixture.pdfView == nil)

        fixture.gate.open()
        try await fixture.waitUntil { fixture.model.jumpRequest == nil }
        #expect(fixture.recorder.textJumpBlockIndices == [ContentsJumpFixture.thirdPageBlock])
        #expect(fixture.location.mode == .reflow)
        #expect(fixture.pdfView == nil)
    }

    @Test @MainActor
    func pageJumpFallsBackToTheOriginalWhenThereIsNoReflowedText() async throws {
        let fixture = try await ContentsJumpFixture.make(content: nil)
        defer { fixture.remove() }

        try await fixture.waitUntil { fixture.gate.didStart }
        fixture.model.requestJump(to: .pdfPage(2))

        // Nothing to reflow, so the source pages are the honest answer.
        try await fixture.waitUntil { fixture.pdfView != nil }
        #expect(fixture.location.mode == .original)
        #expect(fixture.recorder.textJumpBlockIndices.isEmpty)
    }

    private static func pagedPDFData() -> Data {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 300, height: 400))
        return renderer.pdfData { context in
            for page in 0 ..< 3 {
                context.beginPage()
                NSString(string: "Page \(page + 1) of the body text.").draw(
                    at: CGPoint(x: 20, y: 20),
                    withAttributes: [.font: UIFont.systemFont(ofSize: 11)]
                )
            }
        }
    }

    private func makeDocument(pageCount: Int) -> PDFDocument? {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 300, height: 400))
        let data = renderer.pdfData { context in
            for _ in 0 ..< pageCount {
                context.beginPage()
            }
        }
        return PDFDocument(data: data)
    }

    private func makeTextDocument() -> PDFDocument? {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 300, height: 400))
        let data = renderer.pdfData { context in
            context.beginPage()
            NSString(string: "first page").draw(at: CGPoint(x: 20, y: 20), withAttributes: [.font: UIFont.systemFont(ofSize: 18)])
            context.beginPage()
            NSString(string: "second page needle").draw(at: CGPoint(x: 20, y: 20), withAttributes: [.font: UIFont.systemFont(ofSize: 18)])
        }
        return PDFDocument(data: data)
    }

    private func pdfView(in view: UIView) -> PDFView? {
        if let pdfView = view as? PDFView { return pdfView }
        for subview in view.subviews {
            if let pdfView = pdfView(in: subview) { return pdfView }
        }
        return nil
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(30))
        }
        throw CocoaError(.coderReadCorrupt)
    }
}

/// Records the jumps the reader asks for, so a contents tap can be checked
/// independently of where the laid-out page happens to start.
@MainActor
private final class JumpRecorder {
    private(set) var textJumpBlockIndices: [Int] = []
    private var cancellable: AnyCancellable?

    init(model: ReaderNavigationModel) {
        cancellable = model.$jumpRequest.sink { [weak self] request in
            guard case .text(let location)? = request?.location else { return }
            MainActor.assumeIsolated { self?.textJumpBlockIndices.append(location.anchor.blockIndex) }
        }
    }
}

@MainActor @Observable
private final class PDFReflowHarnessState {
    var settings = ReaderDisplaySettings(layoutMode: .paged)
    var location = PDFReadingLocation(mode: .reflow)
}

@MainActor
private struct PDFReflowHarness: View {
    let document: ReaderDocument
    @Bindable var state: PDFReflowHarnessState
    let navigationModel: ReaderNavigationModel
    var extractor: any PDFTextExtracting = PDFTextExtractor()

    var body: some View {
        PDFDocumentReaderView(
            document: document,
            settings: $state.settings,
            location: $state.location,
            navigationModel: navigationModel,
            extractor: extractor
        )
    }
}

/// Holds extraction open so a jump can arrive while the reader is still loading.
private final class ExtractionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen: Bool
    private var hasStarted = false

    init(isOpen: Bool) {
        self.isOpen = isOpen
    }

    var didStart: Bool { lock.withLock { hasStarted } }

    func markStarted() { lock.withLock { hasStarted = true } }
    func open() { lock.withLock { isOpen = true } }
    func waitForOpening() async throws {
        while !lock.withLock({ isOpen }) {
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

/// Stands in for PDF extraction: real extraction is covered on its own, and
/// keeping PDFKit out of the hosted view keeps this test deterministic.
private struct StubPDFTextExtractor: PDFTextExtracting {
    let gate: ExtractionGate
    let content: PDFReflowContent?

    func extract(document: ReaderDocument) async throws -> PDFReflowContent {
        gate.markStarted()
        try await gate.waitForOpening()
        guard let content else { throw PDFTextExtractionError.noExtractableText }
        return content
    }
}

/// Hosts the PDF reader on screen with stubbed text, and watches where a
/// contents tap sends it.
@MainActor
private final class ContentsJumpFixture {
    /// The stub puts three blocks on each of its three source pages.
    static let thirdPageBlock = 6

    let model: ReaderNavigationModel
    let recorder: JumpRecorder
    let gate: ExtractionGate

    private let directory: URL
    private let state = PDFReflowHarnessState()
    private let host: UIHostingController<PDFReflowHarness>
    private let screen: ReaderTestScreen

    var location: PDFReadingLocation { state.location }
    var pdfView: PDFView? { Self.firstPDFView(in: host.view) }
    var hasTextSurface: Bool { Self.view(withIdentifier: "reader.pages", in: host.view) != nil }

    static func make(content: PDFReflowContent? = .stub, holdExtraction: Bool = false) async throws -> ContentsJumpFixture {
        try await ContentsJumpFixture(content: content, holdExtraction: holdExtraction)
    }

    private init(content: PDFReflowContent?, holdExtraction: Bool) async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PDFContentsJumpTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("reader.pdf")
        // Only the page count matters here; the text comes from the stub.
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 300, height: 400))
        try renderer.pdfData { context in
            for _ in 0 ..< 3 { context.beginPage() }
        }.write(to: fileURL, options: .atomic)

        let document = ReaderDocument(id: UUID(), title: "PDF", fileURL: fileURL, format: .pdf)
        model = ReaderNavigationModel(document: document, bookmarkStore: ReaderBookmarkStore(directory: directory))
        recorder = JumpRecorder(model: model)
        gate = ExtractionGate(isOpen: !holdExtraction)
        host = UIHostingController(rootView: PDFReflowHarness(
            document: document,
            state: state,
            navigationModel: model,
            extractor: StubPDFTextExtractor(gate: gate, content: content)
        ))

        screen = await ReaderTestScreen.show(host)
    }

    func remove() {
        screen.dismiss()
        try? FileManager.default.removeItem(at: directory)
    }

    func waitUntilTextIsOnScreen() async throws {
        try await waitUntil { Self.view(withIdentifier: "reader.pages", in: self.host.view) != nil }
    }

    func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(30))
        }
        throw CocoaError(.coderReadCorrupt)
    }

    private static func view(withIdentifier identifier: String, in view: UIView) -> UIView? {
        if view.accessibilityIdentifier == identifier { return view }
        for subview in view.subviews {
            if let match = self.view(withIdentifier: identifier, in: subview) { return match }
        }
        return nil
    }

    private static func firstPDFView(in view: UIView) -> PDFView? {
        if let pdfView = view as? PDFView { return pdfView }
        for subview in view.subviews {
            if let pdfView = firstPDFView(in: subview) { return pdfView }
        }
        return nil
    }
}

private extension PDFReflowContent {
    /// Three source pages of three paragraphs each, long enough to lay out over
    /// several reflowed pages.
    static let stub = PDFReflowContent(
        textContent: ReaderTextContent(format: .pdf, blocks: (0 ..< 9).map { index in
            .paragraph("第 \(index) 段。" + String(repeating: "重排后的正文会随字号重新换行与分页。", count: 12))
        }),
        pageCount: 3,
        pagesWithoutText: [],
        pageStartBlockIndices: [0, 3, 6]
    )
}

@MainActor @Observable
private final class PDFOriginalHarnessState {
    var settings = ReaderDisplaySettings(layoutMode: .paged)
    var location = PDFReadingLocation(mode: .original)
}

@MainActor
private struct PDFOriginalHarness: View {
    let document: ReaderDocument
    @Bindable var state: PDFOriginalHarnessState
    let navigationModel: ReaderNavigationModel

    var body: some View {
        PDFDocumentReaderView(
            document: document,
            settings: $state.settings,
            location: $state.location,
            navigationModel: navigationModel
        )
    }
}
