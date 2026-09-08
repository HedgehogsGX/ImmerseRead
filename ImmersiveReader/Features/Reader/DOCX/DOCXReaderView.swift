import SwiftUI

struct DOCXReaderView: View {
    let document: ReaderDocument
    let settings: ReaderDisplaySettings
    let initialProgress: Double
    let onProgressChange: (Double) -> Void

    private let loader: any ReaderTextLoading

    init(
        document: ReaderDocument,
        settings: ReaderDisplaySettings,
        initialProgress: Double = 0,
        onProgressChange: @escaping (Double) -> Void = { _ in },
        loader: any ReaderTextLoading = DOCXReaderTextLoader()
    ) {
        self.document = document
        self.settings = settings
        self.initialProgress = initialProgress.clampedToUnitInterval
        self.onProgressChange = onProgressChange
        self.loader = loader
    }

    var body: some View {
        TextReaderView(
            document: document,
            settings: settings,
            initialProgress: initialProgress,
            onProgressChange: onProgressChange,
            loader: loader
        )
    }
}

struct DOCXReaderTextLoader: ReaderTextLoading {
    func load(document: ReaderDocument) async throws -> ReaderTextContent {
        let converter = await MammothDOCXConverter()
        return try await converter.convert(document: document).readerContent
    }
}
