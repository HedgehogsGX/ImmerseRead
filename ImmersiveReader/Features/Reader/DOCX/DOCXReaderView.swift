import SwiftUI

struct DOCXReaderView: View {
    let document: ReaderDocument
    let settings: ReaderDisplaySettings
    let initialLocation: TextReadingLocation?
    let initialProgress: Double
    let onLocationChange: (TextReadingLocation) -> Void
    let navigationModel: ReaderNavigationModel?

    private let loader: any ReaderTextLoading

    init(
        document: ReaderDocument,
        settings: ReaderDisplaySettings,
        initialLocation: TextReadingLocation? = nil,
        initialProgress: Double = 0,
        onLocationChange: @escaping (TextReadingLocation) -> Void = { _ in },
        navigationModel: ReaderNavigationModel? = nil,
        loader: any ReaderTextLoading = DOCXReaderTextLoader()
    ) {
        self.document = document
        self.settings = settings
        self.initialLocation = initialLocation
        self.initialProgress = initialProgress.clampedToUnitInterval
        self.onLocationChange = onLocationChange
        self.navigationModel = navigationModel
        self.loader = loader
    }

    var body: some View {
        TextReaderView(
            document: document,
            settings: settings,
            initialLocation: initialLocation,
            initialProgress: initialProgress,
            onLocationChange: onLocationChange,
            navigationModel: navigationModel,
            loader: loader
        )
    }
}

/// Converts a DOCX once, then serves the resulting blocks from disk.
struct DOCXReaderTextLoader: ReaderTextLoading {
    static let cacheKey = ReaderContentCache.Key(
        kind: "docx-text",
        version: MammothDOCXConverter.conversionVersion
    )

    private let cache: ReaderContentCache

    init(cache: ReaderContentCache = ReaderContentCache()) {
        self.cache = cache
    }

    func load(document: ReaderDocument) async throws -> ReaderTextContent {
        if let cached = await cache.load(ReaderTextContent.self, key: Self.cacheKey, for: document) {
            return cached
        }
        let converter = await MammothDOCXConverter()
        let content = try await converter.convert(document: document).readerContent
        try Task.checkCancellation()
        await cache.store(content, key: Self.cacheKey, for: document)
        return content
    }
}
