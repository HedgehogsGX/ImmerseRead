import Foundation

/// Original PDF pages and reflowed characters have different position scales.
/// Keep both bookmarks so consulting the source layout never overwrites the text bookmark.
struct PDFReadingLocation: Codable, Equatable, Sendable {
    var mode: PDFReadingMode
    private(set) var reflowProgress: Double
    private(set) var originalProgress: Double

    init(
        mode: PDFReadingMode = .reflow,
        reflowProgress: Double = 0,
        originalProgress: Double = 0
    ) {
        self.mode = mode
        self.reflowProgress = Self.normalized(reflowProgress)
        self.originalProgress = Self.normalized(originalProgress)
    }

    /// Pre-reflow versions saved only an original-page fraction. Never reinterpret
    /// that value as a character fraction, even when saved location data is damaged.
    static func restore(from data: Data?, legacyOriginalProgress: Double) -> Self {
        guard let data,
              let location = try? JSONDecoder().decode(Self.self, from: data) else {
            return Self(originalProgress: legacyOriginalProgress)
        }
        return location
    }

    func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }

    func progress(for mode: PDFReadingMode) -> Double {
        switch mode {
        case .reflow:
            reflowProgress
        case .original:
            originalProgress
        }
    }

    /// Updating a bookmark does not change the selected mode. In particular, a
    /// callback from a disappearing reader must not select that reader again.
    mutating func updateProgress(_ value: Double, for mode: PDFReadingMode) {
        switch mode {
        case .reflow:
            reflowProgress = Self.normalized(value)
        case .original:
            originalProgress = Self.normalized(value)
        }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        guard version == Self.currentVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .version,
                in: container,
                debugDescription: "Unsupported PDF reading location version: \(version)"
            )
        }
        self.init(
            mode: try container.decode(PDFReadingMode.self, forKey: .mode),
            reflowProgress: try container.decode(Double.self, forKey: .reflowProgress),
            originalProgress: try container.decode(Double.self, forKey: .originalProgress)
        )
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentVersion, forKey: .version)
        try container.encode(mode, forKey: .mode)
        try container.encode(reflowProgress, forKey: .reflowProgress)
        try container.encode(originalProgress, forKey: .originalProgress)
    }

    private static let currentVersion = 1

    private static func normalized(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case mode
        case reflowProgress
        case originalProgress
    }
}
