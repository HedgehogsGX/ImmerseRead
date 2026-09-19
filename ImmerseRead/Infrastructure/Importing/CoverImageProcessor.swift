import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Turns any picture into the small JPEG the shelf stores beside a book.
///
/// Everything runs through ImageIO and Core Graphics, so it stays off the main
/// actor and never keeps a full-size decode in memory.
struct CoverImageProcessor: Sendable {
    static let defaultMaximumPixelSize: CGFloat = 680
    static let defaultMaximumEncodedBytes = 1_500_000
    static let defaultMaximumSourceBytes = 32 * 1_024 * 1_024
    /// Pictures shorter than this on either edge are decoration, not covers.
    static let minimumScavengedEdge: CGFloat = 160

    let maximumPixelSize: CGFloat
    let maximumEncodedBytes: Int
    let maximumSourceBytes: Int

    init(
        maximumPixelSize: CGFloat = CoverImageProcessor.defaultMaximumPixelSize,
        maximumEncodedBytes: Int = CoverImageProcessor.defaultMaximumEncodedBytes,
        maximumSourceBytes: Int = CoverImageProcessor.defaultMaximumSourceBytes
    ) {
        self.maximumPixelSize = max(1, maximumPixelSize)
        self.maximumEncodedBytes = max(1, maximumEncodedBytes)
        self.maximumSourceBytes = max(1, maximumSourceBytes)
    }

    /// - Parameter requiringUsableSize: rejects thumbnails and decorations.
    ///   Pass `true` for a picture scavenged out of a document, never for one
    ///   the document declares as its cover.
    func encodedCover(fromImageData data: Data, requiringUsableSize: Bool = false) -> Data? {
        guard !data.isEmpty, data.count <= maximumSourceBytes else {
            return nil
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0
        else {
            return nil
        }

        if requiringUsableSize {
            guard let size = Self.pixelSize(of: source),
                  min(size.width, size.height) >= Self.minimumScavengedEdge
            else {
                return nil
            }
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maximumPixelSize.rounded()),
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ) else {
            return nil
        }
        return encodedCover(from: thumbnail)
    }

    func encodedCover(from image: CGImage) -> Data? {
        guard var candidate = Self.flattened(image, maximumPixelSize: maximumPixelSize) else {
            return nil
        }

        // Two halvings are enough to bring any cover-sized picture under the
        // budget; giving up keeps a pathological image out of the library.
        for _ in 0 ... 2 {
            for quality in stride(from: 0.85, through: 0.35, by: -0.1) {
                guard let data = Self.jpegData(from: candidate, quality: quality) else {
                    return nil
                }
                if data.count <= maximumEncodedBytes {
                    return data
                }
            }

            let halfEdge = CGFloat(max(candidate.width, candidate.height)) / 2
            guard let smaller = Self.flattened(candidate, maximumPixelSize: halfEdge) else {
                return nil
            }
            candidate = smaller
        }
        return nil
    }

    static func pixelSize(ofImageData data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        return pixelSize(of: source)
    }

    /// Whether a render carries so little contrast that it would look like an
    /// empty card on the shelf, which is what a blank first page produces.
    static func isLikelyBlank(_ image: CGImage) -> Bool {
        let sampleEdge = 48
        guard let context = CGContext(
            data: nil,
            width: sampleEdge,
            height: sampleEdge,
            bitsPerComponent: 8,
            bytesPerRow: sampleEdge,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return false
        }

        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: sampleEdge, height: sampleEdge))
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: sampleEdge, height: sampleEdge))

        guard let pixels = context.data else {
            return false
        }
        let buffer = pixels.bindMemory(to: UInt8.self, capacity: sampleEdge * sampleEdge)
        var darkest = UInt8.max
        var brightest = UInt8.min
        for index in 0 ..< (sampleEdge * sampleEdge) {
            darkest = min(darkest, buffer[index])
            brightest = max(brightest, buffer[index])
        }
        return Int(brightest) - Int(darkest) < 12
    }

    private static func pixelSize(of source: CGImageSource) -> CGSize? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
            as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int
        else {
            return nil
        }
        return CGSize(width: width, height: height)
    }

    /// Redraws onto opaque white at or below `maximumPixelSize`, so a
    /// transparent picture does not turn into a black card once it is JPEG.
    private static func flattened(_ image: CGImage, maximumPixelSize: CGFloat) -> CGImage? {
        let longestEdge = CGFloat(max(image.width, image.height))
        guard longestEdge >= 1, maximumPixelSize >= 1 else {
            return nil
        }
        let scale = min(1, maximumPixelSize / longestEdge)
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            return nil
        }

        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private static func jpegData(from image: CGImage, quality: Double) -> Data? {
        let buffer = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            buffer,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }

        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return buffer as Data
    }
}
