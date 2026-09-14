import Foundation

/// Where a shelf cover came from.
///
/// Persisted on `Book`, so a missing value means the document was imported
/// before covers were detected and still deserves one pass of detection.
enum BookCoverSource: String, CaseIterable, Codable, Hashable, Sendable {
    /// A picture the document itself carries (EPUB cover, DOCX thumbnail or figure).
    case embedded
    /// Rendered from the document's own first page.
    case rendered
    /// A picture the reader picked.
    case custom
    /// Detection ran and found nothing usable, so the shelf draws lettering instead.
    case generated

    var title: String {
        switch self {
        case .embedded:
            String(localized: "文件内封面")
        case .rendered:
            String(localized: "首页生成")
        case .custom:
            String(localized: "自定义封面")
        case .generated:
            String(localized: "文字封面")
        }
    }

    /// Whether the app found this cover on its own.
    var isAutomatic: Bool {
        switch self {
        case .embedded, .rendered:
            true
        case .custom, .generated:
            false
        }
    }
}

/// What one pass of cover detection produced for a book already on the shelf.
struct BookCoverDetection: Equatable, Sendable {
    let coverRelativePath: String?
    let source: BookCoverSource

    static let none = Self(coverRelativePath: nil, source: .generated)
}

/// Palette for the lettering cover a book falls back to when it has no picture.
enum BookCoverStyle: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case midnight
    case forest
    case clay
    case plum
    case sand
    case ocean
    case rose
    case graphite

    var id: Self { self }

    var title: String {
        switch self {
        case .midnight:
            String(localized: "午夜蓝")
        case .forest:
            String(localized: "松林绿")
        case .clay:
            String(localized: "陶土橙")
        case .plum:
            String(localized: "梅子紫")
        case .sand:
            String(localized: "暖沙黄")
        case .ocean:
            String(localized: "深海青")
        case .rose:
            String(localized: "玫瑰红")
        case .graphite:
            String(localized: "石墨灰")
        }
    }

    /// A stable pick, so a book keeps the same lettering cover across launches
    /// and across devices without storing anything.
    static func automatic(for seed: String) -> Self {
        let checksum = seed.unicodeScalars.reduce(UInt64(5_381)) { partialResult, scalar in
            partialResult &* 33 &+ UInt64(scalar.value)
        }
        return allCases[Int(checksum % UInt64(allCases.count))]
    }
}
