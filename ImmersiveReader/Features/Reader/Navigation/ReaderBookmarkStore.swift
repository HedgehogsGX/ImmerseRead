import Foundation

struct ReaderBookmarkStore: Sendable {
    static let `default` = ReaderBookmarkStore()

    let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? Self.defaultDirectory()
    }

    func load(documentID: UUID) -> [ReaderBookmark] {
        guard let data = try? Data(contentsOf: fileURL(for: documentID)),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.version == Payload.currentVersion else {
            return []
        }
        return payload.bookmarks.filter { $0.documentID == documentID }
    }

    func save(_ bookmarks: [ReaderBookmark], documentID: UUID) throws {
        let file = fileURL(for: documentID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(Payload(bookmarks: bookmarks))
        try data.write(to: file, options: .atomic)
    }

    func fileURL(for documentID: UUID) -> URL {
        directory.appendingPathComponent("\(documentID.uuidString).json")
    }

    private static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("ImmersiveReader/ReaderBookmarks", isDirectory: true)
    }
}

private extension ReaderBookmarkStore {
    struct Payload: Codable {
        static let currentVersion = 1
        let version: Int
        let bookmarks: [ReaderBookmark]

        init(bookmarks: [ReaderBookmark]) {
            version = Self.currentVersion
            self.bookmarks = bookmarks
        }
    }
}
