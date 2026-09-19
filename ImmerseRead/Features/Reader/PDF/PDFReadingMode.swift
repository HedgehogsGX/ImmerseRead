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
}
