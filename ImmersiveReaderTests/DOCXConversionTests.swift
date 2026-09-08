import Foundation
import ReadiumZIPFoundation
import Testing
@testable import ImmersiveReader

struct DOCXConversionTests {
    @Test
    func sanitizerKeepsSemanticStructureAndRemovesActiveContent() throws {
        let source = """
        <script>alert('unsafe')</script>
        <h2 onclick="alert(1)">章节标题</h2>
        <p class="body">正文 <strong style="color: red">重点</strong>
          <a href="javascript:alert(1)">链接文字</a>
          <img src="https://example.com/tracker.png" onerror="alert(1)">
        </p>
        <ol start="4">
          <li>第一项<ul><li>嵌套项</li></ul></li>
          <li>第二项</li>
        </ol>
        <table style="position: fixed"><tr><th>A</th><td>B</td></tr></table>
        <iframe src="https://example.com"></iframe>
        """

        let output = try DOCXHTMLSanitizer.sanitize(
            source,
            maximumUTF8Bytes: 64 * 1_024
        )

        #expect(!output.html.contains("script"))
        #expect(!output.html.contains("iframe"))
        #expect(!output.html.contains("img"))
        #expect(!output.html.contains("href"))
        #expect(!output.html.contains("style="))
        #expect(!output.html.contains("onclick"))
        #expect(output.blocks == [
            .heading(level: 2, text: "章节标题"),
            .paragraph("正文 重点 链接文字"),
            .orderedListItem(depth: 0, ordinal: 1, text: "第一项"),
            .unorderedListItem(depth: 1, text: "嵌套项"),
            .orderedListItem(depth: 0, ordinal: 2, text: "第二项"),
            .paragraph("A\tB"),
        ])
        #expect(output.plainText.contains("1. 第一项"))
        #expect(output.plainText.contains("  • 嵌套项"))
    }

    @Test
    func sanitizerRejectsOversizedConvertedHTML() {
        do {
            _ = try DOCXHTMLSanitizer.sanitize(
                "<p>12345</p>",
                maximumUTF8Bytes: 4
            )
            Issue.record("Expected the converted HTML size limit to be enforced")
        } catch let error as DOCXConversionError {
            #expect(error == .convertedContentTooLarge(maximumBytes: 4))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test @MainActor
    func converterRejectsOversizedDOCXBeforeStartingJavaScript() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DOCXConversionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let fileURL = temporaryDirectory.appendingPathComponent("large.docx")
        try Data(repeating: 0x50, count: 5).write(to: fileURL)
        let document = ReaderDocument(
            id: UUID(),
            title: "Large",
            fileURL: fileURL,
            format: .docx
        )
        let converter = MammothDOCXConverter(maximumFileSize: 4)

        do {
            _ = try await converter.convert(document: document)
            Issue.record("Expected the DOCX size limit to be enforced")
        } catch let error as DOCXConversionError {
            #expect(error == .fileTooLarge(maximumBytes: 4))
        }
    }

    @Test @MainActor
    func convertsAMinimalDOCXWithTheBundledOfflineRuntime() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DOCXConversionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let fileURL = temporaryDirectory.appendingPathComponent("minimal.docx")
        try await makeMinimalDOCX(at: fileURL)
        let document = ReaderDocument(
            id: UUID(),
            title: "Minimal",
            fileURL: fileURL,
            format: .docx
        )

        let result = try await MammothDOCXConverter().convert(document: document)

        #expect(result.readerContent.blocks == [
            .paragraph("第一章"),
            .paragraph("这是设备端转换的正文。"),
        ])
        #expect(result.plainText.contains("第一章"))
        #expect(!result.sanitizedHTML.contains("script"))
    }

    private func makeMinimalDOCX(at fileURL: URL) async throws {
        let archive = try await Archive(url: fileURL, accessMode: .create)
        let entries: [(String, Data)] = [
            (
                "[Content_Types].xml",
                Data(
                    """
                    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
                      <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
                      <Default Extension="xml" ContentType="application/xml"/>
                      <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
                    </Types>
                    """.utf8
                )
            ),
            (
                "_rels/.rels",
                Data(
                    """
                    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
                      <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
                    </Relationships>
                    """.utf8
                )
            ),
            (
                "word/document.xml",
                Data(
                    """
                    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                    <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
                      <w:body>
                        <w:p><w:r><w:t>第一章</w:t></w:r></w:p>
                        <w:p><w:r><w:t>这是设备端转换的正文。</w:t></w:r></w:p>
                        <w:sectPr/>
                      </w:body>
                    </w:document>
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
