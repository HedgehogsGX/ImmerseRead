import Foundation

/// A platform-independent sRGB color that can cross the extraction worker boundary.
struct ReaderTextColor: Hashable, Sendable {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = Self.clamped(red, fallback: 0)
        self.green = Self.clamped(green, fallback: 0)
        self.blue = Self.clamped(blue, fallback: 0)
        self.alpha = Self.clamped(alpha, fallback: 1)
    }

    private static func clamped(_ value: Double, fallback: Double) -> Double {
        guard !value.isNaN else { return fallback }
        return min(max(value, 0), 1)
    }
}

/// Ranges use UTF-16 offsets, like PDFKit and NSAttributedString, not Character counts.
struct ReaderTextStyleSpan: Hashable, Sendable {
    let range: NSRange
    let color: ReaderTextColor
}

struct ReaderStyledText: Hashable, Sendable {
    let text: String
    let styles: [ReaderTextStyleSpan]
}
