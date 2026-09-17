import Foundation

/// Serves a book's extracted text from disk after the first extraction.
struct CachingPDFTextExtractor: PDFTextExtracting {
    static let cacheKey = ReaderContentCache.Key(
        kind: "pdf-reflow",
        version: PDFTextExtractor.extractionVersion
    )

    private let base: any PDFTextExtracting
    private let cache: ReaderContentCache

    init(
        base: any PDFTextExtracting = PDFTextExtractor(),
        cache: ReaderContentCache = ReaderContentCache()
    ) {
        self.base = base
        self.cache = cache
    }

    func extract(document: ReaderDocument) async throws -> PDFReflowContent {
        if let cached = await cache.load(PDFReflowContent.self, key: Self.cacheKey, for: document) {
            return cached
        }
        let content = try await base.extract(document: document)
        try Task.checkCancellation()
        await cache.store(content, key: Self.cacheKey, for: document)
        return content
    }
}
