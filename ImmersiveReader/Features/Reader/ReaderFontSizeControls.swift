import SwiftUI

struct ReaderFontSizeControls: View {
    @Binding var settings: ReaderDisplaySettings
    var identifierPrefix = "reader.fontSize"
    /// Off when something else already occupies the leading edge of the row.
    var showsLabel = true

    var body: some View {
        HStack(spacing: 16) {
            if showsLabel {
                Text("字号")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Button {
                settings.adjustFontSize(by: -1)
            } label: {
                Image(systemName: "textformat.size.smaller")
                    .frame(minWidth: 32, minHeight: 32)
            }
            .buttonStyle(.bordered)
            .disabled(settings.fontSize <= ReaderDisplaySettings.fontSizeRange.lowerBound)
            .accessibilityLabel("减小字号")
            .accessibilityIdentifier("\(identifierPrefix).decrease")

            Text("\(Int(settings.fontSize)) pt")
                .font(.subheadline.monospacedDigit())
                .frame(minWidth: 48)
                .accessibilityLabel("当前字号 \(Int(settings.fontSize)) 点")
                .accessibilityIdentifier("\(identifierPrefix).value")

            Button {
                settings.adjustFontSize(by: 1)
            } label: {
                Image(systemName: "textformat.size.larger")
                    .frame(minWidth: 32, minHeight: 32)
            }
            .buttonStyle(.bordered)
            .disabled(settings.fontSize >= ReaderDisplaySettings.fontSizeRange.upperBound)
            .accessibilityLabel("增大字号")
            .accessibilityIdentifier("\(identifierPrefix).increase")
        }
    }
}

#Preview {
    ReaderFontSizeControls(settings: .constant(.default))
        .padding()
}
