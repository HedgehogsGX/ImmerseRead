import Foundation

struct ReaderTextSourceMap: Hashable, Codable, Sendable {
    let legacyRanges: [NSRange]
    let blockRanges: [NSRange]

    init(source: String, blocks: [ReaderSemanticBlock]) {
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n") as NSString
        var legacyRanges: [NSRange] = []
        var paragraphStart: Int?
        var paragraphEnd = 0
        var offset = 0
        for line in (normalized as String).components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                if let start = paragraphStart {
                    legacyRanges.append(NSRange(location: start, length: paragraphEnd - start))
                    paragraphStart = nil
                }
            } else {
                let range = (line as NSString).range(of: trimmed)
                if paragraphStart == nil { paragraphStart = offset + range.location }
                paragraphEnd = offset + NSMaxRange(range)
            }
            offset += line.utf16.count + 1
        }
        if let start = paragraphStart {
            legacyRanges.append(NSRange(location: start, length: paragraphEnd - start))
        }
        self.legacyRanges = legacyRanges

        var cursor = 0
        blockRanges = blocks.map { block in
            let range = normalized.range(of: block.text, options: .literal,
                                         range: NSRange(location: cursor, length: normalized.length - cursor))
            guard range.location != NSNotFound else { return NSRange(location: cursor, length: 0) }
            cursor = NSMaxRange(range)
            return range
        }
    }

    func migrate(_ anchor: ReaderTextAnchor) -> ReaderTextAnchor? {
        guard legacyRanges.indices.contains(anchor.blockIndex), !blockRanges.isEmpty else { return nil }
        let legacy = legacyRanges[anchor.blockIndex]
        let sourceOffset = legacy.location + min(anchor.offsetInBlock, legacy.length)
        let index = blockRanges.lastIndex { $0.location <= sourceOffset } ?? 0
        let range = blockRanges[index]
        return ReaderTextAnchor(blockIndex: index, offsetInBlock: min(max(0, sourceOffset - range.location), range.length))
    }
}
