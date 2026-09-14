import Foundation
import Testing
@testable import ImmersiveReader

struct ReaderNavigationTests {
    @Test @MainActor
    func textContentBuildsSectionsAndSearchResults() async throws {
        let document = ReaderDocument(
            id: UUID(),
            title: "导航测试",
            fileURL: URL(fileURLWithPath: "/tmp/navigation.txt"),
            format: .plainText
        )
        let model = ReaderNavigationModel(
            document: document,
            bookmarkStore: ReaderBookmarkStore(directory: temporaryDirectory())
        )
        model.update(content: ReaderTextContent(format: .plainText, blocks: [
            .heading(level: 2, text: "第一章"),
            .paragraph("这是一段可搜索的正文。"),
            .paragraph("正文再次出现。")
        ]))
        #expect(model.sections.map(\.title) == ["第一章"])

        model.search("正文")
        try await waitForSearch(model)
        #expect(model.searchResults.count == 2)
        #expect(model.searchResults.allSatisfy { $0.location.isText })
    }

    @Test @MainActor
    func newerQueriesCancelStaleResultsAndSurfaceFailures() async throws {
        let model = ReaderNavigationModel(
            document: ReaderDocument(id: UUID(), title: "Search", fileURL: URL(fileURLWithPath: "/tmp/search.txt"), format: .plainText),
            bookmarkStore: ReaderBookmarkStore(directory: temporaryDirectory())
        )
        model.setSearchProvider { query in
            if query == "failure" { throw CocoaError(.fileReadCorruptFile) }
            try await Task.sleep(for: .milliseconds(query == "old" ? 600 : 1))
            return [ReaderSearchResult(id: query, title: query, snippet: query, location: .pdfPage(0))]
        }
        model.search("old")
        try await Task.sleep(for: .milliseconds(250))
        model.search("new")
        try await waitForSearch(model)
        #expect(model.searchResults.map(\.id) == ["new"])
        model.search("failure")
        try await waitForSearch(model)
        #expect(model.searchError != nil)
        #expect(model.searchResults.isEmpty)
        model.search(" ")
        #expect(!model.isSearching)
        #expect(model.searchError == nil)
    }

    @Test
    func textSearchUsesUTF16AnchorsAndBoundsResults() throws {
        let content = ReaderTextContent(format: .plainText, blocks: [
            .heading(level: 1, text: "Chapter"),
            .paragraph("😀Café " + String(repeating: "cafe ", count: 300))
        ])
        let results = try ReaderTextSearch.results(for: "cafe", content: content, segmentation: ReaderTextSegmentation(blocks: content.blocks))
        #expect(results.count == 200)
        #expect(results.first?.title == "Chapter")
        guard case .text(let location) = try #require(results.first).location else {
            Issue.record("Expected a text search location")
            return
        }
        #expect(location.anchor == .init(blockIndex: 1, offsetInBlock: 2))
    }

    @Test @MainActor
    func markdownSearchAnchorsUseVisibleTextRatherThanMarkupOffsets() throws {
        let content = ReaderTextContent(format: .markdown, blocks: [
            .unorderedListItem(depth: 0, text: "**Bold** and [target](https://example.com)")
        ])
        let results = try ReaderTextSearch.results(for: "target", content: content, segmentation: ReaderTextSegmentation(blocks: content.blocks))
        guard case .text(let location) = try #require(results.first).location else {
            Issue.record("Expected a text location")
            return
        }
        let rendered = ReaderTextRenderer.attributedString(for: content, settings: .default).string as NSString
        #expect(location.anchor.offsetInBlock == rendered.range(of: "target").location)
        #expect(results.first?.snippet == "•\tBold and target")
    }

    @MainActor
    private func waitForSearch(_ model: ReaderNavigationModel) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while model.isSearching, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!model.isSearching)
    }

    @Test @MainActor
    func bookmarksPersistAndToggleByOpaqueLocation() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let documentID = UUID()
        let document = ReaderDocument(
            id: documentID,
            title: "书签测试",
            fileURL: URL(fileURLWithPath: "/tmp/bookmark.txt"),
            format: .plainText
        )
        let store = ReaderBookmarkStore(directory: directory)
        let model = ReaderNavigationModel(document: document, bookmarkStore: store)
        let location = ReaderNavigationLocation.text(TextReadingLocation(
            anchor: ReaderTextAnchor(blockIndex: 3, offsetInBlock: 8),
            progress: 0.4
        ))
        model.report(location: location)
        #expect(model.toggleBookmark(title: "第一处")?.title == "第一处")
        #expect(store.load(documentID: documentID).count == 1)
        #expect(model.isBookmarked())
        model.toggleBookmark()
        #expect(store.load(documentID: documentID).isEmpty)
    }

    @Test @MainActor
    func aFreshlyOpenedDocumentCanBeBookmarkedBeforeItIsScrolled() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let documentID = UUID()
        let document = ReaderDocument(
            id: documentID,
            title: "刚打开",
            fileURL: directory.appendingPathComponent("book.pdf"),
            format: .pdf
        )
        let store = ReaderBookmarkStore(directory: directory)
        let model = ReaderNavigationModel(document: document, bookmarkStore: store)

        // Nothing has moved yet, so the reader has reported no position.
        #expect(model.currentLocation == nil)
        #expect(model.toggleBookmark() == nil)

        model.seedLocation(ReaderContainerView.openingLocation(
            format: .pdf,
            pdfLocation: PDFReadingLocation(),
            textLocation: nil,
            epubLocation: nil
        ))

        #expect(model.currentLocation != nil)
        #expect(model.toggleBookmark(title: "开头")?.title == "开头")
        #expect(store.load(documentID: documentID).count == 1)
    }

    @Test @MainActor
    func seedingNeverOverridesWhereTheReaderSaysItIs() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = ReaderDocument(
            id: UUID(),
            title: "已滚动",
            fileURL: directory.appendingPathComponent("book.txt"),
            format: .plainText
        )
        let model = ReaderNavigationModel(
            document: document,
            bookmarkStore: ReaderBookmarkStore(directory: directory)
        )
        let reported = ReaderNavigationLocation.text(TextReadingLocation(
            anchor: ReaderTextAnchor(blockIndex: 12, offsetInBlock: 4),
            progress: 0.6
        ))

        model.report(location: reported)
        model.seedLocation(.text(TextReadingLocation(
            anchor: ReaderTextAnchor(blockIndex: 0, offsetInBlock: 0),
            progress: 0
        )))

        #expect(model.currentLocation == reported)
    }

    @Test @MainActor
    func openingLocationCoversEveryFormatThatCanRestoreAPosition() {
        let textLocation = TextReadingLocation(
            anchor: ReaderTextAnchor(blockIndex: 5, offsetInBlock: 1),
            progress: 0.3
        )

        #expect(ReaderContainerView.openingLocation(
            format: .pdf,
            pdfLocation: PDFReadingLocation(),
            textLocation: nil,
            epubLocation: nil
        ) == .pdf(PDFReadingLocation()))

        #expect(ReaderContainerView.openingLocation(
            format: .docx,
            pdfLocation: PDFReadingLocation(),
            textLocation: textLocation,
            epubLocation: nil
        ) == .text(textLocation))

        // A document with no saved position opens at its start.
        #expect(ReaderContainerView.openingLocation(
            format: .markdown,
            pdfLocation: PDFReadingLocation(),
            textLocation: nil,
            epubLocation: nil
        ) == .text(TextReadingLocation(
            anchor: ReaderTextAnchor(blockIndex: 0, offsetInBlock: 0),
            progress: 0
        )))

        // EPUB waits for Readium, and legacy DOC has no navigation at all.
        #expect(ReaderContainerView.openingLocation(
            format: .epub,
            pdfLocation: PDFReadingLocation(),
            textLocation: nil,
            epubLocation: nil
        ) == nil)
        #expect(ReaderContainerView.openingLocation(
            format: .legacyWord,
            pdfLocation: PDFReadingLocation(),
            textLocation: nil,
            epubLocation: nil
        ) == nil)
    }

    @Test @MainActor
    func failedBookmarkWritesAreVisibleAndDoNotPretendToPersist() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let blockedDirectory = directory.appendingPathComponent("not-a-directory")
        try Data("file".utf8).write(to: blockedDirectory)
        let document = ReaderDocument(id: UUID(), title: "Failure", fileURL: directory.appendingPathComponent("book.txt"), format: .plainText)
        let model = ReaderNavigationModel(document: document, bookmarkStore: ReaderBookmarkStore(directory: blockedDirectory))
        model.report(location: .text(.init(anchor: .init(blockIndex: 1, offsetInBlock: 2), progress: 0.2)))
        #expect(model.toggleBookmark() == nil)
        #expect(model.bookmarkError != nil)
        #expect(model.bookmarks.isEmpty)
    }

    @Test @MainActor
    func togglingTheSameTextPassageIgnoresChangesToEstimatedProgress() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = ReaderDocument(id: UUID(), title: "Bookmark", fileURL: directory.appendingPathComponent("book.txt"), format: .plainText)
        let model = ReaderNavigationModel(document: document, bookmarkStore: ReaderBookmarkStore(directory: directory))
        let anchor = ReaderTextAnchor(blockIndex: 10, offsetInBlock: 20)
        model.report(location: .text(.init(anchor: anchor, progress: 0.1)))
        model.toggleBookmark()
        model.report(location: .text(.init(anchor: anchor, progress: 0.2)))
        #expect(model.isBookmarked())
        model.toggleBookmark()
        #expect(model.bookmarks.isEmpty)
    }

    @Test
    func navigationLocationsRoundTrip() throws {
        let locations: [ReaderNavigationLocation] = [
            .text(TextReadingLocation(anchor: .init(blockIndex: 1, offsetInBlock: 2), progress: 0.2)),
            .pdfPage(4),
            .epub(EPUBReadingLocation(locatorJSON: "{\"href\":\"chapter.xhtml\"}", progress: 0.7))
        ]
        let data = try JSONEncoder().encode(locations)
        #expect(try JSONDecoder().decode([ReaderNavigationLocation].self, from: data) == locations)
    }

    private func temporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReaderNavigationTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private extension ReaderNavigationLocation {
    var isText: Bool {
        if case .text = self { return true }
        return false
    }
}
