import Foundation
@preconcurrency import ReadiumNavigator
@preconcurrency import ReadiumShared
@preconcurrency import ReadiumStreamer
import SwiftUI
import UIKit

/// Boundary between the app reader and Readium 3.11.
///
/// The opening work is completed before the navigator enters the SwiftUI view
/// hierarchy. This keeps opening failures in `EPUBReaderHostView`'s normal
/// loading/error state instead of replacing the navigator with an ad-hoc UIKit
/// error controller.
@MainActor
protocol EPUBReader: AnyObject {
    /// `initialLocation` is the exact saved locator; `initialProgress` is the
    /// coarse fallback for books saved before locators were persisted.
    func prepare(
        document: ReaderDocument,
        initialLocation: EPUBReadingLocation?,
        initialProgress: Double,
        settings: ReaderDisplaySettings
    ) async throws

    func makeReaderView(
        settings: Binding<ReaderDisplaySettings>,
        onLocationChange: @escaping (EPUBReadingLocation) -> Void
    ) -> AnyView

    func navigationSections() async -> [ReaderNavigationSection]
    func search(query: String) async throws -> [ReaderSearchResult]
    func go(to location: EPUBReadingLocation) async -> Bool
}

extension EPUBReader {
    func navigationSections() async -> [ReaderNavigationSection] { [] }
    func search(query: String) async throws -> [ReaderSearchResult] { [] }
    func go(to location: EPUBReadingLocation) async -> Bool { false }
}

/// Readium-backed EPUB reader with no DRM content protections installed.
@MainActor
final class ReadiumEPUBReader: EPUBReader {
    private var session: Session?

    /// The navigator's current locator as JSON; the saved initial locator until the reader has laid out.
    var currentLocationJSON: String? {
        try? session?.navigator.currentLocation?.jsonString()
    }

    func prepare(
        document: ReaderDocument,
        initialLocation: EPUBReadingLocation?,
        initialProgress: Double,
        settings: ReaderDisplaySettings
    ) async throws {
        session = nil

        guard document.format == .epub else {
            throw EPUBReaderIntegrationError.notEPUB
        }
        guard let fileURL = FileURL(url: document.fileURL) else {
            throw EPUBReaderIntegrationError.invalidFileURL
        }

        // Each opening task owns its dependencies. A cancelled retry can still
        // be unwinding inside Readium while the next attempt starts, so sharing
        // these non-Sendable reference types between attempts would weaken the
        // adapter's main-actor isolation guarantees.
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
        switch await assetRetriever.retrieve(url: fileURL) {
        case .success(let retrievedAsset):
            asset = retrievedAsset
        case .failure(let error):
            throw EPUBReaderIntegrationError.assetRetrievalFailed(error.message)
        }
        try Task.checkCancellation()

        let publication: Publication
        switch await publicationOpener.open(
            asset: asset,
            allowUserInteraction: false
        ) {
        case .success(let openedPublication):
            publication = openedPublication
        case .failure(let error):
            throw EPUBReaderIntegrationError.publicationOpeningFailed(error.message)
        }
        try Task.checkCancellation()

        guard publication.conforms(to: .epub) else {
            throw EPUBReaderIntegrationError.notEPUB
        }
        guard !publication.isRestricted else {
            throw EPUBReaderIntegrationError.drmNotSupported
        }
        guard !publication.readingOrder.isEmpty else {
            throw EPUBReaderIntegrationError.emptyReadingOrder
        }

        let initialLocator: Locator?
        if let savedLocator = initialLocation.flatMap({ try? Locator(jsonString: $0.locatorJSON) }) {
            initialLocator = savedLocator
        } else {
            let progress = initialProgress.clampedToProgress
            initialLocator = await publication.locate(progression: progress)
                ?? publication.approximateLocator(at: progress)
        }
        try Task.checkCancellation()

        let navigator: EPUBNavigatorViewController
        do {
            navigator = try EPUBNavigatorViewController(
                publication: publication,
                initialLocation: initialLocator,
                config: .init(
                    preferences: EPUBPreferences(
                        displaySettings: settings,
                        interfaceStyle: UITraitCollection.current.userInterfaceStyle
                    ),
                    disablePageTurnsWhileScrolling: true
                )
            )
        } catch {
            throw EPUBReaderIntegrationError.navigatorCreationFailed
        }

        session = Session(
            documentID: document.id,
            publication: publication,
            navigator: navigator,
            assetRetriever: assetRetriever,
            publicationOpener: publicationOpener
        )
    }

    func makeReaderView(
        settings: Binding<ReaderDisplaySettings>,
        onLocationChange: @escaping (EPUBReadingLocation) -> Void
    ) -> AnyView {
        guard let session else {
            return AnyView(
                ContentUnavailableView(
                    "EPUB 阅读器未准备好",
                    systemImage: "exclamationmark.triangle",
                    description: Text(EPUBReaderIntegrationError.sessionNotPrepared.localizedDescription)
                )
            )
        }

        return AnyView(
            ReadiumEPUBNavigatorView(
                navigator: session.navigator,
                settings: settings.wrappedValue,
                onLocationChange: onLocationChange
            )
            .id(session.documentID)
        )
    }

    func navigationSections() async -> [ReaderNavigationSection] {
        guard let session,
              let links = await session.publication.tableOfContents().getOrNil() else {
            return []
        }
        var sections: [ReaderNavigationSection] = []
        await appendNavigationSections(
            links,
            level: 1,
            path: [],
            publication: session.publication,
            into: &sections
        )
        return sections
    }

    func search(query: String) async throws -> [ReaderSearchResult] {
        guard let session else { return [] }
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }

        let result = await session.publication.search(
            query: query,
            options: SearchOptions(caseSensitive: false, diacriticSensitive: false)
        )
        let iterator: any SearchIterator
        switch result {
        case .success(let value):
            iterator = value
        case .failure(let error):
            throw error
        }

        defer { iterator.close() }
        var results: [ReaderSearchResult] = []
        while results.count < 200 {
            try Task.checkCancellation()
            switch await iterator.next() {
            case .failure(let error):
                throw error
            case .success(nil):
                return results
            case .success(let collection?):
                for locator in collection.locators {
                    try Task.checkCancellation()
                    guard results.count < 200,
                          let location = Self.epubLocation(for: locator) else {
                        break
                    }
                    results.append(ReaderSearchResult(
                        id: "epub-search-\(results.count)-\(locator.href.string)",
                        title: locator.title ?? String(localized: "正文"),
                        snippet: Self.searchSnippet(for: locator),
                        location: .epub(location)
                    ))
                }
            }
        }
        return results
    }

    func go(to location: EPUBReadingLocation) async -> Bool {
        guard let session,
              let locator = try? Locator(jsonString: location.locatorJSON) else {
            return false
        }
        return await session.navigator.go(to: locator, options: NavigatorGoOptions())
    }
}

/// Compatibility for the existing container default. The default now creates
/// the real Readium adapter without requiring a cross-feature source change.
typealias UnavailableEPUBReader = ReadiumEPUBReader

private extension ReadiumEPUBReader {
    struct Session {
        let documentID: UUID
        let publication: Publication
        let navigator: EPUBNavigatorViewController
        // Retain the opening stack for any lazily loaded publication services.
        let assetRetriever: AssetRetriever
        let publicationOpener: PublicationOpener
    }
}

private extension ReadiumEPUBReader {
    func appendNavigationSections(
        _ links: [ReadiumShared.Link],
        level: Int,
        path: [Int],
        publication: Publication,
        into sections: inout [ReaderNavigationSection]
    ) async {
        for (index, link) in links.enumerated() {
            let currentPath = path + [index]
            let locator = await locator(for: link, publication: publication)
            if let locator, let location = Self.epubLocation(for: locator) {
                sections.append(ReaderNavigationSection(
                    id: "epub-toc-\(currentPath.map(String.init).joined(separator: "-"))",
                    title: link.title ?? locator.title ?? String(localized: "第 \(sections.count + 1) 节"),
                    level: level,
                    location: .epub(location)
                ))
            }
            if !link.children.isEmpty {
                await appendNavigationSections(
                    link.children,
                    level: level + 1,
                    path: currentPath,
                    publication: publication,
                    into: &sections
                )
            }
        }
    }

    func locator(for link: ReadiumShared.Link, publication: Publication) async -> Locator? {
        if let locator = await publication.locate(link) {
            return locator
        }
        for child in link.children {
            if let locator = await locator(for: child, publication: publication) {
                return locator
            }
        }
        return nil
    }

    static func epubLocation(for locator: Locator) -> EPUBReadingLocation? {
        guard let locatorJSON = try? locator.jsonString() else { return nil }
        return EPUBReadingLocation(
            locatorJSON: locatorJSON,
            progress: locator.locations.totalProgression ?? 0
        )
    }

    static func searchSnippet(for locator: Locator) -> String {
        let text = locator.text
        let snippet = [text.before, text.highlight, text.after]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined()
        return snippet.isEmpty ? (locator.title ?? String(localized: "正文")) : snippet
    }
}

@MainActor
private struct ReadiumEPUBNavigatorView: UIViewControllerRepresentable {
    let navigator: EPUBNavigatorViewController
    let settings: ReaderDisplaySettings
    let onLocationChange: (EPUBReadingLocation) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onLocationChange: onLocationChange)
    }

    func makeUIViewController(context: Context) -> EPUBNavigatorViewController {
        context.coordinator.attach(to: navigator)
        context.coordinator.update(
            settings: settings,
            interfaceStyle: context.environment.colorScheme.interfaceStyle,
            navigator: navigator
        )
        return navigator
    }

    func updateUIViewController(
        _ navigator: EPUBNavigatorViewController,
        context: Context
    ) {
        context.coordinator.onLocationChange = onLocationChange
        context.coordinator.update(
            settings: settings,
            interfaceStyle: context.environment.colorScheme.interfaceStyle,
            navigator: navigator
        )
    }

    static func dismantleUIViewController(
        _ navigator: EPUBNavigatorViewController,
        coordinator: Coordinator
    ) {
        coordinator.detach(from: navigator)
    }

    @MainActor
    final class Coordinator: NSObject, EPUBNavigatorDelegate {
        var onLocationChange: (EPUBReadingLocation) -> Void

        private var appliedConfiguration: AppliedConfiguration?
        private var directionalNavigationAdapter: DirectionalNavigationAdapter?
        private var lastReportedLocation: EPUBReadingLocation?

        init(onLocationChange: @escaping (EPUBReadingLocation) -> Void) {
            self.onLocationChange = onLocationChange
        }

        func attach(to navigator: EPUBNavigatorViewController) {
            navigator.delegate = self

            let adapter = DirectionalNavigationAdapter(animatedTransition: true)
            adapter.bind(to: navigator)
            directionalNavigationAdapter = adapter
        }

        func detach(from navigator: EPUBNavigatorViewController) {
            if navigator.delegate === self {
                navigator.delegate = nil
            }
            directionalNavigationAdapter?.unbind()
            directionalNavigationAdapter = nil
        }

        func update(
            settings: ReaderDisplaySettings,
            interfaceStyle: UIUserInterfaceStyle,
            navigator: EPUBNavigatorViewController
        ) {
            let configuration = AppliedConfiguration(
                settings: settings,
                interfaceStyle: interfaceStyle
            )
            guard configuration != appliedConfiguration else {
                return
            }

            appliedConfiguration = configuration
            navigator.submitPreferences(
                EPUBPreferences(
                    displaySettings: settings,
                    interfaceStyle: interfaceStyle
                )
            )
        }

        func navigator(_ navigator: Navigator, locationDidChange locator: Locator) {
            guard let progress = locator.locations.totalProgression?.clampedToProgress,
                  let locatorJSON = try? locator.jsonString() else {
                return
            }
            let location = EPUBReadingLocation(locatorJSON: locatorJSON, progress: progress)
            guard location != lastReportedLocation else {
                return
            }

            lastReportedLocation = location
            onLocationChange(location)
        }

        func navigator(_ navigator: Navigator, presentError error: NavigatorError) {
            guard let presenter = navigator as? UIViewController else {
                return
            }

            let message: String
            switch error {
            case .copyForbidden:
                message = String(localized: "此出版物不允许复制所选内容。")
            }

            let alert = UIAlertController(
                title: String(localized: "EPUB 阅读错误"),
                message: message,
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: String(localized: "好"), style: .default))
            presenter.present(alert, animated: true)
        }
    }
}

private extension ReadiumEPUBNavigatorView.Coordinator {
    struct AppliedConfiguration: Equatable {
        let settings: ReaderDisplaySettings
        let interfaceStyle: UIUserInterfaceStyle
    }
}

private extension EPUBPreferences {
    init(
        displaySettings settings: ReaderDisplaySettings,
        interfaceStyle: UIUserInterfaceStyle
    ) {
        let defaultFontSize = ReaderDisplaySettings.default.fontSize
        let rawFontScale = settings.fontSize.isFinite && defaultFontSize > 0
            ? settings.fontSize / defaultFontSize
            : 1
        let fontScale = min(max(rawFontScale, 0.1), 5)
        let lineHeight = settings.lineHeightMultiple.isFinite
            ? min(max(settings.lineHeightMultiple, 1), 2)
            : ReaderDisplaySettings.default.lineHeightMultiple
        let margin = settings.margin.isFinite
            ? settings.epubPageMargins
            : ReaderDisplaySettings.default.epubPageMargins

        self.init(
            fontFamily: FontFamily(rawValue: settings.fontFamily.readiumRawValue),
            fontSize: fontScale,
            lineHeight: lineHeight,
            pageMargins: margin,
            publisherStyles: false,
            scroll: settings.layoutMode == .scrolling,
            theme: settings.theme.readiumTheme(interfaceStyle: interfaceStyle)
        )
    }
}

private extension ReaderTheme {
    func readiumTheme(interfaceStyle: UIUserInterfaceStyle) -> ReadiumNavigator.Theme {
        switch self {
        case .system:
            interfaceStyle == .dark ? .dark : .light
        case .light:
            .light
        case .sepia:
            .sepia
        case .dark:
            .dark
        }
    }
}

private extension ColorScheme {
    var interfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .light:
            .light
        case .dark:
            .dark
        @unknown default:
            .unspecified
        }
    }
}

private extension Publication {
    /// EPUBs normally provide a positions service. This deterministic fallback
    /// keeps progress restoration usable for malformed books that do not.
    func approximateLocator(at totalProgression: Double) -> Locator? {
        guard !readingOrder.isEmpty else {
            return nil
        }

        let progress = totalProgression.clampedToProgress
        let scaledProgress = progress * Double(readingOrder.count)
        let index = min(Int(scaledProgress), readingOrder.count - 1)
        let link = readingOrder[index]
        let resourceProgression = index == readingOrder.count - 1 && progress == 1
            ? 1
            : scaledProgress - Double(index)

        return Locator(
            href: link.url(),
            mediaType: link.mediaType ?? .xhtml,
            title: link.title,
            locations: .init(
                progression: resourceProgression,
                totalProgression: progress
            )
        )
    }
}

private extension Double {
    var clampedToProgress: Double {
        guard isFinite else {
            return 0
        }
        return min(max(self, 0), 1)
    }
}

private extension AssetRetrieveURLError {
    var message: String {
        switch self {
        case .schemeNotSupported:
            String(localized: "文件地址类型不受支持。")
        case .formatNotSupported:
            String(localized: "文件不是有效的 EPUB，或其封装格式不受支持。")
        case .reading:
            String(localized: "无法读取 EPUB 文件。")
        }
    }
}

private extension PublicationOpenError {
    var message: String {
        switch self {
        case .formatNotSupported:
            String(localized: "无法解析 EPUB 内容。")
        case .reading:
            String(localized: "读取 EPUB 内容时发生错误。")
        }
    }
}

enum EPUBReaderIntegrationError: LocalizedError {
    case invalidFileURL
    case notEPUB
    case assetRetrievalFailed(String)
    case publicationOpeningFailed(String)
    case drmNotSupported
    case emptyReadingOrder
    case navigatorCreationFailed
    case sessionNotPrepared

    var errorDescription: String? {
        switch self {
        case .invalidFileURL:
            String(localized: "EPUB 文件地址无效。")
        case .notEPUB:
            String(localized: "所选文件不是可阅读的 EPUB 出版物。")
        case .assetRetrievalFailed(let message),
             .publicationOpeningFailed(let message):
            message
        case .drmNotSupported:
            String(localized: "此 EPUB 受 DRM 保护，当前阅读器仅支持无 DRM 的书籍。")
        case .emptyReadingOrder:
            String(localized: "EPUB 没有可阅读的正文内容。")
        case .navigatorCreationFailed:
            String(localized: "无法创建 EPUB 阅读界面。")
        case .sessionNotPrepared:
            String(localized: "EPUB 阅读会话尚未准备完成。")
        }
    }
}
