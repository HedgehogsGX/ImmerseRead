import Foundation
import Testing
@testable import ImmerseRead

struct BookFormatDetectorTests {
    private let detector = BookFormatDetector()

    @Test
    func recognizesSupportedExtensionsCaseInsensitively() {
        #expect(BookFormat(fileExtension: "EPUB") == .epub)
        #expect(BookFormat(fileExtension: ".Pdf") == .pdf)
        #expect(BookFormat(fileExtension: "txt") == .plainText)
        #expect(BookFormat(fileExtension: "MD") == .markdown)
        #expect(BookFormat(fileExtension: "markdown") == .markdown)
        #expect(BookFormat(fileExtension: "docx") == .docx)
        #expect(BookFormat(fileExtension: "doc") == .legacyWord)
        #expect(BookFormat(fileExtension: "rtf") == nil)
    }

    @Test
    func validatesBinarySignatures() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let fixtures: [(String, Data, BookFormat)] = [
            ("book.epub", Data([0x50, 0x4B, 0x03, 0x04, 0x00]), .epub),
            ("paper.PDF", Data("%PDF-1.7\n".utf8), .pdf),
            ("notes.docx", Data([0x50, 0x4B, 0x03, 0x04, 0x00]), .docx),
            (
                "legacy.doc",
                Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]),
                .legacyWord
            ),
        ]

        for (filename, data, expectedFormat) in fixtures {
            let fileURL = temporaryDirectory.appendingPathComponent(filename)
            try data.write(to: fileURL, options: .atomic)
            let detection = try detector.detectFormat(at: fileURL)
            #expect(detection.format == expectedFormat)
            #expect(detection.textEncoding == nil)
        }
    }

    @Test
    func rejectsExtensionAndContentMismatch() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let fileURL = temporaryDirectory.appendingPathComponent("disguised.pdf")
        try Data("This is not a PDF".utf8).write(to: fileURL, options: .atomic)

        do {
            _ = try detector.detectFormat(at: fileURL)
            Issue.record("Expected signature validation to reject the file")
        } catch let error as BookImportError {
            #expect(error == .fileSignatureMismatch(expectedFormat: .pdf))
        }
    }

    @Test
    func detectsUTF8AndBOMMarkedUTF16() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let utf8URL = temporaryDirectory.appendingPathComponent("中文.md")
        try Data("# 标题\n正文🙂".utf8).write(to: utf8URL, options: .atomic)
        #expect(try detector.detectFormat(at: utf8URL).textEncoding == .utf8)

        let utf16URL = temporaryDirectory.appendingPathComponent("中文.txt")
        var utf16Data = Data([0xFF, 0xFE])
        utf16Data.append(try #require("中文🙂".data(using: .utf16LittleEndian)))
        try utf16Data.write(to: utf16URL, options: .atomic)
        #expect(
            try detector.detectFormat(at: utf16URL).textEncoding == .utf16LittleEndian
        )
    }

    @Test
    func rejectsInvalidUTF8EvenWhenCorruptionIsBeyondFirstChunk() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        var data = Data(repeating: 0x61, count: 70 * 1_024)
        data.append(0xFF)
        let fileURL = temporaryDirectory.appendingPathComponent("corrupt.txt")
        try data.write(to: fileURL, options: .atomic)

        do {
            _ = try detector.detectFormat(at: fileURL)
            Issue.record("Expected invalid UTF-8 to be rejected")
        } catch let error as BookImportError {
            #expect(error == .invalidTextEncoding)
        }
    }

    @Test
    func rejectsUTF16WithoutBOMInsteadOfGuessing() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let fileURL = temporaryDirectory.appendingPathComponent("ambiguous.txt")
        let data = try #require("中文".data(using: .utf16LittleEndian))
        try data.write(to: fileURL, options: .atomic)

        do {
            _ = try detector.detectFormat(at: fileURL)
            Issue.record("Expected unmarked UTF-16 to be rejected")
        } catch let error as BookImportError {
            #expect(error == .invalidTextEncoding)
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("BookFormatDetectorTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }
}
