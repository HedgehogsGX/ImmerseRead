import Foundation
import Combine

enum ReaderNavigationLocation: Codable, Equatable, Sendable {
    case text(TextReadingLocation)
    case pdf(PDFReadingLocation)
    case pdfPage(Int)
    case epub(EPUBReadingLocation)
}

struct ReaderNavigationSection: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let title: String
    let level: Int
    let location: ReaderNavigationLocation

    init(id: String, title: String, level: Int, location: ReaderNavigationLocation) {
        self.id = id
        self.title = title
        self.level = max(1, level)
        self.location = location
    }
}

struct ReaderSearchResult: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let snippet: String
    let location: ReaderNavigationLocation
}

struct ReaderNavigationJump: Identifiable, Equatable, Sendable {
    let id: UUID
    let location: ReaderNavigationLocation

    init(location: ReaderNavigationLocation) {
        id = UUID()
        self.location = location
    }
}

struct ReaderBookmark: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let documentID: UUID
    let title: String
    let location: ReaderNavigationLocation
    let createdAt: Date

    init(
        id: UUID = UUID(),
        documentID: UUID,
        title: String,
        location: ReaderNavigationLocation,
        createdAt: Date = .now
    ) {
        self.id = id
        self.documentID = documentID
        self.title = title
        self.location = location
        self.createdAt = createdAt
    }
}

@MainActor
final class ReaderNavigationModel: ObservableObject {
    let documentID: UUID
    let format: BookFormat

    @Published private(set) var sections: [ReaderNavigationSection] = []
    @Published private(set) var searchResults: [ReaderSearchResult] = []
    @Published private(set) var bookmarks: [ReaderBookmark]
    @Published private(set) var currentLocation: ReaderNavigationLocation?
    @Published private(set) var jumpRequest: ReaderNavigationJump?
    @Published var searchQuery = ""
    @Published private(set) var isSearching = false
    @Published private(set) var searchError: String?
    @Published var bookmarkError: String?

    private let bookmarkStore: ReaderBookmarkStore
    private var searchProvider: (@MainActor (String) async throws -> [ReaderSearchResult])?
    private var searchTask: Task<Void, Never>?

    init(document: ReaderDocument, bookmarkStore: ReaderBookmarkStore = .default) {
        documentID = document.id
        format = document.format
        self.bookmarkStore = bookmarkStore
        bookmarks = bookmarkStore.load(documentID: document.id)
    }

    func update(content: ReaderTextContent) {
        let segmentation = ReaderTextSegmentation(blocks: content.blocks)
        let textSections = content.blocks.enumerated().compactMap { index, block -> ReaderNavigationSection? in
            guard case .heading(let level, _) = block else { return nil }
            return ReaderNavigationSection(
                id: "block-\(index)",
                title: ReaderTextSearch.text(for: block, format: content.format),
                level: level,
                location: .text(TextReadingLocation(
                    anchor: ReaderTextAnchor(blockIndex: index, offsetInBlock: 0),
                    progress: segmentation.progress(
                        for: ReaderTextAnchor(blockIndex: index, offsetInBlock: 0)
                    )
                ))
            )
        }
        if content.format != .pdf { sections = textSections }
        setSearchProvider { query in
            let task = Task.detached(priority: .userInitiated) {
                try ReaderTextSearch.results(for: query, content: content, segmentation: segmentation)
            }
            return try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        }
    }

    func update(sections: [ReaderNavigationSection]) {
        guard self.sections != sections else { return }
        self.sections = sections
    }

    func report(location: ReaderNavigationLocation) {
        currentLocation = location
    }

    /// Publishes the position a document opens at, so bookmarking is available
    /// immediately instead of only after the reader reports a move. A reader
    /// that has already reported keeps its own position.
    func seedLocation(_ location: ReaderNavigationLocation?) {
        guard currentLocation == nil, let location else {
            return
        }
        currentLocation = location
    }

    func requestJump(to location: ReaderNavigationLocation) {
        jumpRequest = ReaderNavigationJump(location: location)
    }

    func clearJumpRequest(_ request: ReaderNavigationJump) {
        guard jumpRequest?.id == request.id else { return }
        jumpRequest = nil
    }

    func search(_ query: String) {
        searchQuery = query
        performSearch()
    }

    func setSearchProvider(_ provider: @escaping @MainActor (String) async throws -> [ReaderSearchResult]) {
        searchProvider = provider
        performSearch()
    }

    @discardableResult
    func toggleBookmark(title: String? = nil) -> ReaderBookmark? {
        guard let currentLocation else { return nil }
        if let bookmark = bookmarks.first(where: { $0.location.matchesPosition(currentLocation) }) {
            removeBookmark(bookmark)
            return nil
        }
        let bookmark = ReaderBookmark(
            documentID: documentID,
            title: title ?? String(localized: "阅读位置 \(bookmarks.count + 1)"),
            location: currentLocation
        )
        return saveBookmarks(bookmarks + [bookmark]) ? bookmark : nil
    }

    func removeBookmark(_ bookmark: ReaderBookmark) {
        saveBookmarks(bookmarks.filter { $0.id != bookmark.id })
    }

    func isBookmarked(_ location: ReaderNavigationLocation? = nil) -> Bool {
        guard let location = location ?? currentLocation else { return false }
        return bookmarks.contains { $0.location.matchesPosition(location) }
    }

    @discardableResult
    private func saveBookmarks(_ updated: [ReaderBookmark]) -> Bool {
        do {
            try bookmarkStore.save(updated, documentID: documentID)
            bookmarks = updated
            bookmarkError = nil
            return true
        } catch {
            bookmarkError = error.localizedDescription
            return false
        }
    }

    private func performSearch() {
        searchTask?.cancel()
        searchResults = []
        searchError = nil
        isSearching = false
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, let searchProvider else { return }
        isSearching = true
        searchTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(200))
                let results = try await searchProvider(query)
                try Task.checkCancellation()
                self?.searchResults = Array(results.prefix(200))
                self?.isSearching = false
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self?.searchError = error.localizedDescription
                self?.isSearching = false
            }
        }
    }
}

private extension ReaderNavigationLocation {
    func matchesPosition(_ other: Self) -> Bool {
        switch (self, other) {
        case (.text(let lhs), .text(let rhs)):
            lhs.anchor == rhs.anchor && lhs.semanticVersion == rhs.semanticVersion
        case (.pdf(let lhs), .pdf(let rhs)):
            lhs.mode == rhs.mode && (lhs.mode == .reflow
                ? lhs.reflowAnchor == rhs.reflowAnchor && lhs.reflowProgress == rhs.reflowProgress
                : lhs.originalProgress == rhs.originalProgress)
        default:
            self == other
        }
    }
}

enum ReaderTextSearch {
    static func results(
        for query: String,
        content: ReaderTextContent,
        segmentation: ReaderTextSegmentation
    ) throws -> [ReaderSearchResult] {
        guard !query.isEmpty else { return [] }
        var results: [ReaderSearchResult] = []
        var sectionTitle = String(localized: "正文")
        for (index, block) in content.blocks.enumerated() {
            try Task.checkCancellation()
            let text = text(for: block, format: content.format)
            if case .heading = block { sectionTitle = text }
            var searchStart = text.startIndex
            while searchStart < text.endIndex,
                  let match = text.range(
                      of: query,
                      options: [.caseInsensitive, .diacriticInsensitive],
                      range: searchStart ..< text.endIndex
                  ) {
                let utf16Index = match.lowerBound.samePosition(in: text.utf16) ?? text.utf16.startIndex
                let matchOffset = text.utf16.distance(from: text.utf16.startIndex, to: utf16Index)
                let prefixLength = text.distance(from: text.startIndex, to: match.lowerBound)
                let suffixLength = text.distance(from: match.upperBound, to: text.endIndex)
                let startIndex = text.index(match.lowerBound, offsetBy: -min(36, prefixLength))
                let endIndex = text.index(match.upperBound, offsetBy: min(72, suffixLength))
                let snippet = String(text[startIndex ..< endIndex])
                let anchor = ReaderTextAnchor(blockIndex: index, offsetInBlock: matchOffset)
                let location = TextReadingLocation(
                    anchor: anchor,
                    progress: segmentation.progress(for: anchor)
                )
                results.append(ReaderSearchResult(
                    id: "search-\(index)-\(matchOffset)",
                    title: sectionTitle,
                    snippet: snippet,
                    location: .text(location)
                ))
                if results.count == 200 { break }
                if match.upperBound == text.endIndex { break }
                searchStart = match.upperBound
            }
            if results.count == 200 { break }
        }
        return results
    }

    static func text(for block: ReaderSemanticBlock, format: BookFormat) -> String {
        let prefix: String
        let supportsMarkdown: Bool
        switch block {
        case .unorderedListItem: (prefix, supportsMarkdown) = ("•\t", true)
        case .orderedListItem(_, let ordinal, _): (prefix, supportsMarkdown) = ("\(ordinal).\t", true)
        case .blockQuote: (prefix, supportsMarkdown) = ("│  ", true)
        case .heading, .paragraph: (prefix, supportsMarkdown) = ("", true)
        default: (prefix, supportsMarkdown) = ("", false)
        }
        if format == .markdown, supportsMarkdown,
           let parsed = try? AttributedString(markdown: block.text, options: .init(
               interpretedSyntax: .inlineOnlyPreservingWhitespace,
               failurePolicy: .returnPartiallyParsedIfPossible
           )) {
            return prefix + String(parsed.characters)
        }
        return prefix + block.text
    }
}
