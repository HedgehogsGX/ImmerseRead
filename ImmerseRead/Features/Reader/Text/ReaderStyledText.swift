import Foundation

/// A platform-independent sRGB color that can cross the extraction worker boundary.
struct ReaderTextColor: Hashable, Codable, Sendable {
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

extension ReaderTextStyleSpan: Codable {
    private enum CodingKeys: String, CodingKey {
        case location
        case length
        case color
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            range: NSRange(
                location: try container.decode(Int.self, forKey: .location),
                length: try container.decode(Int.self, forKey: .length)
            ),
            color: try container.decode(ReaderTextColor.self, forKey: .color)
        )
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(range.location, forKey: .location)
        try container.encode(range.length, forKey: .length)
        try container.encode(color, forKey: .color)
    }
}

struct ReaderStyledText: Hashable, Codable, Sendable {
    let text: String
    let styles: [ReaderTextStyleSpan]
}
