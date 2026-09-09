import Foundation

/// A position in reflowable text that survives typography changes and renderer
/// updates: the semantic block plus a UTF-16 offset into that block's rendered text.
struct ReaderTextAnchor: Codable, Hashable, Sendable {
    let blockIndex: Int
    let offsetInBlock: Int

    init(blockIndex: Int, offsetInBlock: Int) {
        self.blockIndex = max(0, blockIndex)
        self.offsetInBlock = max(0, offsetInBlock)
    }
}

/// Persisted reading position for TXT, Markdown and DOCX books.
///
/// `progress` is the shelf's coarse fraction; `anchor` is what the reader
/// actually reopens at.
struct TextReadingLocation: Codable, Equatable, Sendable {
    let anchor: ReaderTextAnchor
    let progress: Double

    init(anchor: ReaderTextAnchor, progress: Double) {
        self.anchor = anchor
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
                debugDescription: "Unsupported text reading location version: \(version)"
            )
        }
        self.init(
            anchor: try container.decode(ReaderTextAnchor.self, forKey: .anchor),
            progress: try container.decode(Double.self, forKey: .progress)
        )
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentVersion, forKey: .version)
        try container.encode(anchor, forKey: .anchor)
        try container.encode(progress, forKey: .progress)
    }

    private static let currentVersion = 1

    private enum CodingKeys: String, CodingKey {
        case version
        case anchor
        case progress
    }
}
