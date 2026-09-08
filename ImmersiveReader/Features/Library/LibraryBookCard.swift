import SwiftUI

struct LibraryBookCard: View {
    let book: LibraryBookPresentation
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            cover

            VStack(alignment: .leading, spacing: 5) {
                Text(book.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2, reservesSpace: true)

                Text(book.activityLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                ProgressView(value: book.normalizedProgress)
                    .tint(palette.accent)
                    .accessibilityHidden(true)

                Text(book.normalizedProgress > 0 ? "已读 \(book.progressLabel)" : "尚未开始")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(.rect)
        .contextMenu {
            Button(role: .destructive, action: onDelete) {
                Label("删除", systemImage: "trash")
            }
                .accessibilityIdentifier("library.delete.\(book.id.uuidString)")
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(book.accessibilityLabel)
        .accessibilityHint("轻点开始阅读。长按可删除。")
        .accessibilityIdentifier("library.book.\(book.id.uuidString)")
    }

    private var cover: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [palette.top, palette.bottom],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.white.opacity(0.18), lineWidth: 1)

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "text.book.closed.fill")
                        .font(.title2)

                    Spacer(minLength: 8)

                    Text(book.formatLabel.uppercased())
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(.black.opacity(0.16), in: Capsule())
                }

                Spacer(minLength: 8)

                Text(book.title)
                    .font(.title3.weight(.semibold))
                    .lineLimit(3)
            }
            .foregroundStyle(.white)
            .padding(16)
        }
        .aspectRatio(0.7, contentMode: .fit)
        .shadow(color: palette.bottom.opacity(0.22), radius: 8, y: 5)
        .accessibilityHidden(true)
    }

    private var palette: CoverPalette {
        CoverPalette.forTitle(book.title)
    }
}

private struct CoverPalette {
    let top: Color
    let bottom: Color
    let accent: Color

    static func forTitle(_ title: String) -> Self {
        let checksum = title.unicodeScalars.reduce(0) { partialResult, scalar in
            partialResult &+ Int(scalar.value)
        }

        let index = Int(UInt(bitPattern: checksum) % UInt(palettes.count))
        return palettes[index]
    }

    private static let palettes: [Self] = [
        .init(top: Color(red: 0.20, green: 0.31, blue: 0.55), bottom: Color(red: 0.09, green: 0.16, blue: 0.31), accent: .indigo),
        .init(top: Color(red: 0.22, green: 0.48, blue: 0.42), bottom: Color(red: 0.08, green: 0.24, blue: 0.22), accent: .teal),
        .init(top: Color(red: 0.64, green: 0.35, blue: 0.25), bottom: Color(red: 0.35, green: 0.15, blue: 0.12), accent: .orange),
        .init(top: Color(red: 0.48, green: 0.31, blue: 0.57), bottom: Color(red: 0.24, green: 0.13, blue: 0.31), accent: .purple),
        .init(top: Color(red: 0.52, green: 0.43, blue: 0.22), bottom: Color(red: 0.28, green: 0.21, blue: 0.08), accent: .yellow)
    ]
}
