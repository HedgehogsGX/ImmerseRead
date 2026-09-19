import Foundation

struct LibraryBookPresentation: Identifiable, Hashable {
    let id: UUID
    let title: String
    let author: String?
    let format: BookFormat
    let progress: Double
    let activityLabel: String
    let storedRelativePath: String
    let fileByteCount: Int64
    let coverURL: URL?
    let coverStyle: BookCoverStyle
    let coverSource: BookCoverSource?
    /// Changes whenever the cover file does, so cached images are reloaded.
    let coverUpdatedAt: Date?

    init(
        id: UUID,
        title: String,
        author: String? = nil,
        format: BookFormat,
        progress: Double,
        activityLabel: String,
        storedRelativePath: String,
        fileByteCount: Int64 = 0,
        coverURL: URL? = nil,
        coverStyle: BookCoverStyle? = nil,
        coverSource: BookCoverSource? = nil,
        coverUpdatedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.format = format
        self.progress = progress
        self.activityLabel = activityLabel
        self.storedRelativePath = storedRelativePath
        self.fileByteCount = fileByteCount
        self.coverURL = coverURL
        self.coverStyle = coverStyle
            ?? BookCoverStyle.automatic(for: "\(title)|\(author ?? "")")
        self.coverSource = coverSource
        self.coverUpdatedAt = coverUpdatedAt
    }

    var formatLabel: String {
        format.shortLabel
    }

    var normalizedProgress: Double {
        min(max(progress, 0), 1)
    }

    var progressLabel: String {
        normalizedProgress.formatted(.percent.precision(.fractionLength(0)))
    }

    var hasStarted: Bool {
        normalizedProgress > 0.001
    }

    var isFinished: Bool {
        normalizedProgress >= 0.999
    }

    /// Reading is under way: worth offering at the top of the shelf.
    var isInProgress: Bool {
        hasStarted && !isFinished
    }

    var statusLabel: String {
        if isFinished {
            return String(localized: "已读完")
        }
        return hasStarted
            ? String(localized: "已读 \(progressLabel)")
            : String(localized: "尚未开始")
    }

    var sizeLabel: String {
        fileByteCount > 0
            ? fileByteCount.formatted(.byteCount(style: .file))
            : format.displayName
    }

    /// Cache key for the decoded cover image, and the identity the shelf
    /// reloads on: it has to change when the file is replaced *and* when the
    /// stored cover finishes resolving to a URL.
    var coverIdentity: String {
        guard coverURL != nil else {
            return "\(id.uuidString)-none"
        }
        let version = coverUpdatedAt?.timeIntervalSinceReferenceDate ?? 0
        return "\(id.uuidString)-\(Int(version))"
    }

    var accessibilityLabel: String {
        let authorLabel = author.map { "，\($0)" } ?? ""
        return String(localized: "\(title)\(authorLabel)，\(formatLabel)，\(statusLabel)，\(activityLabel)")
    }
}
