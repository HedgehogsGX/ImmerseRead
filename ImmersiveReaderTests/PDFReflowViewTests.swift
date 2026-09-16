import Foundation
import Observation
import PDFKit
import SwiftUI
import Testing
import UIKit
@testable import ImmersiveReader

@MainActor @Suite(.serialized)
struct PDFReflowViewTests {
    @Test
    func changingPDFTypographyChangesTheActualFontWithoutExtractingAgain() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PDFReflowViewTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let fileURL = directoryURL.appendingPathComponent("reader.pdf")
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
        let data = renderer.pdfData { context in
            context.beginPage()
            ("Readable PDF text that should use a real adjustable font." as NSString).draw(
                in: CGRect(x: 48, y: 60, width: 510, height: 600),
                withAttributes: [.font: UIFont.systemFont(ofSize: 12)]
            )
        }
        try data.write(to: fileURL, options: .atomic)

        let document = ReaderDocument(id: UUID(), title: "PDF", fileURL: fileURL, format: .pdf)
        let state = PDFReflowHarnessState()
        let extractor = CountingPDFTextExtractor()
        let host = UIHostingController(rootView: PDFReflowHarness(
            document: document,
            state: state,
            extractor: extractor
        ))
        let screen = await ReaderTestScreen.show(host)
        defer { screen.dismiss() }

        try await waitUntil {
            self.fontSize(in: host.view) == 19
        }
        #expect(firstSubview(of: PDFView.self, in: host.view) == nil)

        state.settings.fontSize = 36
        try await waitUntil {
            self.fontSize(in: host.view) == 36
        }
        let textView = try #require(firstSubview(of: UITextView.self, in: host.view))
        #expect(textView.zoomScale == 1)
        #expect(textView.transform == .identity)
        let countAfterFontChange = await extractor.invocationCount
        #expect(countAfterFontChange == 1)

        state.mode = .original
        try await waitUntil {
            self.firstSubview(of: PDFView.self, in: host.view)?.document != nil
        }
        state.mode = .reflow
        try await waitUntil {
            self.fontSize(in: host.view) == 36
        }
        let countAfterModeSwitch = await extractor.invocationCount
        #expect(countAfterModeSwitch == 1)
    }

    @Test
    func textPositionSurvivesFontChangesOriginalModeAndReopening() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PDFReflowPositionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let fileURL = directoryURL.appendingPathComponent("uneven-pages.pdf")
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
        let data = renderer.pdfData { context in
            for (page, count) in [4, 12, 20].enumerated() {
                context.beginPage()
                let text = (0..<count).map { paragraph in
                    "Page \(page + 1), paragraph \(paragraph + 1). The same passage stays visible when the font changes."
                }.joined(separator: "\n\n")
                (text as NSString).draw(
                    in: CGRect(x: 48, y: 48, width: 516, height: 690),
                    withAttributes: [.font: UIFont.systemFont(ofSize: 10)]
                )
            }
        }
        try data.write(to: fileURL, options: .atomic)

        let document = ReaderDocument(id: UUID(), title: "位置恢复", fileURL: fileURL, format: .pdf)
        let state = PDFReflowHarnessState()
        let extractor = CountingPDFTextExtractor()
        let host = UIHostingController(rootView: PDFReflowHarness(
            document: document, state: state, extractor: extractor
        ))
        let screen = await ReaderTestScreen.show(host)
        defer { screen.dismiss() }

        try await waitUntil { self.fontSize(in: host.view) == 19 }
        let textView = try #require(firstSubview(of: UITextView.self, in: host.view))
        textView.layoutManager.ensureLayout(for: textView.textContainer)
        textView.layoutIfNeeded()
        #expect(textView.contentSize.height > textView.bounds.height * 2)
        textView.setContentOffset(CGPoint(x: 0, y: textView.contentSize.height * 0.5), animated: false)
        try await waitUntil { state.location.reflowProgress > 0.3 }
        let anchor = visibleCharacterOffset(in: textView)

        for fontSize in [32.0, 14.0, 26.0] {
            state.settings.fontSize = fontSize
            try await waitUntil { self.fontSize(in: host.view) == fontSize }
            let currentView = try #require(firstSubview(of: UITextView.self, in: host.view))
            #expect(abs(visibleCharacterOffset(in: currentView) - anchor) < 120)
        }
        let savedReflowProgress = state.location.reflowProgress

        state.mode = .original
        try await waitUntil {
            self.firstSubview(of: PDFView.self, in: host.view)?.document != nil
        }
        let pdfView = try #require(firstSubview(of: PDFView.self, in: host.view))
        let finalPage = try #require(pdfView.document?.page(at: 2))
        pdfView.go(to: finalPage)
        try await waitUntil { state.location.originalProgress == 1 }
        #expect(state.location.reflowProgress == savedReflowProgress)

        state.mode = .reflow
        try await waitUntil { self.fontSize(in: host.view) == 26 }
        let returnedView = try #require(firstSubview(of: UITextView.self, in: host.view))
        #expect(abs(visibleCharacterOffset(in: returnedView) - anchor) < 120)
        try await waitUntil {
            state.savedLocationData.flatMap {
                try? JSONDecoder().decode(PDFReadingLocation.self, from: $0)
            }?.mode == .reflow
        }

        let savedData = try #require(state.savedLocationData)
        let reopenedState = PDFReflowHarnessState()
        reopenedState.settings = state.settings
        reopenedState.location = PDFReadingLocation.restore(from: savedData, legacyOriginalProgress: 1)
        #expect(reopenedState.location.originalProgress == 1)
        #expect(reopenedState.location.reflowProgress == savedReflowProgress)
        let reopenedHost = UIHostingController(rootView: PDFReflowHarness(
            document: document, state: reopenedState, extractor: extractor
        ))
        screen.present(reopenedHost)
        try await waitUntil { self.fontSize(in: reopenedHost.view) == 26 }
        let reopenedTextView = try #require(firstSubview(of: UITextView.self, in: reopenedHost.view))
        #expect(abs(visibleCharacterOffset(in: reopenedTextView) - anchor) < 120)
    }

    private func visibleCharacterOffset(in textView: UITextView) -> Int {
        textView.layoutManager.characterIndex(
            for: CGPoint(x: 0, y: max(0, textView.contentOffset.y - textView.textContainerInset.top + 1)),
            in: textView.textContainer,
            fractionOfDistanceBetweenInsertionPoints: nil
        )
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

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(6))
        while ContinuousClock.now < deadline {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(30))
        }
        throw PDFViewTestError.timedOut
    }
}

@MainActor @Observable
private final class PDFReflowHarnessState {
    var settings = ReaderDisplaySettings(layoutMode: .scrolling)
    var location = PDFReadingLocation()
    var savedLocationData: Data?

    var mode: PDFReadingMode {
        get { location.mode }
        set { location.mode = newValue }
    }
}

@MainActor
private struct PDFReflowHarness: View {
    let document: ReaderDocument
    @Bindable var state: PDFReflowHarnessState
    let extractor: CountingPDFTextExtractor

    var body: some View {
        PDFDocumentReaderView(
            document: document,
            settings: $state.settings,
            location: $state.location,
            extractor: extractor
        )
        .onChange(of: state.location) { _, value in
            state.savedLocationData = value.encoded()
        }
    }
}

private actor CountingPDFTextExtractor: PDFTextExtracting {
    private(set) var invocationCount = 0

    func extract(document: ReaderDocument) async throws -> PDFReflowContent {
        invocationCount += 1
        return try await PDFTextExtractor().extract(document: document)
    }
}

private enum PDFViewTestError: Error {
    case timedOut
}
