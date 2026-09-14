import SwiftUI

struct ReaderContainerView: View {
    let document: ReaderDocument
    let initialProgress: Double
    let initialTextLocation: TextReadingLocation?
    let initialEPUBLocation: EPUBReadingLocation?
    /// Receives the shelf progress and the format-specific location to persist.
    let onLocationChange: (Double, Data?) -> Void

    @State private var epubReader: any EPUBReader
    @State private var settings: ReaderDisplaySettings
    @State private var presentedSheet: PresentedSheet?
    @State private var pdfLocation: PDFReadingLocation
    @StateObject private var navigationModel: ReaderNavigationModel

    init(
        document: ReaderDocument,
        initialProgress: Double = 0,
        initialLocationData: Data? = nil,
        onLocationChange: @escaping (Double, Data?) -> Void = { _, _ in },
        initialSettings: ReaderDisplaySettings? = nil,
        epubReader: (any EPUBReader)? = nil
    ) {
        self.document = document
        self.initialProgress = initialProgress.clampedToUnitInterval
        self.onLocationChange = { progress, data in
            onLocationChange(progress.clampedToUnitInterval, data)
        }
        // Each format owns its location encoding; decoding another format's
        // payload fails and falls back to the coarse progress fraction.
        initialTextLocation = document.format == .pdf || document.format == .epub
            ? nil
            : TextReadingLocation.restore(from: initialLocationData)
        initialEPUBLocation = document.format == .epub
            ? EPUBReadingLocation.restore(from: initialLocationData)
            : nil
        _pdfLocation = State(initialValue: PDFReadingLocation.restore(
            from: document.format == .pdf ? initialLocationData : nil,
            legacyOriginalProgress: initialProgress
        ))
        _epubReader = State(initialValue: epubReader ?? ReadiumEPUBReader())
        _settings = State(
            initialValue: initialSettings ?? ReaderSettingsStore.load()
        )
        _navigationModel = StateObject(
            wrappedValue: ReaderNavigationModel(document: document)
        )
    }

    var body: some View {
        ZStack {
            settings.theme.backgroundColor
                .ignoresSafeArea()

            readerSurface
        }
        .preferredColorScheme(settings.theme.preferredColorScheme)
        .navigationTitle(document.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if document.format.supportsTypography {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        presentedSheet = .settings
                    } label: {
                        Label("阅读设置", systemImage: "textformat.size")
                    }
                    .accessibilityIdentifier("reader.settings.open")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                ReaderNavigationToolbar(
                    model: navigationModel,
                    supportsNavigation: document.format != .legacyWord
                )
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if document.format.supportsTypography, document.format != .pdf {
                ReaderFontSizeControls(settings: $settings)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .background(.bar)
            }
        }
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
            case .settings:
                ReaderSettingsView(
                    settings: $settings,
                    supportsTypography: document.format.supportsTypography,
                    pdfReadingMode: document.format == .pdf ? $pdfLocation.mode : nil
                )
                .presentationDetents([.medium, .large])
            }
        }
        .task {
            navigationModel.seedLocation(
                Self.openingLocation(
                    format: document.format,
                    pdfLocation: pdfLocation,
                    textLocation: initialTextLocation,
                    epubLocation: initialEPUBLocation
                )
            )
        }
        .onChange(of: settings) { _, newSettings in
            ReaderSettingsStore.save(newSettings)
        }
        .onChange(of: pdfLocation) { _, newLocation in
            guard document.format == .pdf else { return }
            navigationModel.report(location: .pdf(newLocation))
            onLocationChange(newLocation.progress(for: newLocation.mode), newLocation.encoded())
        }
    }

    @ViewBuilder
    private var readerSurface: some View {
        switch document.format {
        case .plainText, .markdown:
            TextReaderView(
                document: document,
                settings: settings,
                initialLocation: initialTextLocation,
                initialProgress: initialProgress,
                onLocationChange: reportTextLocation,
                navigationModel: navigationModel
            )

        case .pdf:
            PDFDocumentReaderView(
                document: document,
                settings: $settings,
                location: $pdfLocation,
                navigationModel: navigationModel
            )
            .id(document.id)

        case .epub:
            EPUBReaderHostView(
                document: document,
                settings: $settings,
                initialLocation: initialEPUBLocation,
                initialProgress: initialProgress,
                onLocationChange: { location in
                    navigationModel.report(location: .epub(location))
                    onLocationChange(location.progress, location.encoded())
                },
                navigationModel: navigationModel,
                reader: epubReader
            )

        case .docx:
            DOCXReaderView(
                document: document,
                settings: settings,
                initialLocation: initialTextLocation,
                initialProgress: initialProgress,
                onLocationChange: reportTextLocation,
                navigationModel: navigationModel
            )

        case .legacyWord:
            LegacyDocumentPreviewView(document: document)
        }
    }

    private func reportTextLocation(_ location: TextReadingLocation) {
        navigationModel.report(location: .text(location))
        onLocationChange(location.progress, location.encoded())
    }

    /// Where a document sits the moment it opens.
    ///
    /// PDF and reflowable text restore to a known position (or the very start),
    /// so they can be bookmarked right away. EPUB waits for the navigator to
    /// report, because only a restored locator is trustworthy before then.
    static func openingLocation(
        format: BookFormat,
        pdfLocation: PDFReadingLocation,
        textLocation: TextReadingLocation?,
        epubLocation: EPUBReadingLocation?
    ) -> ReaderNavigationLocation? {
        switch format {
        case .pdf:
            .pdf(pdfLocation)
        case .plainText, .markdown, .docx:
            .text(textLocation ?? TextReadingLocation(
                anchor: ReaderTextAnchor(blockIndex: 0, offsetInBlock: 0),
                progress: 0
            ))
        case .epub:
            epubLocation.map(ReaderNavigationLocation.epub)
        case .legacyWord:
            nil
        }
    }
}

private extension ReaderContainerView {
    enum PresentedSheet: String, Identifiable {
        case settings

        var id: Self { self }
    }
}

#Preview("Markdown") {
    NavigationStack {
        ReaderContainerView(
            document: ReaderDocument(
                id: UUID(),
                title: "示例 Markdown",
                fileURL: URL(fileURLWithPath: "/tmp/reader-preview.md"),
                format: .markdown
            )
        )
    }
}
