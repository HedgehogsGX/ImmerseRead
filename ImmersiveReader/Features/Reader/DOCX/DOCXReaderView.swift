import SwiftUI

struct DOCXReaderView: View {
    let document: ReaderDocument
    let settings: ReaderDisplaySettings
    let initialLocation: TextReadingLocation?
    let initialProgress: Double
    let onLocationChange: (TextReadingLocation) -> Void

    private let loader: any ReaderTextLoading

    init(
        document: ReaderDocument,
        settings: ReaderDisplaySettings,
        initialLocation: TextReadingLocation? = nil,
        initialProgress: Double = 0,
        onLocationChange: @escaping (TextReadingLocation) -> Void = { _ in },
        loader: any ReaderTextLoading = DOCXReaderTextLoader()
    ) {
        self.document = document
        self.settings = settings
        self.initialLocation = initialLocation
        self.initialProgress = initialProgress.clampedToUnitInterval
        self.onLocationChange = onLocationChange
        self.loader = loader
    }

    var body: some View {
        TextReaderView(
            document: document,
            settings: settings,
            initialLocation: initialLocation,
            initialProgress: initialProgress,
            onLocationChange: onLocationChange,
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
