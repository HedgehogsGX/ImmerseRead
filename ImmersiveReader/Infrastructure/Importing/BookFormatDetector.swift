import Foundation

struct BookFormatDetection: Equatable, Sendable {
    let format: BookFormat
    let textEncoding: BookTextEncoding?
}

struct BookFormatDetector: Sendable {
    private static let pdfSignature = Data("%PDF-".utf8)
    private static let zipSignature = Data([0x50, 0x4B, 0x03, 0x04])
    private static let compoundDocumentSignature = Data([
        0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1,
    ])

    func detectFormat(
        at fileURL: URL,
        suggestedFileExtension: String? = nil
    ) throws -> BookFormatDetection {
        guard fileURL.isFileURL else {
            throw BookImportError.sourceMustBeFileURL
        }

        let fileExtension = (suggestedFileExtension ?? fileURL.pathExtension)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()

        guard let format = BookFormat(fileExtension: fileExtension) else {
            throw BookImportError.unsupportedFormat(fileExtension: fileExtension)
        }

        let resourceValues: URLResourceValues
        do {
            resourceValues = try fileURL.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
            ])
        } catch {
            throw BookImportError.sourceUnavailable
        }

        guard resourceValues.isSymbolicLink != true else {
            throw BookImportError.symbolicLinksAreNotSupported
        }
        guard resourceValues.isRegularFile == true else {
            throw BookImportError.sourceIsNotRegularFile
        }
        guard (resourceValues.fileSize ?? 0) > 0 else {
            throw BookImportError.emptyFile
        }

        if format.isPlainText {
            let encoding = try TextFileValidator.detectAndValidateEncoding(at: fileURL)
            return BookFormatDetection(format: format, textEncoding: encoding)
        }

        let prefix = try readPrefix(from: fileURL, byteCount: 8)
        let expectedSignature: Data
        switch format {
        case .pdf:
            expectedSignature = Self.pdfSignature
        case .epub, .docx:
            expectedSignature = Self.zipSignature
        case .doc:
            expectedSignature = Self.compoundDocumentSignature
        case .txt, .md, .markdown:
            preconditionFailure("Plain text formats are handled before signature validation")
        }

        guard prefix.starts(with: expectedSignature) else {
            throw BookImportError.fileSignatureMismatch(expectedFormat: format)
        }

        return BookFormatDetection(format: format, textEncoding: nil)
    }

    private func readPrefix(from fileURL: URL, byteCount: Int) throws -> Data {
        do {
            let handle = try FileHandle(forReadingFrom: fileURL)
            defer { try? handle.close() }
            return try handle.read(upToCount: byteCount) ?? Data()
        } catch let error as BookImportError {
            throw error
        } catch {
            throw BookImportError.sourceUnavailable
        }
    }
}

private enum TextFileValidator {
    private static let utf8BOM = Data([0xEF, 0xBB, 0xBF])
    private static let utf16LittleEndianBOM = Data([0xFF, 0xFE])
    private static let utf16BigEndianBOM = Data([0xFE, 0xFF])
    private static let chunkSize = 64 * 1_024

    static func detectAndValidateEncoding(at fileURL: URL) throws -> BookTextEncoding {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: fileURL)
        } catch {
            throw BookImportError.sourceUnavailable
        }
        defer { try? handle.close() }

        let prefix: Data
        do {
            prefix = try handle.read(upToCount: 3) ?? Data()
            try handle.seek(toOffset: 0)
        } catch {
            throw BookImportError.sourceUnavailable
        }

        if prefix.starts(with: utf8BOM) {
            try validateUTF8(using: handle, bytesToSkip: utf8BOM.count)
            return .utf8
        }
        if prefix.starts(with: utf16LittleEndianBOM) {
            try validateUTF16(using: handle, bytesToSkip: 2, littleEndian: true)
            return .utf16LittleEndian
        }
        if prefix.starts(with: utf16BigEndianBOM) {
            try validateUTF16(using: handle, bytesToSkip: 2, littleEndian: false)
            return .utf16BigEndian
        }

        try validateUTF8(using: handle, bytesToSkip: 0)
        return .utf8
    }

    private static func validateUTF8(
        using handle: FileHandle,
        bytesToSkip: Int
    ) throws {
        var validator = UTF8StreamValidator()
        var remainingBytesToSkip = bytesToSkip

        do {
            while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
                let bytes = [UInt8](chunk)
                let startIndex = min(remainingBytesToSkip, bytes.count)
                remainingBytesToSkip -= startIndex

                for byte in bytes[startIndex...] {
                    guard validator.consume(byte) else {
                        throw BookImportError.invalidTextEncoding
                    }
                }
            }
        } catch let error as BookImportError {
            throw error
        } catch {
            throw BookImportError.sourceUnavailable
        }

        guard remainingBytesToSkip == 0, validator.isComplete else {
            throw BookImportError.invalidTextEncoding
        }
        guard validator.sawScalar else {
            throw BookImportError.emptyFile
        }
    }

    private static func validateUTF16(
        using handle: FileHandle,
        bytesToSkip: Int,
        littleEndian: Bool
    ) throws {
        var remainingBytesToSkip = bytesToSkip
        var pendingByte: UInt8?
        var pendingHighSurrogate: UInt16?
        var sawScalar = false

        do {
            while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
                let bytes = [UInt8](chunk)
                var index = min(remainingBytesToSkip, bytes.count)
                remainingBytesToSkip -= index

                while index < bytes.count {
                    let firstByte: UInt8
                    if let carriedByte = pendingByte {
                        firstByte = carriedByte
                        pendingByte = nil
                    } else {
                        firstByte = bytes[index]
                        index += 1
                    }

                    guard index < bytes.count else {
                        pendingByte = firstByte
                        break
                    }

                    let secondByte = bytes[index]
                    index += 1
                    let codeUnit: UInt16
                    if littleEndian {
                        codeUnit = UInt16(firstByte) | (UInt16(secondByte) << 8)
                    } else {
                        codeUnit = (UInt16(firstByte) << 8) | UInt16(secondByte)
                    }

                    if let highSurrogate = pendingHighSurrogate {
                        guard (0xDC00 ... 0xDFFF).contains(codeUnit) else {
                            throw BookImportError.invalidTextEncoding
                        }
                        let high = UInt32(highSurrogate - 0xD800)
                        let low = UInt32(codeUnit - 0xDC00)
                        let scalar = 0x1_0000 + (high << 10) + low
                        guard isAllowedTextScalar(scalar) else {
                            throw BookImportError.invalidTextEncoding
                        }
                        pendingHighSurrogate = nil
                        sawScalar = true
                    } else if (0xD800 ... 0xDBFF).contains(codeUnit) {
                        pendingHighSurrogate = codeUnit
                    } else {
                        guard !(0xDC00 ... 0xDFFF).contains(codeUnit) else {
                            throw BookImportError.invalidTextEncoding
                        }
                        guard isAllowedTextScalar(UInt32(codeUnit)) else {
                            throw BookImportError.invalidTextEncoding
                        }
                        sawScalar = true
                    }
                }
            }
        } catch let error as BookImportError {
            throw error
        } catch {
            throw BookImportError.sourceUnavailable
        }

        guard remainingBytesToSkip == 0,
              pendingByte == nil,
              pendingHighSurrogate == nil
        else {
            throw BookImportError.invalidTextEncoding
        }
        guard sawScalar else {
            throw BookImportError.emptyFile
        }
    }

    private static func isAllowedTextScalar(_ scalar: UInt32) -> Bool {
        switch scalar {
        case 0x09, 0x0A, 0x0D:
            true
        case 0x00 ... 0x1F, 0x7F ... 0x9F:
            false
        default:
            true
        }
    }

    private struct UTF8StreamValidator {
        private(set) var sawScalar = false
        private var continuationBytesRemaining = 0
        private var nextContinuationMinimum: UInt8 = 0x80
        private var nextContinuationMaximum: UInt8 = 0xBF
        private var scalarAccumulator: UInt32 = 0

        var isComplete: Bool {
            continuationBytesRemaining == 0
        }

        mutating func consume(_ byte: UInt8) -> Bool {
            if continuationBytesRemaining > 0 {
                guard (nextContinuationMinimum ... nextContinuationMaximum).contains(byte) else {
                    return false
                }

                scalarAccumulator = (scalarAccumulator << 6) | UInt32(byte & 0x3F)
                continuationBytesRemaining -= 1
                nextContinuationMinimum = 0x80
                nextContinuationMaximum = 0xBF

                if continuationBytesRemaining == 0 {
                    guard TextFileValidator.isAllowedTextScalar(scalarAccumulator) else {
                        return false
                    }
                    sawScalar = true
                }
                return true
            }

            switch byte {
            case 0x00 ... 0x7F:
                guard TextFileValidator.isAllowedTextScalar(UInt32(byte)) else {
                    return false
                }
                sawScalar = true
            case 0xC2 ... 0xDF:
                beginScalar(byte: byte, prefixMask: 0x1F, continuationCount: 1)
            case 0xE0:
                beginScalar(byte: byte, prefixMask: 0x0F, continuationCount: 2)
                nextContinuationMinimum = 0xA0
            case 0xE1 ... 0xEC, 0xEE ... 0xEF:
                beginScalar(byte: byte, prefixMask: 0x0F, continuationCount: 2)
            case 0xED:
                beginScalar(byte: byte, prefixMask: 0x0F, continuationCount: 2)
                nextContinuationMaximum = 0x9F
            case 0xF0:
                beginScalar(byte: byte, prefixMask: 0x07, continuationCount: 3)
                nextContinuationMinimum = 0x90
            case 0xF1 ... 0xF3:
                beginScalar(byte: byte, prefixMask: 0x07, continuationCount: 3)
            case 0xF4:
                beginScalar(byte: byte, prefixMask: 0x07, continuationCount: 3)
                nextContinuationMaximum = 0x8F
            default:
                return false
            }

            return true
        }

        private mutating func beginScalar(
            byte: UInt8,
            prefixMask: UInt8,
            continuationCount: Int
        ) {
            scalarAccumulator = UInt32(byte & prefixMask)
            continuationBytesRemaining = continuationCount
            nextContinuationMinimum = 0x80
            nextContinuationMaximum = 0xBF
        }
    }
}
