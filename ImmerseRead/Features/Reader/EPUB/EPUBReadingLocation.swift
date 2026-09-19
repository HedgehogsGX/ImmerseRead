import Foundation

/// Persisted reading position for EPUB books: the navigator's exact Readium
/// `Locator` as JSON, plus the coarse fraction shown on the shelf.
struct EPUBReadingLocation: Codable, Equatable, Sendable {
    let locatorJSON: String
    let progress: Double

    init(locatorJSON: String, progress: Double) {
        self.locatorJSON = locatorJSON
        self.progress = progress.clampedToUnitInterval
    }

    static func restore(from data: Data?) -> Self? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        guard version == Self.currentVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .version,
                in: container,
                debugDescription: "Unsupported EPUB reading location version: \(version)"
            )
        }
        self.init(
            locatorJSON: try container.decode(String.self, forKey: .locatorJSON),
            progress: try container.decode(Double.self, forKey: .progress)
        )
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentVersion, forKey: .version)
        try container.encode(locatorJSON, forKey: .locatorJSON)
        try container.encode(progress, forKey: .progress)
    }

    private static let currentVersion = 1

    private enum CodingKeys: String, CodingKey {
        case version
        case locatorJSON
        case progress
    }
}
