import Foundation
import PDFKit

enum PDFNavigationSupport {
    @MainActor
    static func sections(for document: PDFDocument) -> [ReaderNavigationSection] {
        if let root = document.outlineRoot {
            var sections: [ReaderNavigationSection] = []
            append(childrenOf: root, level: 1, path: [], document: document, into: &sections)
            if !sections.isEmpty {
                return sections
            }
        }

        return (0 ..< document.pageCount).map { pageIndex in
            ReaderNavigationSection(
                id: "page-\(pageIndex)",
                title: String(localized: "第 \(pageIndex + 1) 页"),
                level: 1,
                location: .pdfPage(pageIndex)
            )
        }
    }

    @MainActor
    static func search(
        query: String,
        in document: PDFDocument
    ) async throws -> [ReaderSearchResult] {
        try results(query: query, in: document)
    }

    static func search(query: String, fileURL: URL) async throws -> [ReaderSearchResult] {
        let task = Task.detached(priority: .userInitiated) {
            guard let document = PDFDocument(url: fileURL), !document.isLocked else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return try results(query: query, in: document)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private static func results(query: String, in document: PDFDocument) throws -> [ReaderSearchResult] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }

        var results: [ReaderSearchResult] = []
        for pageIndex in 0 ..< document.pageCount {
            try Task.checkCancellation()
            guard let text = document.page(at: pageIndex)?.string else { continue }
            var searchStart = text.startIndex
            while searchStart < text.endIndex,
                  let match = text.range(
                      of: query,
                      options: [.caseInsensitive, .diacriticInsensitive],
                      range: searchStart ..< text.endIndex
                  ) {
                let prefixLength = text.distance(from: text.startIndex, to: match.lowerBound)
                let suffixLength = text.distance(from: match.upperBound, to: text.endIndex)
                let startIndex = text.index(match.lowerBound, offsetBy: -min(48, prefixLength))
                let endIndex = text.index(match.upperBound, offsetBy: min(96, suffixLength))
                results.append(ReaderSearchResult(
                    id: "pdf-search-\(pageIndex)-\(results.count)",
                    title: String(localized: "第 \(pageIndex + 1) 页"),
                    snippet: String(text[startIndex ..< endIndex]),
                    location: .pdfPage(pageIndex)
                ))
                if results.count == 200 { return results }
                if match.upperBound == text.endIndex { break }
                searchStart = match.upperBound
                try Task.checkCancellation()
            }
        }
        return results
    }

    private static func append(
        childrenOf outline: PDFOutline,
        level: Int,
        path: [Int],
        document: PDFDocument,
        into sections: inout [ReaderNavigationSection]
    ) {
        for index in 0 ..< outline.numberOfChildren {
            guard let child = outline.child(at: index) else { continue }
            let childPath = path + [index]
            let pageIndex = pageIndex(for: child, document: document)
            if let pageIndex {
                sections.append(ReaderNavigationSection(
                    id: "outline-\(childPath.map(String.init).joined(separator: "-"))",
                    title: child.label ?? String(localized: "第 \(pageIndex + 1) 页"),
                    level: level,
                    location: .pdfPage(pageIndex)
                ))
            }
            append(
                childrenOf: child,
                level: level + 1,
                path: childPath,
                document: document,
                into: &sections
            )
        }
    }

    private static func pageIndex(for outline: PDFOutline, document: PDFDocument) -> Int? {
        if let page = outline.destination?.page {
            let pageIndex = document.index(for: page)
            if pageIndex != NSNotFound { return pageIndex }
        }
        for index in 0 ..< outline.numberOfChildren {
            guard let child = outline.child(at: index),
                  let pageIndex = pageIndex(for: child, document: document) else { continue }
            return pageIndex
        }
        return nil
    }
}
