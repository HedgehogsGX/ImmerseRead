import SwiftUI
import ReadiumZIPFoundation
import Testing
@testable import ImmersiveReader

struct EPUBNavigationTests {
    @Test @MainActor
    func legacyReaderDoublesKeepDefaultNavigationBehavior() async throws {
        let reader = LegacyReaderDouble()
        #expect(await reader.navigationSections().isEmpty)
        #expect(try await reader.search(query: "query").isEmpty)
        #expect(await reader.go(to: EPUBReadingLocation(locatorJSON: "{}", progress: 0)) == false)
    }

    @Test
    func epubLocationClampsProgressAndPreservesLocator() throws {
        let location = EPUBReadingLocation(
            locatorJSON: #"{"href":"chapter.xhtml","type":"application/xhtml+xml"}"#,
            progress: 1.5
        )
        let restored = try #require(EPUBReadingLocation.restore(from: location.encoded()))
        #expect(restored.locatorJSON.contains("chapter.xhtml"))
        #expect(restored.progress == 1)
    }

    @Test @MainActor
    func readiumNavigationExposesNestedContentsAndSearchLocations() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EPUBNavigationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("navigation.epub")
        try await makeEPUB(at: fileURL)

        let reader = ReadiumEPUBReader()
        try await reader.prepare(
            document: ReaderDocument(id: UUID(), title: "导航", fileURL: fileURL, format: .epub),
            initialLocation: nil,
            initialProgress: 0,
            settings: .default
        )
        let sections = await reader.navigationSections()
        #expect(sections.map(\.title) == ["第一章", "第一节"])
        #expect(sections.map(\.level) == [1, 2])
        let results = try await reader.search(query: "needle")
        #expect(results.count == 1)
        #expect(results.first?.snippet.contains("needle") == true)
        if let result = results.first {
            if case .epub = result.location {
            } else {
                Issue.record("EPUB search result did not carry an EPUB location")
            }
        } else {
            Issue.record("EPUB search result did not carry an EPUB location")
        }
    }

    private func makeEPUB(at fileURL: URL) async throws {
        let archive = try await Archive(url: fileURL, accessMode: .create)
        let entries: [(String, Data)] = [
            ("mimetype", Data("application/epub+zip".utf8)),
            ("META-INF/container.xml", Data("""
                <?xml version="1.0" encoding="UTF-8"?>
                <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
                  <rootfiles><rootfile full-path="EPUB/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
                </container>
                """.utf8)),
            ("EPUB/content.opf", Data("""
                <?xml version="1.0" encoding="UTF-8"?>
                <package version="3.0" unique-identifier="book-id" xmlns="http://www.idpf.org/2007/opf">
                  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="book-id">urn:uuid:navigation</dc:identifier><dc:title>导航</dc:title><dc:language>zh-CN</dc:language><meta property="dcterms:modified">2026-09-01T00:00:00Z</meta></metadata>
                  <manifest><item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/></manifest>
                  <spine><itemref idref="chapter"/></spine>
                </package>
                """.utf8)),
            ("EPUB/chapter.xhtml", Data("""
                <html xmlns="http://www.w3.org/1999/xhtml"><head><title>第一章</title></head><body><h1>第一章</h1><h2 id="section">第一节</h2><p>needle 在这一节。</p></body></html>
                """.utf8)),
            ("EPUB/nav.xhtml", Data("""
                <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><body><nav epub:type="toc"><ol><li><a href="chapter.xhtml">第一章</a><ol><li><a href="chapter.xhtml#section">第一节</a></li></ol></li></ol></nav></body></html>
                """.utf8))
        ]
        for (path, data) in entries {
            try await archive.addEntry(
                with: path,
                type: .file,
                uncompressedSize: Int64(data.count),
                provider: { position, requestedSize in
                    let start = Int(position)
                    guard start < data.count else { return Data() }
                    return data.subdata(in: start ..< min(start + requestedSize, data.count))
                }
            )
        }
    }
}

@MainActor
private final class LegacyReaderDouble: EPUBReader {
    func prepare(
        document: ReaderDocument,
        initialLocation: EPUBReadingLocation?,
        initialProgress: Double,
        settings: ReaderDisplaySettings
    ) async throws {}

    func makeReaderView(
        settings: Binding<ReaderDisplaySettings>,
        onLocationChange: @escaping (EPUBReadingLocation) -> Void
    ) -> AnyView {
        AnyView(EmptyView())
    }
}
