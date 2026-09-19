import Foundation

/// Stores content derived from a book's original file (extracted PDF text,
/// converted DOCX blocks) next to that file, so reopening a book skips the
/// expensive derivation.
///
/// Entries live in the book's own folder, so deleting or reconciling a book
/// removes them too. They are excluded from backups because they can always be
/// rebuilt. A cache miss or any I/O failure simply means deriving again.
actor ReaderContentCache {
    struct Key: Hashable, Sendable {
        let kind: String
        let version: Int

        var filename: String {
            "\(kind).v\(version).json"
        }

        fileprivate var filenamePrefix: String {
            "\(kind).v"
        }
    }

    private let directoryForDocument: @Sendable (ReaderDocument) -> URL
    private let fileManager = FileManager.default

    init(
        directoryForDocument: @escaping @Sendable (ReaderDocument) -> URL = {
            $0.fileURL.deletingLastPathComponent()
        }
    ) {
        self.directoryForDocument = directoryForDocument
    }

    func load<Payload: Codable & Sendable>(
        _ type: Payload.Type,
        key: Key,
        for document: ReaderDocument
    ) -> Payload? {
        guard let fingerprint = try? Fingerprint(of: document.fileURL) else {
            return nil
        }
        let cacheURL = directoryForDocument(document).appendingPathComponent(key.filename)
        guard let data = try? Data(contentsOf: cacheURL, options: .mappedIfSafe),
              let envelope = try? JSONDecoder().decode(Envelope<Payload>.self, from: data),
              envelope.fingerprint == fingerprint
        else {
            return nil
        }
        return envelope.payload
    }

    func store<Payload: Codable & Sendable>(
        _ payload: Payload,
        key: Key,
        for document: ReaderDocument
    ) {
        guard let fingerprint = try? Fingerprint(of: document.fileURL) else {
            return
        }
        let envelope = Envelope(fingerprint: fingerprint, payload: payload)
        guard let data = try? JSONEncoder().encode(envelope) else {
            return
        }

        let directory = directoryForDocument(document)
        var cacheURL = directory.appendingPathComponent(key.filename)
        do {
            try data.write(to: cacheURL, options: .atomic)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try cacheURL.setResourceValues(values)
        } catch {
            try? fileManager.removeItem(at: cacheURL)
            return
        }
        removeEntries(supersededBy: key, in: directory)
    }

    /// Raising a derivation's version makes its earlier files unreadable, and a
    /// book's whole text can sit in one of them. Drop them once the replacement
    /// is safely on disk.
    private func removeEntries(supersededBy key: Key, in directory: URL) {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        for entry in entries where entry.lastPathComponent != key.filename
            && entry.lastPathComponent.hasPrefix(key.filenamePrefix)
            && entry.pathExtension == "json" {
            try? fileManager.removeItem(at: entry)
        }
    }

    /// Byte count and modification date of the source file. Stored originals are
    /// never rewritten, so a matching fingerprint means the derivation still applies.
    /// Read through FileManager: URL resource values are cached per URL instance and
    /// would report a replaced file's old attributes.
    private struct Fingerprint: Codable, Equatable {
        let byteCount: Int64
        let modificationDate: Date

        init(of fileURL: URL) throws {
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            guard let byteCount = attributes[.size] as? NSNumber,
                  let modificationDate = attributes[.modificationDate] as? Date else {
                throw CocoaError(.fileReadUnknown)
            }
            self.byteCount = byteCount.int64Value
            self.modificationDate = modificationDate
        }
    }

    private struct Envelope<Payload: Codable>: Codable {
        let fingerprint: Fingerprint
        let payload: Payload
    }
}
