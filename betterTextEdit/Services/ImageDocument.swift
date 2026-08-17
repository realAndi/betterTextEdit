import AppKit
import ImageIO
import UniformTypeIdentifiers

/// A decoded image, ready to look at.
///
/// Everything comes from ImageIO, which is why the awkward formats need no
/// special handling: WebP, HEIC, AVIF, and camera RAW are all decoded by the
/// system, and animation is just a source with more than one frame. The frames
/// of a GIF, an animated WebP, or an APNG all arrive the same way, each with the
/// delay the file asked for.
struct ImageDocument {
    struct Frame {
        let image: NSImage
        /// Seconds this frame is shown for.
        let delay: Double
    }

    var frames: [Frame]
    var pixelSize: CGSize
    var formatName: String
    var byteCount: Int
    var colorModel: String?
    var bitDepth: Int?
    var hasAlpha: Bool

    var isAnimated: Bool { frames.count > 1 }

    /// Very long animations are truncated rather than held in memory whole.
    static let maximumFrames = 512

    var summary: String {
        var parts = ["\(Int(pixelSize.width)) × \(Int(pixelSize.height))"]
        parts.append(formatName)
        if let colorModel {
            parts.append(bitDepth.map { "\(colorModel) \($0)-bit" } ?? colorModel)
        }
        if hasAlpha { parts.append("alpha") }
        parts.append(ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file))
        return parts.joined(separator: " · ")
    }
}

enum ImageLoader {
    enum LoadError: LocalizedError {
        case undecodable(String)

        var errorDescription: String? {
            switch self {
            case let .undecodable(name): "betterTextEdit can’t decode this \(name)."
            }
        }

        var recoverySuggestion: String? {
            "The file may be damaged, or use a variant macOS doesn’t support."
        }
    }

    /// True for anything ImageIO is prepared to decode.
    ///
    /// Asking the type system rather than keeping a list of extensions is what
    /// makes the long tail work: every camera RAW variant conforms to
    /// `public.camera-raw-image`, and new formats arrive with the OS.
    static func handles(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        // SVG is a picture, but it's also text — and editing the source is the
        // more useful thing for an editor to offer.
        guard type != .svg else { return false }
        return type.conforms(to: .image) || type.conforms(to: .rawImage)
    }

    static func load(_ url: URL) throws -> ImageDocument {
        let options: [CFString: Any] = [kCGImageSourceShouldCache: true]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options as CFDictionary),
              CGImageSourceGetCount(source) > 0
        else {
            throw LoadError.undecodable(formatName(for: url, source: nil))
        }

        let count = min(CGImageSourceGetCount(source), ImageDocument.maximumFrames)
        var frames: [ImageDocument.Frame] = []
        frames.reserveCapacity(count)

        for index in 0 ..< count {
            guard let cgImage = CGImageSourceCreateImageAtIndex(source, index, options as CFDictionary) else { continue }
            let size = NSSize(width: cgImage.width, height: cgImage.height)
            frames.append(
                ImageDocument.Frame(
                    image: NSImage(cgImage: cgImage, size: size),
                    delay: delay(of: source, at: index)
                )
            )
        }

        guard let first = frames.first else {
            throw LoadError.undecodable(formatName(for: url, source: source))
        }

        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let byteCount = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0

        return ImageDocument(
            frames: frames,
            pixelSize: first.image.size,
            formatName: formatName(for: url, source: source),
            byteCount: byteCount,
            colorModel: (properties[kCGImagePropertyColorModel] as? String),
            bitDepth: (properties[kCGImagePropertyDepth] as? Int),
            hasAlpha: (properties[kCGImagePropertyHasAlpha] as? Bool) ?? false
        )
    }

    /// Per-frame delay, which each animated format records in its own dictionary.
    private static func delay(of source: CGImageSource, at index: Int) -> Double {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]

        let containers: [CFString] = [
            kCGImagePropertyGIFDictionary,
            kCGImagePropertyPNGDictionary,
            kCGImagePropertyWebPDictionary,
            kCGImagePropertyHEICSDictionary,
        ]

        for key in containers {
            guard let dictionary = properties[key] as? [CFString: Any] else { continue }
            let unclamped = dictionary[kCGImagePropertyGIFUnclampedDelayTime] as? Double
                ?? dictionary[kCGImagePropertyAPNGUnclampedDelayTime] as? Double
                ?? dictionary[kCGImagePropertyWebPUnclampedDelayTime] as? Double
            let clamped = dictionary[kCGImagePropertyGIFDelayTime] as? Double
                ?? dictionary[kCGImagePropertyAPNGDelayTime] as? Double
                ?? dictionary[kCGImagePropertyWebPDelayTime] as? Double

            if let value = unclamped ?? clamped, value > 0 {
                // Browsers floor very short delays, and so does everything that
                // wants a 50fps GIF to look the way its author saw it.
                return max(value, 0.02)
            }
        }
        return 0.1
    }

    private static func formatName(for url: URL, source: CGImageSource?) -> String {
        if let identifier = source.flatMap(CGImageSourceGetType) as? String,
           let type = UTType(identifier),
           let description = type.localizedDescription
        {
            return description
        }
        return url.pathExtension.uppercased() + " image"
    }
}
