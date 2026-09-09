import SwiftUI

struct EPUBReaderHostView: View {
    let document: ReaderDocument
    @Binding var settings: ReaderDisplaySettings
    let initialLocation: EPUBReadingLocation?
    let initialProgress: Double
    let onLocationChange: (EPUBReadingLocation) -> Void
    let reader: any EPUBReader

    @State private var phase: LoadPhase = .idle
    @State private var reloadID = UUID()

    var body: some View {
        Group {
            switch phase {
            case .idle, .loading:
                ReaderLoadingView(message: "正在打开 EPUB…")

            case .ready:
                reader.makeReaderView(
                    settings: $settings,
                    onLocationChange: onLocationChange
                )

            case .failed(let message):
                ReaderErrorView(
                    title: "EPUB 阅读器未就绪",
                    message: message,
                    retry: { reloadID = UUID() }
                )
            }
        }
        .task(id: LoadID(documentID: document.id, reloadID: reloadID)) {
            await prepare()
        }
    }

    @MainActor
    private func prepare() async {
        phase = .loading
        do {
            try await reader.prepare(
                document: document,
                initialLocation: initialLocation,
                initialProgress: initialProgress,
                settings: settings
            )
            try Task.checkCancellation()
            phase = .ready
        } catch is CancellationError {
            return
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}

private extension EPUBReaderHostView {
    enum LoadPhase {
        case idle
        case loading
        case ready
        case failed(String)
    }

    struct LoadID: Hashable {
        let documentID: UUID
        let reloadID: UUID
    }
}
