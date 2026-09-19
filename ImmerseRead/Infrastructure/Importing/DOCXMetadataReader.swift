import Foundation
import ReadiumZIPFoundation

/// Reads the little the shelf needs from a DOCX package — title, author and a
/// cover picture — without running the body through the converter.
struct DOCXMetadataReader: Sendable {
    /// Word writes this preview when "save thumbnail" is on.
    private static let thumbnailPaths = [
        "docprops/thumbnail.jpeg",
        "docprops/thumbnail.jpg",
        "docprops/thumbnail.png",
    ]
    private static let corePropertiesPath = "docprops/core.xml"
    private static let mediaPrefix = "word/media/"
    private static let pictureExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "bmp", "tiff", "tif", "heic", "webp",
    ]
    private static let maximumPropertiesBytes = 256 * 1_024

    private let coverImageProcessor: CoverImageProcessor
    /// How many pictures to try before settling for lettering, so a document
    /// full of icons cannot turn import into a decode marathon.
    private let maximumInspectedPictures = 8

    init(coverImageProcessor: CoverImageProcessor = CoverImageProcessor()) {
        self.coverImageProcessor = coverImageProcessor
    }

    func read(from fileURL: URL) async -> BookMetadata {
        guard let archive = try? await Archive(url: fileURL, accessMode: .read),
              let entries = try? await archive.entries(),
              !entries.isEmpty
        else {
            return BookMetadata()
        }

        let properties = await documentProperties(in: archive, entries: entries)
        guard !Task.isCancelled else {
            return BookMetadata()
        }
        let coverData = await coverData(in: archive, entries: entries)

        return BookMetadata(
            title: properties.title,
            author: properties.author,
            coverData: coverData,
            coverSource: .embedded
        )
    }

    private func documentProperties(
        in archive: Archive,
        entries: [Entry]
    ) async -> (title: String?, author: String?) {
        guard let entry = entry(at: Self.corePropertiesPath, in: entries),
              let data = await data(
                  of: entry,
                  in: archive,
                  maximumBytes: Self.maximumPropertiesBytes
              )
        else {
            return (nil, nil)
        }

        let values = CorePropertiesParser.parse(data)
        return (
            BookMetadataExtractor.normalized(values["dc:title"]),
            BookMetadataExtractor.normalized(values["dc:creator"])
        )
    }

    private func coverData(in archive: Archive, entries: [Entry]) async -> Data? {
        for path in Self.thumbnailPaths {
            guard let entry = entry(at: path, in: entries),
                  let data = await data(
                      of: entry,
                      in: archive,
                      maximumBytes: coverImageProcessor.maximumSourceBytes
                  ),
                  let cover = coverImageProcessor.encodedCover(fromImageData: data)
            else {
                continue
            }
            return cover
        }

        for entry in pictureEntries(in: entries).prefix(maximumInspectedPictures) {
            guard !Task.isCancelled else {
                return nil
            }
            guard let data = await data(
                of: entry,
                in: archive,
                maximumBytes: coverImageProcessor.maximumSourceBytes
            ),
                // A scavenged picture has to be big enough to read as a cover,
                // otherwise bullets and logos would become the artwork.
                let cover = coverImageProcessor.encodedCover(
                    fromImageData: data,
                    requiringUsableSize: true
                )
            else {
                continue
            }
            return cover
        }
        return nil
    }

    /// Pictures in the order Word numbers them, which follows the document.
    private func pictureEntries(in entries: [Entry]) -> [Entry] {
        entries
            .filter { entry in
                let path = entry.path.lowercased()
                guard entry.type == .file, path.hasPrefix(Self.mediaPrefix) else {
                    return false
                }
                let fileExtension = (path as NSString).pathExtension
                return Self.pictureExtensions.contains(fileExtension)
            }
            .sorted { lhs, rhs in
                let lhsIndex = Self.pictureIndex(in: lhs.path)
                let rhsIndex = Self.pictureIndex(in: rhs.path)
                if lhsIndex != rhsIndex {
                    return lhsIndex < rhsIndex
                }
                return lhs.path < rhs.path
            }
    }

    private func entry(at path: String, in entries: [Entry]) -> Entry? {
        entries.first { $0.type == .file && $0.path.lowercased() == path }
    }

    private func data(
        of entry: Entry,
        in archive: Archive,
        maximumBytes: Int
    ) async -> Data? {
        guard entry.uncompressedSize > 0,
              entry.uncompressedSize <= UInt64(maximumBytes)
        else {
            return nil
        }

        let collector = ArchiveDataCollector()
        do {
            _ = try await archive.extract(entry, skipCRC32: true) { chunk in
                await collector.append(chunk)
            }
        } catch {
            return nil
        }
        let data = await collector.value
        return data.isEmpty ? nil : data
    }

    /// `word/media/image10.png` has to sort after `image2.png`.
    private static func pictureIndex(in path: String) -> Int {
        let name = (path as NSString).deletingPathExtension
        let digits = name.reversed().prefix { $0.isNumber }.reversed()
        return Int(String(digits)) ?? Int.max
    }
}

/// Pulls the handful of Dublin Core values Word stores in `docProps/core.xml`.
private final class CorePropertiesParser: NSObject, XMLParserDelegate {
    private static let wantedElements: Set<String> = ["dc:title", "dc:creator"]

    private var values: [String: String] = [:]
    private var currentElement: String?
    private var currentText = ""

    static func parse(_ data: Data) -> [String: String] {
        let delegate = CorePropertiesParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        guard parser.parse() else {
            return delegate.values
        }
        return delegate.values
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes attributeDict: [String: String]
    ) {
        let name = elementName.lowercased()
        currentElement = Self.wantedElements.contains(name) ? name : nil
        currentText = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard currentElement != nil, currentText.count < 1_024 else {
            return
        }
        currentText += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?
    ) {
        defer {
            currentElement = nil
            currentText = ""
        }
        guard let currentElement, currentElement == elementName.lowercased() else {
            return
        }
        values[currentElement] = currentText
    }
}
