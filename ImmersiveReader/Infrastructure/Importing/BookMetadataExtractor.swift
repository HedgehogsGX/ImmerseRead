import Foundation
@preconcurrency import ReadiumShared
@preconcurrency import ReadiumStreamer
import CoreGraphics
import PDFKit
import UIKit

@MainActor
struct BookMetadataExtractor: Sendable {
    static let defaultCoverMaximumPixelSize = CGSize(width: 480, height: 680)
    static let defaultMaximumCoverBytes = 1_500_000
    static let defaultMaximumSourceCoverBytes = 32 * 1_024 * 1_024
    /// Pages smaller than an inch are separators or artefacts, not covers.
    static let minimumRenderablePageEdge: CGFloat = 72
    /// How deep to look for a page worth showing when the document opens blank.
    static let maximumInspectedPDFPages = 3
    /// A bounded prefix is enough for a Markdown heading or front matter.
    static let maximumInspectedTextBytes = 8 * 1_024

    private let coverMaximumPixelSize: CGSize
    private let coverImageProcessor: CoverImageProcessor
    private let maximumSourceCoverBytes: Int

    init(
        coverMaximumPixelSize: CGSize = BookMetadataExtractor.defaultCoverMaximumPixelSize,
        maximumCoverBytes: Int = BookMetadataExtractor.defaultMaximumCoverBytes,
        maximumSourceCoverBytes: Int = BookMetadataExtractor.defaultMaximumSourceCoverBytes
    ) {
        self.coverMaximumPixelSize = coverMaximumPixelSize
        self.maximumSourceCoverBytes = max(1, maximumSourceCoverBytes)
        coverImageProcessor = CoverImageProcessor(
            maximumPixelSize: max(coverMaximumPixelSize.width, coverMaximumPixelSize.height),
            maximumEncodedBytes: maximumCoverBytes,
            maximumSourceBytes: maximumSourceCoverBytes
        )
    }

    func extract(from fileURL: URL, format: BookFormat) async -> BookMetadata {
        guard !Task.isCancelled else {
            return BookMetadata()
        }

        switch format {
        case .epub:
            return await extractEPUB(from: fileURL)
        case .pdf:
            return extractPDF(from: fileURL)
        case .docx:
            return await DOCXMetadataReader(coverImageProcessor: coverImageProcessor)
                .read(from: fileURL)
        case .markdown:
            return extractMarkdown(from: fileURL)
        case .plainText, .legacyWord:
            return BookMetadata()
        }
    }

    // MARK: - EPUB

    private func extractEPUB(from fileURL: URL) async -> BookMetadata {
        guard let readiumURL = FileURL(url: fileURL) else {
            return BookMetadata()
        }

        let httpClient = DefaultHTTPClient()
        let assetRetriever = AssetRetriever(httpClient: httpClient)
        let publicationOpener = PublicationOpener(
            parser: DefaultPublicationParser(
                httpClient: httpClient,
                assetRetriever: assetRetriever,
                pdfFactory: DefaultPDFDocumentFactory()
            ),
            contentProtections: []
        )

        let asset: Asset
        switch await assetRetriever.retrieve(url: readiumURL) {
        case .success(let retrievedAsset):
            asset = retrievedAsset
        case .failure:
            return BookMetadata()
        }

        guard !Task.isCancelled else {
            return BookMetadata()
        }

        let publication: Publication
        switch await publicationOpener.open(asset: asset, allowUserInteraction: false) {
        case .success(let openedPublication):
            publication = openedPublication
        case .failure:
            return BookMetadata()
        }

        guard !Task.isCancelled else {
            return BookMetadata()
        }

        let title = Self.normalized(publication.metadata.title)
        let author = Self.normalized(
            publication.metadata.authors
                .map(\.name)
                .compactMap(Self.normalized)
                .joined(separator: ", ")
        )
        let coverData = await extractCoverData(from: publication)

        return BookMetadata(
            title: title,
            author: author,
            coverData: coverData,
            coverSource: .embedded
        )
    }

    private func extractCoverData(from publication: Publication) async -> Data? {
        guard let coverLink = coverLink(in: publication),
              coverLink.mediaType?.isBitmap == true,
              coverLink.url().relativeURL != nil,
              let resource = publication.get(coverLink)
        else {
            return nil
        }

        guard let sourceData = await readCoverData(from: resource) else {
            return nil
        }
        // The publication declares this picture as its cover, so it is used at
        // whatever size it comes in.
        return coverImageProcessor.encodedCover(fromImageData: sourceData)
    }

    private func readCoverData(from resource: Resource) async -> Data? {
        guard !Task.isCancelled else {
            return nil
        }

        let maximumBytes = maximumSourceCoverBytes
        switch await resource.estimatedLength() {
        case .success(let estimatedLength):
            if estimatedLength ?? 0 > UInt64(maximumBytes) {
                return nil
            }
        case .failure:
            break
        }

        let readLimit = UInt64(maximumBytes) + 1
        switch await resource.read(range: 0 ..< readLimit) {
        case .success(let data) where data.count <= maximumBytes:
            guard !Task.isCancelled else {
                return nil
            }
            return data
        case .success:
            return nil
        case .failure:
            return nil
        }
    }

    private func coverLink(in publication: Publication) -> Link? {
        if let explicitCover = publication.linksWithRel(.cover).first {
            return explicitCover
        }

        guard let firstReadingOrderLink = publication.readingOrder.first else {
            return nil
        }
        if isImage(firstReadingOrderLink) {
            return firstReadingOrderLink
        }
        return firstReadingOrderLink.alternates.first(where: isImage)
    }

    private func isImage(_ link: Link) -> Bool {
        link.mediaType?.isBitmap == true
    }

    // MARK: - PDF

    private func extractPDF(from fileURL: URL) -> BookMetadata {
        guard let document = PDFKit.PDFDocument(url: fileURL) else {
            return BookMetadata()
        }

        let attributes = document.documentAttributes ?? [:]
        return BookMetadata(
            title: Self.normalized(Self.stringAttribute(.titleAttribute, in: attributes)),
            author: Self.normalized(Self.stringAttribute(.authorAttribute, in: attributes)),
            coverData: renderedPDFCoverData(from: document),
            coverSource: .rendered
        )
    }

    /// Renders the first page that is not blank, which is what a reader would
    /// recognise as the document's cover.
    private func renderedPDFCoverData(from document: PDFKit.PDFDocument) -> Data? {
        guard !document.isLocked, document.pageCount > 0 else {
            return nil
        }

        let inspectedPageCount = min(document.pageCount, Self.maximumInspectedPDFPages)
        for pageIndex in 0 ..< inspectedPageCount {
            guard !Task.isCancelled, let page = document.page(at: pageIndex) else {
                return nil
            }

            let bounds = page.bounds(for: PDFDisplayBox.cropBox)
            guard bounds.width >= Self.minimumRenderablePageEdge,
                  bounds.height >= Self.minimumRenderablePageEdge
            else {
                continue
            }

            // Cap the upscale so a small page cannot ask for a huge bitmap.
            let scale = min(
                4,
                min(
                    coverMaximumPixelSize.width / bounds.width,
                    coverMaximumPixelSize.height / bounds.height
                )
            )
            let targetSize = CGSize(
                width: max(1, (bounds.width * scale).rounded()),
                height: max(1, (bounds.height * scale).rounded())
            )

            guard let image = page.thumbnail(of: targetSize, for: PDFDisplayBox.cropBox).cgImage,
                  !CoverImageProcessor.isLikelyBlank(image)
            else {
                continue
            }
            return coverImageProcessor.encodedCover(from: image)
        }
        return nil
    }

    // MARK: - Markdown

    /// Markdown carries no package metadata, so the title comes from YAML front
    /// matter or the first heading, the way the document itself reads.
    private func extractMarkdown(from fileURL: URL) -> BookMetadata {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            return BookMetadata()
        }
        defer { try? handle.close() }

        guard let data = try? handle.read(upToCount: Self.maximumInspectedTextBytes),
              let text = String(data: data, encoding: .utf8)
        else {
            return BookMetadata()
        }

        let lines = text.components(separatedBy: .newlines)
        var frontMatter: [String: String] = [:]
        var bodyStartIndex = 0

        if lines.first?.trimmingCharacters(in: .whitespaces) == "---" {
            for (index, line) in lines.enumerated().dropFirst() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed == "---" || trimmed == "..." {
                    bodyStartIndex = index + 1
                    break
                }
                guard let separatorIndex = trimmed.firstIndex(of: ":") else {
                    continue
                }
                let key = trimmed[trimmed.startIndex ..< separatorIndex]
                    .trimmingCharacters(in: .whitespaces)
                    .lowercased()
                let value = trimmed[trimmed.index(after: separatorIndex)...]
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                frontMatter[key] = value
            }
        }

        let heading = lines[bodyStartIndex...]
            .lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix("# ") }?
            .dropFirst(2)
            .trimmingCharacters(in: .whitespaces)

        return BookMetadata(
            title: Self.normalized(frontMatter["title"]) ?? Self.normalized(heading),
            author: Self.normalized(frontMatter["author"])
        )
    }

    // MARK: - Shared

    private static func stringAttribute(
        _ key: PDFDocumentAttribute,
        in attributes: [AnyHashable: Any]
    ) -> String? {
        if let value = attributes[key] as? String {
            return value
        }
        if let value = attributes[key] as? NSString {
            return value as String
        }
        return nil
    }

    nonisolated static func normalized(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        return String(trimmed.prefix(512))
    }
}
