import Foundation

struct BookMetadata: Equatable, Sendable {
    let title: String?
    let author: String?
    let coverData: Data?
    /// How `coverData` was obtained; `.generated` whenever there is no picture.
    let coverSource: BookCoverSource

    init(
        title: String? = nil,
        author: String? = nil,
        coverData: Data? = nil,
        coverSource: BookCoverSource = .embedded
    ) {
        self.title = title
        self.author = author
        self.coverData = coverData
        self.coverSource = coverData == nil ? .generated : coverSource
    }
}
