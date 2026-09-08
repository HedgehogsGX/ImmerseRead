import SwiftUI

struct ReaderDisplaySettings: Hashable, Sendable {
    var layoutMode: ReaderLayoutMode = .paged
    var fontSize: Double = 19
    var lineHeightMultiple: Double = 1.55
    var theme: ReaderTheme = .system

    static let `default` = Self()
    static let fontSizeRange = 14.0 ... 40.0
    static let lineHeightRange = 1.2 ... 2.0

    mutating func adjustFontSize(by step: Double) {
        let currentSize = fontSize.isFinite ? fontSize : Self.default.fontSize
        fontSize = min(max(currentSize + step, Self.fontSizeRange.lowerBound), Self.fontSizeRange.upperBound)
    }

    mutating func resetTypography() {
        fontSize = Self.default.fontSize
        lineHeightMultiple = Self.default.lineHeightMultiple
    }
}

enum ReaderLayoutMode: String, CaseIterable, Hashable, Sendable, Identifiable {
    case paged
    case scrolling

    var id: Self { self }

    var title: String {
        switch self {
        case .paged:
            "分页"
        case .scrolling:
            "滚动"
        }
    }

    var systemImage: String {
        switch self {
        case .paged:
            "book.pages"
        case .scrolling:
            "scroll"
        }
    }
}

enum ReaderTheme: String, CaseIterable, Hashable, Sendable, Identifiable {
    case system
    case light
    case sepia
    case dark

    var id: Self { self }

    var title: String {
        switch self {
        case .system:
            "跟随系统"
        case .light:
            "浅色"
        case .sepia:
            "米色"
        case .dark:
            "深色"
        }
    }

    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system:
            nil
        case .light, .sepia:
            .light
        case .dark:
            .dark
        }
    }

    var backgroundColor: Color {
        switch self {
        case .system:
            Color(uiColor: .systemBackground)
        case .light:
            .white
        case .sepia:
            Color(red: 0.96, green: 0.92, blue: 0.82)
        case .dark:
            Color(red: 0.08, green: 0.08, blue: 0.09)
        }
    }

    var textColor: UIColor {
        switch self {
        case .system:
            .label
        case .light:
            .black
        case .sepia:
            UIColor(red: 0.24, green: 0.19, blue: 0.13, alpha: 1)
        case .dark:
            UIColor(white: 0.9, alpha: 1)
        }
    }
}
