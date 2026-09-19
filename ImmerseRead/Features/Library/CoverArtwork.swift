import SwiftUI
import UIKit

/// A book's cover: the picture the document carries or the reader chose, and
/// lettering built from the title when there is no picture at all.
struct CoverArtwork: View {
    nonisolated static let aspectRatio: CGFloat = 2.0 / 3.0

    let title: String
    let author: String?
    let formatLabel: String
    let style: BookCoverStyle
    var image: UIImage?
    var cornerRadius: CGFloat = 14

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width

            ZStack {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    lettering(width: width)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
            }
        }
        .aspectRatio(Self.aspectRatio, contentMode: .fit)
        .accessibilityHidden(true)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    private var palette: CoverPalette {
        CoverPalette(style: style)
    }

    private func lettering(width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(
                colors: [palette.top, palette.bottom],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RadialGradient(
                colors: [.white.opacity(0.22), .clear],
                center: UnitPoint(x: 0.12, y: 0.02),
                startRadius: 0,
                endRadius: width * 1.1
            )

            // A darker strip on the binding edge, so a shelf of lettering
            // covers still reads as a shelf of books.
            HStack(spacing: 0) {
                Rectangle()
                    .fill(.black.opacity(0.2))
                    .frame(width: max(3, width * 0.05))
                Rectangle()
                    .fill(.white.opacity(0.12))
                    .frame(width: max(0.5, width * 0.006))
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: width * 0.035) {
                HStack {
                    Spacer(minLength: 0)
                    Text(formatLabel.uppercased())
                        .font(.system(size: max(8, width * 0.062), weight: .bold))
                        .tracking(0.6)
                        .padding(.horizontal, width * 0.05)
                        .padding(.vertical, width * 0.025)
                        .background(palette.ink.opacity(0.16), in: Capsule())
                }

                Spacer(minLength: width * 0.06)

                Rectangle()
                    .frame(width: width * 0.26, height: max(1, width * 0.012))
                    .opacity(0.55)

                Text(title)
                    .font(.system(size: width * 0.135, weight: .semibold, design: .serif))
                    .lineSpacing(width * 0.02)
                    .lineLimit(4)
                    .minimumScaleFactor(0.55)

                if let author, !author.isEmpty {
                    Text(author)
                        .font(.system(size: width * 0.072, weight: .medium, design: .serif))
                        .opacity(0.78)
                        .lineLimit(1)
                }
            }
            .foregroundStyle(palette.ink)
            .padding(.leading, width * 0.15)
            .padding(.trailing, width * 0.1)
            .padding(.vertical, width * 0.1)
        }
    }
}

struct CoverPalette {
    let top: Color
    let bottom: Color
    /// Lettering colour, dark on the light palettes.
    let ink: Color
    /// Used for the shelf's progress bar, so it agrees with the cover.
    let accent: Color

    init(style: BookCoverStyle) {
        switch style {
        case .midnight:
            self.init(top: 0x3A4C7A, bottom: 0x141C34, ink: .white, accent: .indigo)
        case .forest:
            self.init(top: 0x2F5D4B, bottom: 0x12271F, ink: .white, accent: .teal)
        case .clay:
            self.init(top: 0xA85A38, bottom: 0x4A2117, ink: .white, accent: .orange)
        case .plum:
            self.init(top: 0x6B3F73, bottom: 0x2E1734, ink: .white, accent: .purple)
        case .sand:
            self.init(top: 0xE4CE9C, bottom: 0xBE9A5C, ink: Color(hex: 0x3A2E16), accent: .brown)
        case .ocean:
            self.init(top: 0x2C6C7E, bottom: 0x0F2A33, ink: .white, accent: .cyan)
        case .rose:
            self.init(top: 0xA8475C, bottom: 0x4A1724, ink: .white, accent: .pink)
        case .graphite:
            self.init(top: 0x5A5F66, bottom: 0x24272B, ink: .white, accent: .gray)
        }
    }

    private init(top: UInt32, bottom: UInt32, ink: Color, accent: Color) {
        self.top = Color(hex: top)
        self.bottom = Color(hex: bottom)
        self.ink = ink
        self.accent = accent
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

#Preview("Lettering covers") {
    ScrollView {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 16)], spacing: 16) {
            ForEach(BookCoverStyle.allCases) { style in
                CoverArtwork(
                    title: "瓦尔登湖",
                    author: "亨利·戴维·梭罗",
                    formatLabel: "EPUB",
                    style: style
                )
            }
        }
        .padding()
    }
}
