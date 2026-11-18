import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A validated, downsampled avatar held in memory until the profile is saved. The original
/// photo is never retained and no Photos URL or identifier is ever stored.
struct PreparedAvatar: Equatable, Sendable {
    /// Square JPEG, at most `ProfileAvatarProcessor.fullPixels` on a side.
    let full: Data
    /// Square JPEG, at most `ProfileAvatarProcessor.thumbnailPixels` on a side, for compact controls.
    let thumbnail: Data
}

enum ProfileAvatarProcessor {
    /// Bounds the bytes accepted from the photo picker (large enough for ProRAW stills).
    static let maximumInputBytes = 50 * 1_048_576
    /// Bounds declared source dimensions before any decoding happens.
    static let maximumSourceSide = 20_000
    static let maximumSourcePixels = 150_000_000
    static let fullPixels = 512
    static let thumbnailPixels = 128

    /// Validates `data` as a decodable image and produces centre-cropped square JPEGs.
    /// ImageIO's thumbnailer decodes at reduced size, so the full-resolution bitmap is never
    /// materialized.
    static func prepare(_ data: Data, maximumSourceSide: Int = ProfileAvatarProcessor.maximumSourceSide, maximumSourcePixels: Int = ProfileAvatarProcessor.maximumSourcePixels) throws -> PreparedAvatar {
        guard !data.isEmpty else { throw LocalProfileError.invalidImage }
        guard data.count <= maximumInputBytes else { throw LocalProfileError.imageTooLarge }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source) as String?,
              UTType(type)?.conforms(to: .image) == true,
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        else { throw LocalProfileError.invalidImage }
        guard width > 0, height > 0, width <= maximumSourceSide, height <= maximumSourceSide,
              width.multipliedReportingOverflow(by: height).partialValue <= maximumSourcePixels
        else { throw LocalProfileError.unsupportedImageDimensions }
        return PreparedAvatar(full: try square(source, width: width, height: height, side: fullPixels),
                              thumbnail: try square(source, width: width, height: height, side: thumbnailPixels))
    }

    private static func square(_ source: CGImageSource, width: Int, height: Int, side: Int) throws -> Data {
        // Downsample so the shorter edge is at least `side`, then centre-crop to a square.
        let shorter = max(1, min(width, height)), longer = max(width, height)
        // One extra pixel so rounding never leaves the shorter edge below `side`.
        let target = max(side, Int((Double(side) * Double(longer) / Double(shorter)).rounded(.up)) + 1)
        guard let scaled = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: min(target, Self.maximumSourceSide)
        ] as CFDictionary) else { throw LocalProfileError.invalidImage }
        let edge = min(scaled.width, scaled.height)
        guard edge > 0, let cropped = scaled.cropping(to: CGRect(x: (scaled.width - edge) / 2, y: (scaled.height - edge) / 2, width: edge, height: edge))
        else { throw LocalProfileError.invalidImage }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { throw LocalProfileError.invalidImage }
        // A newly encoded CGImage carries no source metadata such as location.
        CGImageDestinationAddImage(destination, cropped, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw LocalProfileError.invalidImage }
        if edge <= side { return output as Data }
        // The thumbnailer rounds; re-encode once more at exactly `side` if it overshot.
        guard let resized = CGImageSourceCreateWithData(output as CFData, nil),
              let final = CGImageSourceCreateThumbnailAtIndex(resized, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: side] as CFDictionary)
        else { throw LocalProfileError.invalidImage }
        let exact = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(exact, UTType.jpeg.identifier as CFString, 1, nil) else { throw LocalProfileError.invalidImage }
        CGImageDestinationAddImage(destination, final, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw LocalProfileError.invalidImage }
        return exact as Data
    }
}
