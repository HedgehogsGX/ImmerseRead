import QuickLook
import SwiftUI

/// A compatibility preview for the legacy binary Word format.
///
/// Quick Look preserves access to the original document but does not promise
/// ebook-style reflow, progress tracking, or typography controls.
struct LegacyDocumentPreviewView: View {
    let document: ReaderDocument

    var body: some View {
        LegacyQuickLookController(fileURL: document.fileURL)
            .ignoresSafeArea(edges: .bottom)
            .accessibilityIdentifier("reader.legacyWord.preview")
    }
}

private struct LegacyQuickLookController: UIViewControllerRepresentable {
    let fileURL: URL

    func makeCoordinator() -> Coordinator {
        Coordinator(fileURL: fileURL)
    }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        guard context.coordinator.fileURL != fileURL else {
            return
        }
        context.coordinator.fileURL = fileURL
        controller.reloadData()
    }

    @MainActor
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var fileURL: URL

        init(fileURL: URL) {
            self.fileURL = fileURL
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
            1
        }

        func previewController(
            _ controller: QLPreviewController,
            previewItemAt index: Int
        ) -> QLPreviewItem {
            fileURL as NSURL
        }
    }
}

