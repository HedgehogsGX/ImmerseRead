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
}

/// Readium-backed EPUB reader with no DRM content protections installed.
@MainActor
final class ReadiumEPUBReader: EPUBReader {
    private var session: Session?

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
}

/// Compatibility for the existing container default. The default now creates
/// the real Readium adapter without requiring a cross-feature source change.
typealias UnavailableEPUBReader = ReadiumEPUBReader

private extension ReadiumEPUBReader {
    struct Session {
        let documentID: UUID
        let navigator: EPUBNavigatorViewController
        // Retain the opening stack for any lazily loaded publication services.
        let assetRetriever: AssetRetriever
        let publicationOpener: PublicationOpener
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
                message = "此出版物不允许复制所选内容。"
            }

            let alert = UIAlertController(
                title: "EPUB 阅读错误",
                message: message,
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "好", style: .default))
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

        self.init(
            fontSize: fontScale,
            lineHeight: lineHeight,
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
            "文件地址类型不受支持。"
        case .formatNotSupported:
            "文件不是有效的 EPUB，或其封装格式不受支持。"
        case .reading:
            "无法读取 EPUB 文件。"
        }
    }
}

private extension PublicationOpenError {
    var message: String {
        switch self {
        case .formatNotSupported:
            "无法解析 EPUB 内容。"
        case .reading:
            "读取 EPUB 内容时发生错误。"
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
            "EPUB 文件地址无效。"
        case .notEPUB:
            "所选文件不是可阅读的 EPUB 出版物。"
        case .assetRetrievalFailed(let message),
             .publicationOpeningFailed(let message):
            message
        case .drmNotSupported:
            "此 EPUB 受 DRM 保护，当前阅读器仅支持无 DRM 的书籍。"
        case .emptyReadingOrder:
            "EPUB 没有可阅读的正文内容。"
        case .navigatorCreationFailed:
            "无法创建 EPUB 阅读界面。"
        case .sessionNotPrepared:
            "EPUB 阅读会话尚未准备完成。"
        }
    }
}
