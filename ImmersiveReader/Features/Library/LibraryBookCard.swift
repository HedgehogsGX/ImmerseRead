import SwiftUI
import UIKit

/// A book's cover at whatever size the shelf needs, loading the stored picture
/// in the background and falling back to lettering.
struct LibraryBookCover: View {
    let book: LibraryBookPresentation
    var cornerRadius: CGFloat = 14
    /// Point width the cover is drawn at, used to size the decode.
    var targetWidth: CGFloat = 180

    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    var body: some View {
        CoverArtwork(
            title: book.title,
            author: book.author,
            formatLabel: book.formatLabel,
            style: book.coverStyle,
            image: image,
            cornerRadius: cornerRadius
        )
        .task(id: book.coverIdentity) {
            await loadImage()
        }
    }

    private func loadImage() async {
        guard let coverURL = book.coverURL else {
            image = nil
            return
        }

        if let cached = CoverImageLoader.shared.cachedImage(identity: book.coverIdentity) {
            image = cached
            return
        }

        image = nil
        let loaded = await CoverImageLoader.shared.image(
            identity: book.coverIdentity,
            at: coverURL,
            targetPixelWidth: targetWidth * displayScale
        )
        guard !Task.isCancelled else {
            return
        }
        image = loaded
    }
}

struct LibraryBookCard: View {
    let book: LibraryBookPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LibraryBookCover(book: book)
                .shadow(color: .black.opacity(0.2), radius: 10, x: 0, y: 6)

            VStack(alignment: .leading, spacing: 3) {
                Text(book.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)

                Text(book.author ?? book.activityLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            LibraryProgressIndicator(book: book)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(book.accessibilityLabel)
        .accessibilityHint("轻点开始阅读。长按可更换封面或删除。")
        .accessibilityIdentifier("library.book.\(book.id.uuidString)")
    }
}

struct LibraryBookRow: View {
    let book: LibraryBookPresentation

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            LibraryBookCover(book: book, cornerRadius: 8, targetWidth: 56)
                .frame(width: 56)
                .shadow(color: .black.opacity(0.16), radius: 5, x: 0, y: 3)

            VStack(alignment: .leading, spacing: 5) {
                Text(book.title)
                    .font(.body.weight(.medium))
                    .lineLimit(2)

                Text(book.author ?? book.activityLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                LibraryProgressIndicator(book: book)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(book.accessibilityLabel)
        .accessibilityHint("轻点开始阅读。长按可更换封面或删除。")
        .accessibilityIdentifier("library.book.\(book.id.uuidString)")
    }
}

/// The most recently opened book that is neither untouched nor finished.
struct LibraryContinueReadingCard: View {
    let book: LibraryBookPresentation

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            LibraryBookCover(book: book, cornerRadius: 10, targetWidth: 76)
                .frame(width: 76)
                .shadow(color: .black.opacity(0.22), radius: 10, x: 0, y: 6)

            VStack(alignment: .leading, spacing: 6) {
                Text("继续阅读")
                    .font(.caption2.weight(.semibold))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)

                Text(book.title)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)

                Text(book.author ?? book.activityLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                LibraryProgressIndicator(book: book)
                    .padding(.top, 2)
                    // Keeps the bar readable instead of stretching it across
                    // the whole width of an iPad.
                    .frame(maxWidth: 360, alignment: .leading)
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.forward")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(16)
        .background(
            Color(uiColor: .secondarySystemBackground),
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "继续阅读 \(book.accessibilityLabel)"))
        .accessibilityIdentifier("library.continue.\(book.id.uuidString)")
    }
}

struct LibraryProgressIndicator: View {
    let book: LibraryBookPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.1))

                    Capsule()
                        .fill(accent)
                        .frame(
                            width: book.hasStarted
                                ? max(4, proxy.size.width * book.normalizedProgress)
                                : 0
                        )
                }
            }
            .frame(height: 4)

            Text(book.statusLabel)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .accessibilityHidden(true)
    }

    private var accent: Color {
        book.isFinished ? .secondary : CoverPalette(style: book.coverStyle).accent
    }
}

#Preview("Shelf pieces") {
    ScrollView {
        VStack(alignment: .leading, spacing: 24) {
            LibraryContinueReadingCard(book: LibraryBookPresentation.previews[0])

            HStack(alignment: .top, spacing: 20) {
                ForEach(LibraryBookPresentation.previews) { book in
                    LibraryBookCard(book: book)
                        .frame(width: 150)
                }
            }

            ForEach(LibraryBookPresentation.previews) { book in
                LibraryBookRow(book: book)
            }
        }
        .padding()
    }
}
