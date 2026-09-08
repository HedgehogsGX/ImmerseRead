import Foundation
import ReadiumZIPFoundation

struct ArchiveSafetyLimits: Equatable, Sendable {
    var maximumEntryCount = 20_000
    var maximumExpandedByteCount: UInt64 = 512 * 1_024 * 1_024
    var maximumCompressionRatio: UInt64 = 250
}

struct ArchiveSafetyValidator: Sendable {
    private let limits: ArchiveSafetyLimits

    init(limits: ArchiveSafetyLimits = ArchiveSafetyLimits()) {
        self.limits = limits
    }

    func validate(at fileURL: URL, as format: BookFormat) async throws {
        guard format == .epub || format == .docx else {
            return
        }

        let archive: Archive
        do {
            archive = try await Archive(url: fileURL, accessMode: .read)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw BookImportError.invalidArchive(expectedFormat: format)
        }

        let entries: [Entry]
        do {
            entries = try await archive.entries()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw BookImportError.invalidArchive(expectedFormat: format)
        }

        guard !entries.isEmpty else {
            throw BookImportError.invalidArchive(expectedFormat: format)
        }
        guard entries.count <= limits.maximumEntryCount else {
            throw BookImportError.unsafeArchive(
                description: "压缩包包含过多文件（上限为 \(limits.maximumEntryCount) 个）。"
            )
        }

        var expandedByteCount: UInt64 = 0
        var normalizedPaths = Set<String>()
        var pathIdentities = Set<String>()

        for entry in entries {
            try Task.checkCancellation()
            let normalizedPath = try validatePath(entry.path)
            let pathIdentity = normalizedPath
                .precomposedStringWithCanonicalMapping
                .lowercased()
            guard pathIdentities.insert(pathIdentity).inserted else {
                throw BookImportError.unsafeArchive(
                    description: "压缩包包含重复路径：\(entry.path)"
                )
            }
            normalizedPaths.insert(normalizedPath)

            guard entry.type != .symlink else {
                throw BookImportError.unsafeArchive(
                    description: "压缩包包含不支持的符号链接：\(entry.path)"
                )
            }

            let (newExpandedByteCount, overflowed) = expandedByteCount
                .addingReportingOverflow(entry.uncompressedSize)
            guard !overflowed,
                  newExpandedByteCount <= limits.maximumExpandedByteCount
            else {
                throw BookImportError.unsafeArchive(
                    description: "解压后的内容超过 \(limits.maximumExpandedByteCount) 字节上限。"
                )
            }
            expandedByteCount = newExpandedByteCount

            guard isCompressionRatioAllowed(for: entry) else {
                throw BookImportError.unsafeArchive(
                    description: "压缩条目膨胀比例异常：\(entry.path)"
                )
            }
        }

        let requiredPaths: Set<String>
        switch format {
        case .epub:
            requiredPaths = ["META-INF/container.xml"]
        case .docx:
            requiredPaths = ["[Content_Types].xml", "word/document.xml"]
        case .pdf, .plainText, .markdown, .legacyWord:
            requiredPaths = []
        }

        guard requiredPaths.isSubset(of: normalizedPaths) else {
            throw BookImportError.invalidArchive(expectedFormat: format)
        }

        if format == .epub {
            try await validateEPUBMimetype(in: archive, entries: entries)
        }
    }

    private func validatePath(_ rawPath: String) throws -> String {
        let normalizedPath = rawPath.replacingOccurrences(of: "\\", with: "/")
        let components = normalizedPath.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        let hasWindowsDrivePrefix = normalizedPath.range(
            of: #"^[A-Za-z]:/"#,
            options: .regularExpression
        ) != nil
        let containsControlCharacter = normalizedPath.unicodeScalars.contains {
            $0.value < 0x20 || $0.value == 0x7F
        }
        let containsEmptyInteriorComponent = components.dropLast().contains(where: \.isEmpty)

        guard !normalizedPath.isEmpty,
              !normalizedPath.hasPrefix("/"),
              !hasWindowsDrivePrefix,
              !containsControlCharacter,
              !containsEmptyInteriorComponent,
              !components.contains(where: { $0 == ".." || $0 == "." })
        else {
            throw BookImportError.unsafeArchive(
                description: "压缩包包含不安全路径：\(rawPath)"
            )
        }

        return normalizedPath
    }

    private func isCompressionRatioAllowed(for entry: Entry) -> Bool {
        guard entry.type == .file, entry.uncompressedSize > 1 * 1_024 * 1_024 else {
            return true
        }
        guard entry.compressedSize > 0 else {
            return false
        }
        return entry.uncompressedSize / entry.compressedSize <= limits.maximumCompressionRatio
    }

    private func validateEPUBMimetype(
        in archive: Archive,
        entries: [Entry]
    ) async throws {
        let expectedMimetype = Data("application/epub+zip".utf8)
        guard let mimetypeEntry = entries.first,
              mimetypeEntry.path == "mimetype",
              mimetypeEntry.type == .file,
              !mimetypeEntry.isCompressed,
              mimetypeEntry.uncompressedSize == UInt64(expectedMimetype.count)
        else {
            throw BookImportError.invalidArchive(expectedFormat: .epub)
        }

        let collector = ArchiveDataCollector()
        do {
            _ = try await archive.extract(mimetypeEntry) { chunk in
                await collector.append(chunk)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw BookImportError.invalidArchive(expectedFormat: .epub)
        }

        guard await collector.value == expectedMimetype else {
            throw BookImportError.invalidArchive(expectedFormat: .epub)
        }
    }
}

private actor ArchiveDataCollector {
    private(set) var value = Data()

    func append(_ chunk: Data) {
        value.append(chunk)
    }
}
