import SwiftUI
import UIKit

struct ReaderDisplaySettings: Hashable, Sendable {
    var layoutMode: ReaderLayoutMode = .paged
    var fontSize: Double = 19
    var lineHeightMultiple: Double = 1.55
    var fontFamily: ReaderFontFamily = .system
    var margin: Double = 20
    var theme: ReaderTheme = .system

    static let `default` = Self()
    static let fontSizeRange = 14.0 ... 40.0
    static let lineHeightRange = 1.2 ... 2.0
    static let marginRange = 12.0 ... 48.0

    var epubPageMargins: Double {
        margin.clamped(to: Self.marginRange) / Self.default.margin
    }

    mutating func adjustFontSize(by step: Double) {
        let currentSize = fontSize.isFinite ? fontSize : Self.default.fontSize
        fontSize = min(max(currentSize + step, Self.fontSizeRange.lowerBound), Self.fontSizeRange.upperBound)
    }

    mutating func resetTypography() {
        fontSize = Self.default.fontSize
        lineHeightMultiple = Self.default.lineHeightMultiple
        fontFamily = Self.default.fontFamily
        margin = Self.default.margin
    }
}

enum ReaderFontFamily: String, CaseIterable, Hashable, Sendable, Identifiable {
    case system
    case serif
    case sansSerif
    case monospace

    var id: Self { self }

    var title: String {
        switch self {
        case .system:
            String(localized: "系统")
        case .serif:
            String(localized: "衬线")
        case .sansSerif:
            String(localized: "无衬线")
        case .monospace:
            String(localized: "等宽")
        }
    }

    var readiumRawValue: String {
        switch self {
        case .system, .sansSerif:
            "sans-serif"
        case .serif:
            "serif"
        case .monospace:
            "monospace"
        }
    }

    @MainActor
    func font(ofSize size: CGFloat, weight: UIFont.Weight = .regular, italic: Bool = false) -> UIFont {
        let familyName: String?
        switch self {
        case .system:
            return italic ? .italicSystemFont(ofSize: size) : .systemFont(ofSize: size, weight: weight)
        case .serif:
            familyName = "Georgia"
        case .sansSerif:
            familyName = "Helvetica Neue"
        case .monospace:
            return .monospacedSystemFont(ofSize: size, weight: weight)
        }

        guard let familyName,
              let base = UIFont(name: familyName, size: size) else {
            return italic ? .italicSystemFont(ofSize: size) : .systemFont(ofSize: size, weight: weight)
        }
        var traits = base.fontDescriptor.symbolicTraits
        if weight.rawValue >= UIFont.Weight.bold.rawValue {
            traits.insert(.traitBold)
        }
        if italic {
            traits.insert(.traitItalic)
        }
        guard let descriptor = base.fontDescriptor.withSymbolicTraits(traits) else {
            return base
        }
        return UIFont(descriptor: descriptor, size: size)
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        guard isFinite else {
            return range.lowerBound
        }
        return min(max(self, range.lowerBound), range.upperBound)
    }
}

enum ReaderLayoutMode: String, CaseIterable, Hashable, Sendable, Identifiable {
    case paged
    case scrolling

    var id: Self { self }

    var title: String {
        switch self {
        case .paged:
            String(localized: "分页")
        case .scrolling:
            String(localized: "滚动")
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

    /// The way of reading the reader lands in when the switch is tapped.
    var toggled: Self {
        switch self {
        case .paged:
            .scrolling
        case .scrolling:
            .paged
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
            String(localized: "跟随系统")
        case .light:
            String(localized: "浅色")
        case .sepia:
            String(localized: "米色")
        case .dark:
            String(localized: "深色")
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
