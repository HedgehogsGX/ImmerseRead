import CryptoKit
import Foundation

actor BookImportService {
    static let defaultMaximumFileSize = DocumentFileLimits.generalMaximumBytes
    static let coverFilename = "cover.jpg"

    private let explicitLibraryRootURL: URL?
    private let maximumFileSize: Int64
    private let now: @Sendable () -> Date
    private let makeIdentifier: @Sendable () -> UUID
    private let fileManager = FileManager.default
    private let formatDetector = BookFormatDetector()
    private let archiveSafetyValidator = ArchiveSafetyValidator()
    private let coverImageProcessor = CoverImageProcessor()
    private var sessionImportsByHash: [String: UUID] = [:]

    init(
        libraryRootURL: URL? = nil,
        maximumFileSize: Int64 = BookImportService.defaultMaximumFileSize,
        now: @escaping @Sendable () -> Date = { Date() },
        makeIdentifier: @escaping @Sendable () -> UUID = { UUID() }
    ) {
        explicitLibraryRootURL = libraryRootURL?.standardizedFileURL
        self.maximumFileSize = max(1, maximumFileSize)
        self.now = now
        self.makeIdentifier = makeIdentifier
    }

    func importBook(
        from sourceURL: URL,
        existingContentHashes: Set<String>
    ) async throws -> BookImportResult {
        guard sourceURL.isFileURL else {
            throw BookImportError.sourceMustBeFileURL
        }

        let sourceExtension = sourceURL.pathExtension.lowercased()
        guard let sourceFormat = BookFormat(fileExtension: sourceExtension) else {
            throw BookImportError.unsupportedFormat(fileExtension: sourceExtension)
        }
        let allowedFileSize = min(
            maximumFileSize,
            DocumentFileLimits.maximumImportBytes(for: sourceFormat)
        )

        let didAccessSecurityScopedResource = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didAccessSecurityScopedResource {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let sourceValues: URLResourceValues
        do {
            sourceValues = try sourceURL.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
            ])
        } catch {
            throw BookImportError.sourceUnavailable
        }

        guard sourceValues.isSymbolicLink != true else {
            throw BookImportError.symbolicLinksAreNotSupported
        }
        guard sourceValues.isRegularFile == true else {
            throw BookImportError.sourceIsNotRegularFile
        }

        let sourceByteCount = Int64(sourceValues.fileSize ?? 0)
        guard sourceByteCount > 0 else {
            throw BookImportError.emptyFile
        }
        guard sourceByteCount <= allowedFileSize else {
            throw BookImportError.fileTooLarge(
                actualBytes: sourceByteCount,
                maximumBytes: allowedFileSize
            )
        }

        let libraryRootURL = try resolveLibraryRootURL()
        do {
            try fileManager.createDirectory(
                at: libraryRootURL,
                withIntermediateDirectories: true
            )
        } catch {
            throw storageFailure(from: error)
        }

        let bookID = try nextAvailableBookIdentifier(in: libraryRootURL)
        let storedFilename = "original.\(sourceFormat.preferredFileExtension)"
        let stagingDirectoryURL = libraryRootURL
            .appendingPathComponent(".import-\(UUID().uuidString)", isDirectory: true)
        let stagedOriginalURL = stagingDirectoryURL.appendingPathComponent(storedFilename)
        let finalDirectoryURL = libraryRootURL
            .appendingPathComponent(bookID.uuidString, isDirectory: true)

        let copiedFile: BoundedFileCopyResult
        do {
            try fileManager.createDirectory(
                at: stagingDirectoryURL,
                withIntermediateDirectories: false
            )
            copiedFile = try BoundedFileCopier.copy(
                from: sourceURL,
                to: stagedOriginalURL,
                maximumBytes: allowedFileSize
            )
        } catch let error as BookImportError {
            try? fileManager.removeItem(at: stagingDirectoryURL)
            throw error
        } catch is CancellationError {
            try? fileManager.removeItem(at: stagingDirectoryURL)
            throw CancellationError()
        } catch {
            try? fileManager.removeItem(at: stagingDirectoryURL)
            throw storageFailure(from: error)
        }

        do {
            let copiedValues = try stagedOriginalURL.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
            ])
            guard copiedValues.isSymbolicLink != true else {
                throw BookImportError.symbolicLinksAreNotSupported
            }
            guard copiedValues.isRegularFile == true else {
                throw BookImportError.sourceIsNotRegularFile
            }

            let copiedByteCount = Int64(copiedValues.fileSize ?? 0)
            guard copiedByteCount > 0 else {
                throw BookImportError.emptyFile
            }
            guard copiedByteCount == copiedFile.byteCount else {
                throw BookImportError.sourceUnavailable
            }
            guard copiedByteCount <= allowedFileSize else {
                throw BookImportError.fileTooLarge(
                    actualBytes: copiedByteCount,
                    maximumBytes: allowedFileSize
                )
            }

            let detection = try formatDetector.detectFormat(
                at: stagedOriginalURL,
                suggestedFileExtension: sourceExtension
            )
            try await archiveSafetyValidator.validate(
                at: stagedOriginalURL,
                as: detection.format
            )
            try Task.checkCancellation()
            let contentHash = copiedFile.contentHash

            guard !existingContentHashes.contains(contentHash),
                  sessionImportsByHash[contentHash] == nil
            else {
                throw BookImportError.duplicate(contentHash: contentHash)
            }

            let metadataExtractor = await MainActor.run { BookMetadataExtractor() }
            let metadata = await metadataExtractor.extract(
                from: stagedOriginalURL,
                format: detection.format
            )
            try Task.checkCancellation()
            let coverRelativePath = persistCover(
                metadata.coverData,
                for: bookID,
                in: stagingDirectoryURL
            )
            let coverSource: BookCoverSource = coverRelativePath == nil
                ? .generated
                : metadata.coverSource

            try fileManager.moveItem(at: stagingDirectoryURL, to: finalDirectoryURL)
            sessionImportsByHash[contentHash] = bookID

            return BookImportResult(
                id: bookID,
                title: metadata.title ?? Self.makeTitle(from: sourceURL),
                author: metadata.author,
                originalFilename: sourceURL.lastPathComponent,
                format: detection.format,
                textEncoding: detection.textEncoding,
                storedRelativePath: "\(bookID.uuidString)/\(storedFilename)",
                coverRelativePath: coverRelativePath,
                coverSource: coverSource,
                contentHash: contentHash,
                fileByteCount: copiedByteCount,
                importedAt: now()
            )
        } catch let error as BookImportError {
            try? fileManager.removeItem(at: stagingDirectoryURL)
            throw error
        } catch is CancellationError {
            try? fileManager.removeItem(at: stagingDirectoryURL)
            throw CancellationError()
        } catch {
            try? fileManager.removeItem(at: stagingDirectoryURL)
            throw storageFailure(from: error)
        }
    }

    func storedFileURL(for relativePath: String) throws -> URL {
        let (bookID, storedFilename) = try validateOriginalPath(relativePath)
        return try existingStoredFileURL(bookID: bookID, filename: storedFilename)
    }

    func storedCoverURL(for relativePath: String) throws -> URL {
        let (bookID, storedFilename) = try validateStoredPath(
            relativePath,
            baseName: "cover"
        ) { $0 == "jpg" }
        return try existingStoredFileURL(bookID: bookID, filename: storedFilename)
    }

    /// Stores a picture the reader picked, downsized to the shelf's budget.
    func replaceCover(for bookID: UUID, imageData: Data) throws -> String {
        guard let coverData = coverImageProcessor.encodedCover(fromImageData: imageData) else {
            throw BookImportError.unusableCoverImage
        }

        let directoryURL = try existingBookDirectoryURL(for: bookID)
        guard let relativePath = persistCover(coverData, for: bookID, in: directoryURL) else {
            throw BookImportError.unusableCoverImage
        }
        return relativePath
    }

    /// Drops the stored picture so the shelf falls back to lettering.
    func removeCover(for bookID: UUID) throws {
        let coverURL = try resolveLibraryRootURL()
            .appendingPathComponent(bookID.uuidString, isDirectory: true)
            .appendingPathComponent(Self.coverFilename, isDirectory: false)

        guard fileManager.fileExists(atPath: coverURL.path) else {
            return
        }
        do {
            try fileManager.removeItem(at: coverURL)
        } catch {
            throw storageFailure(from: error)
        }
    }

    /// Looks inside the stored document again and keeps whatever cover it finds.
    ///
    /// Used for books imported before the app read covers, and whenever the
    /// reader asks for the document's own cover back.
    func detectCover(
        for bookID: UUID,
        storedRelativePath: String,
        format: BookFormat
    ) async throws -> BookCoverDetection {
        let (pathBookID, storedFilename) = try validateOriginalPath(storedRelativePath)
        guard pathBookID == bookID else {
            throw BookImportError.unsafeStoredPath
        }
        let fileURL = try existingStoredFileURL(bookID: bookID, filename: storedFilename)

        let metadataExtractor = await MainActor.run { BookMetadataExtractor() }
        let metadata = await metadataExtractor.extract(from: fileURL, format: format)
        try Task.checkCancellation()

        guard let coverData = metadata.coverData else {
            try removeCover(for: bookID)
            return .none
        }

        let directoryURL = try existingBookDirectoryURL(for: bookID)
        guard let relativePath = persistCover(coverData, for: bookID, in: directoryURL) else {
            return .none
        }
        return BookCoverDetection(
            coverRelativePath: relativePath,
            source: metadata.coverSource
        )
    }

    func removeStoredFiles(
        for bookID: UUID,
        contentHash: String
    ) throws {
        let directoryURL = try resolveLibraryRootURL()
            .appendingPathComponent(bookID.uuidString, isDirectory: true)

        if fileManager.fileExists(atPath: directoryURL.path) {
            do {
                try fileManager.removeItem(at: directoryURL)
            } catch {
                throw storageFailure(from: error)
            }
        }

        if sessionImportsByHash[contentHash] == bookID {
            sessionImportsByHash.removeValue(forKey: contentHash)
        }
    }

    /// Removes only importer-owned staging folders and UUID book folders that no
    /// longer have a SwiftData record. Unknown files are deliberately preserved.
    func reconcileStorage(validBookIDs: Set<UUID>) throws {
        let libraryRootURL = try resolveLibraryRootURL()
        guard fileManager.fileExists(atPath: libraryRootURL.path) else {
            return
        }

        let entries: [URL]
        do {
            entries = try fileManager.contentsOfDirectory(
                at: libraryRootURL,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: []
            )
        } catch {
            throw storageFailure(from: error)
        }

        for entryURL in entries {
            let name = entryURL.lastPathComponent
            let stagingID = name.hasPrefix(".import-")
                ? UUID(uuidString: String(name.dropFirst(".import-".count)))
                : nil
            let storedBookID = UUID(uuidString: name)
            let isOrphanedBook = storedBookID.map { !validBookIDs.contains($0) } ?? false

            guard stagingID != nil || isOrphanedBook else {
                continue
            }

            do {
                let values = try entryURL.resourceValues(forKeys: [
                    .isDirectoryKey,
                    .isSymbolicLinkKey,
                ])
                guard values.isSymbolicLink == true || values.isDirectory == true else {
                    continue
                }
                try fileManager.removeItem(at: entryURL)
            } catch {
                throw storageFailure(from: error)
            }
        }
    }

    private func resolveLibraryRootURL() throws -> URL {
        if let explicitLibraryRootURL {
            guard explicitLibraryRootURL.isFileURL else {
                throw BookImportError.unsafeStoredPath
            }
            return explicitLibraryRootURL
        }

        do {
            return try fileManager
                .url(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask,
                    appropriateFor: nil,
                    create: true
                )
                .appendingPathComponent("Books", isDirectory: true)
                .standardizedFileURL
        } catch {
            throw storageFailure(from: error)
        }
    }

    private func nextAvailableBookIdentifier(in libraryRootURL: URL) throws -> UUID {
        for _ in 0 ..< 8 {
            let candidate = makeIdentifier()
            let candidateDirectory = libraryRootURL
                .appendingPathComponent(candidate.uuidString, isDirectory: true)
            if !fileManager.fileExists(atPath: candidateDirectory.path) {
                return candidate
            }
        }
        throw BookImportError.identifierCollision
    }

    private func persistCover(
        _ data: Data?,
        for bookID: UUID,
        in directoryURL: URL
    ) -> String? {
        guard let data, !data.isEmpty else {
            return nil
        }

        let coverFilename = Self.coverFilename
        let coverURL = directoryURL.appendingPathComponent(coverFilename)
        do {
            try data.write(to: coverURL, options: .atomic)
            let values = try coverURL.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
            ])
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  values.fileSize == data.count
            else {
                return nil
            }
        } catch {
            return nil
        }
        return "\(bookID.uuidString)/\(coverFilename)"
    }

    private func validateOriginalPath(_ relativePath: String) throws -> (UUID, String) {
        try validateStoredPath(relativePath, baseName: "original") {
            BookFormat(fileExtension: $0) != nil
        }
    }

    private func existingBookDirectoryURL(for bookID: UUID) throws -> URL {
        let directoryURL = try resolveLibraryRootURL()
            .appendingPathComponent(bookID.uuidString, isDirectory: true)

        let values: URLResourceValues
        do {
            values = try directoryURL.resourceValues(forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
            ])
        } catch {
            throw BookImportError.storedFileMissing
        }

        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw BookImportError.storedFileMissing
        }
        return directoryURL
    }

    private func validateStoredPath(
        _ relativePath: String,
        baseName: String,
        extensionIsAllowed: (String) -> Bool
    ) throws -> (UUID, String) {
        let pathComponents = relativePath.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        let storedFilename = String(pathComponents.last ?? "")
        let storedFilenameURL = URL(fileURLWithPath: storedFilename)
        let storedExtension = storedFilenameURL.pathExtension.lowercased()

        guard pathComponents.count == 2,
              let bookID = UUID(uuidString: String(pathComponents[0])),
              storedFilenameURL.deletingPathExtension().lastPathComponent == baseName,
              extensionIsAllowed(storedExtension)
        else {
            throw BookImportError.unsafeStoredPath
        }
        return (bookID, storedFilename)
    }

    private func existingStoredFileURL(bookID: UUID, filename: String) throws -> URL {
        let candidateURL = try resolveLibraryRootURL()
            .appendingPathComponent(bookID.uuidString, isDirectory: true)
            .appendingPathComponent(filename, isDirectory: false)

        let values: URLResourceValues
        do {
            values = try candidateURL.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ])
        } catch {
            throw BookImportError.storedFileMissing
        }

        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw BookImportError.storedFileMissing
        }
        return candidateURL
    }

    private static func makeTitle(from sourceURL: URL) -> String {
        let proposedTitle = sourceURL
            .deletingPathExtension()
            .lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return proposedTitle.isEmpty ? String(localized: "未命名文档") : proposedTitle
    }

    private func storageFailure(from error: Error) -> BookImportError {
        .storageFailure(description: String(describing: error))
    }
}

private struct BoundedFileCopyResult {
    let byteCount: Int64
    let contentHash: String
}

private enum BoundedFileCopier {
    private static let chunkSize = 1_024 * 1_024

    static func copy(
        from sourceURL: URL,
        to destinationURL: URL,
        maximumBytes: Int64
    ) throws -> BoundedFileCopyResult {
        let sourceHandle: FileHandle
        do {
            sourceHandle = try FileHandle(forReadingFrom: sourceURL)
        } catch {
            throw BookImportError.sourceUnavailable
        }
        defer { try? sourceHandle.close() }

        guard FileManager.default.createFile(
            atPath: destinationURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw BoundedFileCopyError.couldNotCreateDestination
        }

        let destinationHandle: FileHandle
        do {
            destinationHandle = try FileHandle(forWritingTo: destinationURL)
        } catch {
            throw BoundedFileCopyError.couldNotOpenDestination
        }
        defer { try? destinationHandle.close() }

        var hasher = SHA256()
        var byteCount: Int64 = 0

        while true {
            try Task.checkCancellation()

            let chunk: Data
            do {
                chunk = try sourceHandle.read(upToCount: chunkSize) ?? Data()
            } catch {
                throw BookImportError.sourceUnavailable
            }
            guard !chunk.isEmpty else {
                break
            }

            let (nextByteCount, overflowed) = byteCount
                .addingReportingOverflow(Int64(chunk.count))
            guard !overflowed, nextByteCount <= maximumBytes else {
                throw BookImportError.fileTooLarge(
                    actualBytes: overflowed ? .max : nextByteCount,
                    maximumBytes: maximumBytes
                )
            }

            do {
                try destinationHandle.write(contentsOf: chunk)
            } catch {
                throw BoundedFileCopyError.destinationWriteFailed
            }
            hasher.update(data: chunk)
            byteCount = nextByteCount
        }

        guard byteCount > 0 else {
            throw BookImportError.emptyFile
        }
        do {
            try destinationHandle.synchronize()
        } catch {
            throw BoundedFileCopyError.destinationWriteFailed
        }

        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return BoundedFileCopyResult(byteCount: byteCount, contentHash: digest)
    }
}

private enum BoundedFileCopyError: Error {
    case couldNotCreateDestination
    case couldNotOpenDestination
    case destinationWriteFailed
}
