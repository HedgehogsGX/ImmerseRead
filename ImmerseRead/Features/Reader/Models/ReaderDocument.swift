import Foundation

/// A reader input that is intentionally independent from the library persistence model.
struct ReaderDocument: Identifiable, Hashable, Sendable {
    let id: UUID
    let title: String
    let fileURL: URL
    let format: BookFormat

    init(id: UUID, title: String, fileURL: URL, format: BookFormat) {
        self.id = id
        self.title = title
        self.fileURL = fileURL
        self.format = format
    }
}
