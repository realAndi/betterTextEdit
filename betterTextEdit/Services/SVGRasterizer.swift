import AppKit

/// Turns an SVG into a PNG.
///
/// SVG opens in betterTextEdit as text — editing the source is the useful thing
/// for a vector drawing — but a flat raster is what most things actually take,
/// so this rasterises the markup on demand. AppKit reads SVG into an `NSImage`
/// on its own, and because that image is resolution-independent it can be drawn
/// into a bitmap at any size and stay crisp: the PNG is re-rendered from the
/// vectors at the chosen scale, not blown up from a cached thumbnail.
enum SVGRasterizer {
    enum RasterError: LocalizedError {
        case notAnImage
        case tooLarge(Int)
        case failed

        var errorDescription: String? {
            switch self {
            case .notAnImage:
                "This doesn’t look like an SVG betterTextEdit can render."
            case let .tooLarge(megapixels):
                "That size comes to \(megapixels) megapixels, which is more than betterTextEdit will render at once."
            case .failed:
                "The PNG couldn’t be created."
            }
        }

        var recoverySuggestion: String? {
            switch self {
            case .notAnImage:
                "Make sure the file is valid SVG — it should start with an <svg> element."
            case .tooLarge:
                "Choose a smaller scale."
            case .failed:
                nil
            }
        }
    }

    /// The most pixels we'll rasterise in one go — a guard against a scale that
    /// would ask for gigabytes of bitmap.
    private static let maximumPixels = 100_000_000 // 100 MP

    /// The SVG's own size in points, read from its `width`/`height` or, failing
    /// that, its `viewBox`. `nil` when AppKit can't make an image of the data at
    /// all, which is the signal that it isn't really SVG.
    @MainActor
    static func naturalSize(of data: Data) -> CGSize? {
        guard let image = NSImage(data: data) else { return nil }
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        return size
    }

    /// Renders `data` to PNG bytes at exactly `pixelSize`.
    @MainActor
    static func png(from data: Data, pixelSize: CGSize) throws -> Data {
        guard let image = NSImage(data: data) else { throw RasterError.notAnImage }

        let width = Int(pixelSize.width.rounded())
        let height = Int(pixelSize.height.rounded())
        guard width > 0, height > 0 else { throw RasterError.notAnImage }
        guard width * height <= maximumPixels else {
            throw RasterError.tooLarge((width * height) / 1_000_000)
        }

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { throw RasterError.failed }

        // One point to one pixel, so the whole bitmap is the drawing.
        rep.size = NSSize(width: width, height: height)

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { throw RasterError.failed }
        context.imageInterpolation = .high
        NSGraphicsContext.current = context
        image.draw(
            in: NSRect(x: 0, y: 0, width: width, height: height),
            from: .zero,
            operation: .copy,
            fraction: 1
        )
        context.flushGraphics()

        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw RasterError.failed
        }
        return png
    }
}

// MARK: - The export panel's scale popup

/// The "Scale:" popup under the PNG export panel.
///
/// SVG has no pixels of its own, so the one thing the export has to be told is
/// how big to make them. This offers the natural size and a few multiples of
/// it, each labelled with the pixels it works out to, the way an image editor's
/// export sheet does.
@MainActor
final class PNGScaleAccessory: NSObject {
    let view: NSView

    private let natural: CGSize
    private let scales: [CGFloat] = [1, 2, 3, 4]
    private var scale: CGFloat
    private let popup = NSPopUpButton(frame: .zero, pullsDown: false)

    /// The pixel dimensions the current scale asks for.
    var pixelSize: CGSize {
        CGSize(width: (natural.width * scale).rounded(), height: (natural.height * scale).rounded())
    }

    init(naturalSize: CGSize, initialScale: CGFloat = 2) {
        natural = naturalSize
        scale = scales.contains(initialScale) ? initialScale : 1

        let label = NSTextField(labelWithString: "Scale:")
        label.alignment = .right

        popup.addItems(withTitles: scales.map { multiplier in
            let width = Int((naturalSize.width * multiplier).rounded())
            let height = Int((naturalSize.height * multiplier).rounded())
            return "\(Int(multiplier))× — \(width) × \(height) px"
        })
        popup.selectItem(at: scales.firstIndex(of: scale) ?? 0)

        let stack = NSStackView(views: [label, popup])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 12, right: 16)
        view = stack

        super.init()
        popup.target = self
        popup.action = #selector(scaleChanged)
    }

    @objc private func scaleChanged() {
        guard scales.indices.contains(popup.indexOfSelectedItem) else { return }
        scale = scales[popup.indexOfSelectedItem]
    }
}
