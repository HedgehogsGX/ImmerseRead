import CoreGraphics
import Foundation
import ImageIO
import UIKit

/// Decodes stored covers off the main actor and keeps the shelf's worth of them
/// in memory, so scrolling never re-reads the same file.
///
/// Entries are keyed by the book's cover identity, which changes whenever the
/// cover does; a replaced cover therefore misses the cache instead of needing
/// to be evicted.
@MainActor
final class CoverImageLoader {
    static let shared = CoverImageLoader()

    private let cache = NSCache<NSString, UIImage>()

    init(countLimit: Int = 120) {
        cache.countLimit = countLimit
    }

    func cachedImage(identity: String) -> UIImage? {
        cache.object(forKey: identity as NSString)
    }

    func image(identity: String, at url: URL, targetPixelWidth: CGFloat) async -> UIImage? {
        if let cached = cachedImage(identity: identity) {
            return cached
        }

        let pixelWidth = max(64, targetPixelWidth.rounded())
        let decoded = await Task.detached(priority: .userInitiated) {
            CoverImageLoader.decode(at: url, targetPixelWidth: pixelWidth)
        }.value

        guard let decoded, !Task.isCancelled else {
            return nil
        }
        cache.setObject(decoded, forKey: identity as NSString)
        return decoded
    }

    private nonisolated static func decode(at url: URL, targetPixelWidth: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0
        else {
            return nil
        }

        // Covers are stored at 2:3, so the longest edge follows the width.
        let maximumPixelSize = Int((targetPixelWidth / CoverArtwork.aspectRatio).rounded())
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maximumPixelSize),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ) else {
            return nil
        }
        return UIImage(cgImage: image)
    }
}
