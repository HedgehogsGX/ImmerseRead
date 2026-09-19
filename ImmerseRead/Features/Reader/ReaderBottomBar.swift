import SwiftUI

/// The row pinned under the reading surface: how pages advance, and font size.
///
/// These are the two choices a reader makes while reading. Anything consulted
/// once per document — the PDF's original layout, themes, margins — lives in
/// the reading settings sheet instead.
struct ReaderBottomBar: View {
    @Binding var settings: ReaderDisplaySettings
    /// Off where type size does not apply, such as a PDF's original pages.
    var showsFontSize = true

    var body: some View {
        VStack(spacing: 0) {
            Divider()

            HStack(spacing: 12) {
                ReaderLayoutModePicker(settings: $settings)

                if showsFontSize {
                    ReaderFontSizeControls(settings: $settings, showsLabel: false)
                } else {
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }
}

/// Turning pages or scrolling, as a two-segment control: a single button
/// labelled with one of them cannot say which one is currently in use.
struct ReaderLayoutModePicker: View {
    @Binding var settings: ReaderDisplaySettings

    var body: some View {
        Picker("阅读方式", selection: $settings.layoutMode) {
            ForEach(ReaderLayoutMode.allCases) { mode in
                Image(systemName: mode.systemImage)
                    .accessibilityLabel(mode.title)
                    .tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 104)
        .accessibilityIdentifier("reader.layoutMode")
    }
}

#Preview("Paged") {
    ReaderBottomBar(settings: .constant(.default))
}

#Preview("Original pages") {
    ReaderBottomBar(settings: .constant(.default), showsFontSize: false)
}
