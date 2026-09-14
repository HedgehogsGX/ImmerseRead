import Combine
import SwiftUI

struct EPUBReaderHostView: View {
    let document: ReaderDocument
    @Binding var settings: ReaderDisplaySettings
    let initialLocation: EPUBReadingLocation?
    let initialProgress: Double
    let onLocationChange: (EPUBReadingLocation) -> Void
    let navigationModel: ReaderNavigationModel?
    let reader: any EPUBReader

    @State private var phase: LoadPhase = .idle
    @State private var reloadID = UUID()
    @State private var observedJumpRequestID: UUID?

    var body: some View {
        Group {
            switch phase {
            case .idle, .loading:
                ReaderLoadingView(message: String(localized: "正在打开 EPUB…"))

            case .ready:
                reader.makeReaderView(
                    settings: $settings,
                    onLocationChange: report
                )

            case .failed(let message):
                ReaderErrorView(
                    title: String(localized: "EPUB 阅读器未就绪"),
                    message: message,
                    retry: { reloadID = UUID() }
                )
            }
        }
        .task(id: LoadID(documentID: document.id, reloadID: reloadID)) {
            await prepare()
        }
        .task(id: NavigationTaskID(requestID: observedJumpRequestID ?? navigationModel?.jumpRequest?.id, isReady: phase.isReady)) {
            await applyNavigationJump()
        }
        .onReceive(navigationModel?.$jumpRequest.eraseToAnyPublisher() ?? Empty().eraseToAnyPublisher()) { request in
            observedJumpRequestID = request?.id
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
            if let navigationModel {
                navigationModel.update(sections: await reader.navigationSections())
                navigationModel.setSearchProvider { query in
                    try await reader.search(query: query)
                }
            }
        } catch is CancellationError {
            return
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func report(_ location: EPUBReadingLocation) {
        navigationModel?.report(location: .epub(location))
        onLocationChange(location)
    }

    @MainActor
    private func applyNavigationJump() async {
        guard let navigationModel,
              let request = navigationModel.jumpRequest else { return }
        guard phase.isReady else { return }
        guard case .epub(let location) = request.location else { return }
        if await reader.go(to: location) {
            navigationModel.clearJumpRequest(request)
        }
    }
}

private extension EPUBReaderHostView {
    enum LoadPhase {
        case idle
        case loading
        case ready
        case failed(String)

        var isReady: Bool {
            if case .ready = self { return true }
            return false
        }
    }

    struct LoadID: Hashable {
        let documentID: UUID
        let reloadID: UUID
    }

    struct NavigationTaskID: Hashable {
        let requestID: UUID?
        let isReady: Bool
    }
}
