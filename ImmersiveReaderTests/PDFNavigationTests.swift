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
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let previousKeyWindow = scenes.flatMap(\.windows).first(where: \.isKeyWindow)
        let window = scenes.first.map(UIWindow.init(windowScene:)) ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }

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
        let deadline = ContinuousClock.now.advanced(by: .seconds(6))
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(30))
        }
        throw CocoaError(.coderReadCorrupt)
    }
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
