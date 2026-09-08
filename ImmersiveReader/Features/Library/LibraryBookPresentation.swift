import Foundation

struct LibraryBookPresentation: Identifiable, Hashable {
    let id: UUID
    let title: String
    let formatLabel: String
    let progress: Double
    let activityLabel: String
    let storedRelativePath: String

    var normalizedProgress: Double {
        min(max(progress, 0), 1)
    }

    var progressLabel: String {
        normalizedProgress.formatted(.percent.precision(.fractionLength(0)))
    }

    var accessibilityLabel: String {
        "\(title)，\(formatLabel)，已读 \(progressLabel)，\(activityLabel)"
    }
}
