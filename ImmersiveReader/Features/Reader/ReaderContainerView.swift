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
        .onChange(of: settings) { _, newSettings in
            ReaderSettingsStore.save(newSettings)
        }
        .onChange(of: pdfLocation) { _, newLocation in
            guard document.format == .pdf else { return }
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
                onLocationChange: reportTextLocation
            )

        case .pdf:
            PDFDocumentReaderView(
                document: document,
                settings: $settings,
                location: $pdfLocation
            )
            .id(document.id)

        case .epub:
            EPUBReaderHostView(
                document: document,
                settings: $settings,
                initialLocation: initialEPUBLocation,
                initialProgress: initialProgress,
                onLocationChange: { location in
                    onLocationChange(location.progress, location.encoded())
                },
                reader: epubReader
            )

        case .docx:
            DOCXReaderView(
                document: document,
                settings: settings,
                initialLocation: initialTextLocation,
                initialProgress: initialProgress,
                onLocationChange: reportTextLocation
            )

        case .legacyWord:
            LegacyDocumentPreviewView(document: document)
        }
    }

    private func reportTextLocation(_ location: TextReadingLocation) {
        onLocationChange(location.progress, location.encoded())
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
