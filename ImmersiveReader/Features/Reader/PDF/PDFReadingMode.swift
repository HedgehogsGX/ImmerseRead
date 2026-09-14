import Foundation

enum PDFReadingMode: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    case reflow
    case original

    var id: Self { self }

    var title: String {
        switch self {
        case .reflow:
            String(localized: "正文阅读")
        case .original:
            String(localized: "原版式")
        }
    }

    var systemImage: String {
        switch self {
        case .reflow:
            "text.alignleft"
        case .original:
            "doc.richtext"
        }
    }

    /// The mode the reader lands in when the switch is tapped.
    var toggled: Self {
        switch self {
        case .reflow:
            .original
        case .original:
            .reflow
        }
    }
}
