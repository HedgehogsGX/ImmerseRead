import Foundation

/// Gathers the chunks a ZIP entry is streamed in, for the few entries the app
/// reads whole (an EPUB mimetype, DOCX properties, a cover picture).
actor ArchiveDataCollector {
    private(set) var value = Data()

    func append(_ chunk: Data) {
        value.append(chunk)
    }
}
