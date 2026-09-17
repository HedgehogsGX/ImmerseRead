import Foundation
import ReadiumZIPFoundation
import Testing
@testable import ImmerseRead

struct EPUBReaderTests {
    @Test @MainActor
    func readiumOpensAMinimalLocalEPUB() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("EPUBReaderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let fileURL = directoryURL.appendingPathComponent("minimal.epub")
        try await makeMinimalEPUB(at: fileURL)
        let document = ReaderDocument(
            id: UUID(),
            title: "最小 EPUB",
            fileURL: fileURL,
            format: .epub
        )
        let reader = ReadiumEPUBReader()

        try await reader.prepare(
            document: document,
            initialLocation: nil,
            initialProgress: 0.5,
            settings: .default
        )

        _ = reader.makeReaderView(
            settings: .constant(.default),
            onLocationChange: { _ in }
        )
    }

    @Test @MainActor
    func reopeningUsesTheSavedLocatorAndFallsBackForMalformedOnes() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("EPUBReaderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let fileURL = directoryURL.appendingPathComponent("minimal.epub")
        try await makeMinimalEPUB(at: fileURL)
        let document = ReaderDocument(
            id: UUID(),
            title: "最小 EPUB",
            fileURL: fileURL,
            format: .epub
        )
        let reader = ReadiumEPUBReader()

        let savedLocator = #"{"href":"chapter.xhtml","type":"application/xhtml+xml","locations":{"progression":0.75,"totalProgression":0.75}}"#
        try await reader.prepare(
            document: document,
            initialLocation: EPUBReadingLocation(locatorJSON: savedLocator, progress: 0.75),
            initialProgress: 0,
            settings: .default
        )
        let restored = try #require(reader.currentLocationJSON)
        #expect(restored.contains(#""progression":0.75"#))
        #expect(restored.contains("chapter.xhtml"))

        try await reader.prepare(
            document: document,
            initialLocation: EPUBReadingLocation(locatorJSON: "not a locator", progress: 0.5),
            initialProgress: 0.5,
            settings: .default
        )
        let fallback = try #require(reader.currentLocationJSON)
        #expect(fallback.contains(#""totalProgression":0.5"#))
    }

    private func makeMinimalEPUB(at fileURL: URL) async throws {
        let archive = try await Archive(url: fileURL, accessMode: .create)
        let entries: [(String, Data)] = [
            ("mimetype", Data("application/epub+zip".utf8)),
            (
                "META-INF/container.xml",
                Data(
                    """
                    <?xml version="1.0" encoding="UTF-8"?>
                    <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
                      <rootfiles>
                        <rootfile full-path="EPUB/content.opf" media-type="application/oebps-package+xml"/>
                      </rootfiles>
                    </container>
                    """.utf8
                )
            ),
            (
                "EPUB/content.opf",
                Data(
                    """
                    <?xml version="1.0" encoding="UTF-8"?>
                    <package version="3.0" unique-identifier="book-id"
                             xmlns="http://www.idpf.org/2007/opf">
                      <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                        <dc:identifier id="book-id">urn:uuid:00000000-0000-0000-0000-000000000001</dc:identifier>
                        <dc:title>最小 EPUB</dc:title>
                        <dc:language>zh-CN</dc:language>
                        <meta property="dcterms:modified">2026-08-30T00:00:00Z</meta>
                      </metadata>
                      <manifest>
                        <item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/>
                        <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
                      </manifest>
                      <spine>
                        <itemref idref="chapter"/>
                      </spine>
                    </package>
                    """.utf8
                )
            ),
            (
                "EPUB/chapter.xhtml",
                Data(
                    """
                    <?xml version="1.0" encoding="UTF-8"?>
                    <html xmlns="http://www.w3.org/1999/xhtml">
                      <head><title>第一章</title></head>
                      <body><h1>第一章</h1><p>这是 EPUB 正文。</p></body>
                    </html>
                    """.utf8
                )
            ),
            (
                "EPUB/nav.xhtml",
                Data(
                    """
                    <?xml version="1.0" encoding="UTF-8"?>
                    <html xmlns="http://www.w3.org/1999/xhtml"
                          xmlns:epub="http://www.idpf.org/2007/ops">
                      <head><title>目录</title></head>
                      <body>
                        <nav epub:type="toc"><ol><li><a href="chapter.xhtml">第一章</a></li></ol></nav>
                      </body>
                    </html>
                    """.utf8
                )
            ),
        ]

        for (path, data) in entries {
            try await archive.addEntry(
                with: path,
                type: .file,
                uncompressedSize: Int64(data.count),
                provider: { position, requestedSize in
                    let startIndex = Int(position)
                    guard startIndex < data.count else {
                        return Data()
                    }
                    let endIndex = min(startIndex + requestedSize, data.count)
                    return data.subdata(in: startIndex ..< endIndex)
                }
            )
        }
    }
}
