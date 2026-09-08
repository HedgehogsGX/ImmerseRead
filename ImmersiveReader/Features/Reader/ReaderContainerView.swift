import SwiftUI

struct ReaderContainerView: View {
    let document: ReaderDocument
    let initialProgress: Double
    let onProgressChange: (Double) -> Void
    let onLocationChange: ((Double, Data) -> Void)?

    @State private var epubReader: any EPUBReader
    @State private var settings: ReaderDisplaySettings
    @State private var presentedSheet: PresentedSheet?
    @State private var pdfLocation: PDFReadingLocation

    init(
        document: ReaderDocument,
        initialProgress: Double = 0,
        onProgressChange: @escaping (Double) -> Void = { _ in },
        initialLocationData: Data? = nil,
        onLocationChange: ((Double, Data) -> Void)? = nil,
        initialSettings: ReaderDisplaySettings? = nil,
        epubReader: (any EPUBReader)? = nil
    ) {
        self.document = document
        self.initialProgress = min(max(initialProgress, 0), 1)
        self.onProgressChange = { progress in
            onProgressChange(min(max(progress, 0), 1))
        }
        self.onLocationChange = onLocationChange
        _pdfLocation = State(initialValue: PDFReadingLocation.restore(
            from: initialLocationData,
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
            let progress = newLocation.progress(for: newLocation.mode)
            if let onLocationChange, let data = newLocation.encoded() {
                onLocationChange(progress, data)
            } else {
                onProgressChange(progress)
            }
        }
    }

    @ViewBuilder
    private var readerSurface: some View {
        switch document.format {
        case .plainText, .markdown:
            TextReaderView(
                document: document,
                settings: settings,
                initialProgress: initialProgress,
                onProgressChange: onProgressChange
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
                initialProgress: initialProgress,
                onProgressChange: onProgressChange,
                reader: epubReader
            )

        case .docx:
            DOCXReaderView(
                document: document,
                settings: settings,
                initialProgress: initialProgress,
                onProgressChange: onProgressChange
            )

        case .legacyWord:
            LegacyDocumentPreviewView(document: document)
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
