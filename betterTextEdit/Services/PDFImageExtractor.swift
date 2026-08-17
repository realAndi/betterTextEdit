import AppKit
import CoreGraphics
import PDFKit

/// Pulls the pictures out of a PDF page.
///
/// PDFKit renders images but never hands them over — `PDFPage.attributedString`
/// is text only. The images are image XObjects in the page's resource
/// dictionary, and Core Graphics can reach those: `CGPDFStreamCopyData` returns
/// either ready-made JPEG bytes or raw samples, depending on how the image was
/// filtered.
enum PDFImageExtractor {
    /// Images below this size are almost always rules, bullets, or spacers.
    private static let minimumPixels = 24

    static func images(on page: PDFPage) -> [NSImage] {
        guard let dictionary = page.pageRef?.dictionary else { return [] }

        var resources: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources),
              let resources
        else { return [] }

        let collector = Collector()
        collect(from: resources, into: collector, depth: 0)
        return collector.images
    }

    /// Walks a resource dictionary, and the form XObjects inside it.
    ///
    /// Pictures are often not sitting at the top of a page: anything that draws
    /// through a reusable form — which includes macOS's own PDF printing — nests
    /// them one or more levels down, and a scan that only looks at the page's
    /// own XObjects comes back empty.
    private static func collect(from resources: CGPDFDictionaryRef, into collector: Collector, depth: Int) {
        guard depth < 8 else { return }

        var xobjects: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(resources, "XObject", &xobjects),
              let xobjects
        else { return }

        CGPDFDictionaryApplyFunction(xobjects, { _, object, info in
            guard let info else { return }
            let collector = Unmanaged<Collector>.fromOpaque(info).takeUnretainedValue()

            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(object, .stream, &stream), let stream,
                  let dictionary = CGPDFStreamGetDictionary(stream)
            else { return }

            guard collector.budget > 0 else { return }
            collector.budget -= 1

            var subtype: UnsafePointer<Int8>?
            CGPDFDictionaryGetName(dictionary, "Subtype", &subtype)
            switch subtype.map({ String(cString: $0) }) {
            case "Image":
                if let image = PDFImageExtractor.image(from: stream) {
                    collector.images.append(image)
                }
            case "Form":
                var nested: CGPDFDictionaryRef?
                if CGPDFDictionaryGetDictionary(dictionary, "Resources", &nested), let nested {
                    collector.pendingForms.append(nested)
                }
            default:
                break
            }
        }, Unmanaged.passUnretained(collector).toOpaque())

        let forms = collector.pendingForms
        collector.pendingForms.removeAll()
        for form in forms {
            collect(from: form, into: collector, depth: depth + 1)
        }
    }

    private final class Collector {
        var images: [NSImage] = []
        var pendingForms: [CGPDFDictionaryRef] = []
        /// A form can reference itself. The depth limit bounds how deep that
        /// goes; this bounds how wide, so a hostile file can't fan out forever.
        var budget = 512
    }

    // MARK: - One XObject

    private static func image(from stream: CGPDFStreamRef) -> NSImage? {
        guard let dictionary = CGPDFStreamGetDictionary(stream) else { return nil }

        var subtype: UnsafePointer<Int8>?
        guard CGPDFDictionaryGetName(dictionary, "Subtype", &subtype),
              let subtype, String(cString: subtype) == "Image"
        else { return nil }

        var width = 0 as CGPDFInteger
        var height = 0 as CGPDFInteger
        CGPDFDictionaryGetInteger(dictionary, "Width", &width)
        CGPDFDictionaryGetInteger(dictionary, "Height", &height)
        guard width >= minimumPixels, height >= minimumPixels else { return nil }

        var format = CGPDFDataFormat.raw
        guard let data = CGPDFStreamCopyData(stream, &format) as Data? else { return nil }

        switch format {
        case .jpegEncoded, .JPEG2000:
            // Already a container macOS decodes on its own.
            return NSImage(data: data)
        case .raw:
            return rawImage(data: data, width: Int(width), height: Int(height), dictionary: dictionary)
        @unknown default:
            return NSImage(data: data)
        }
    }

    /// Builds an image from decompressed samples.
    ///
    /// Rather than walk the PDF colour-space object — which can be a name, an
    /// ICC stream, or an indexed palette — the component count is derived from
    /// how many bytes are actually there. That covers the grey and RGB images
    /// that make up nearly all raw PDF bitmaps, and declines the rest instead of
    /// guessing wrong.
    private static func rawImage(
        data: Data,
        width: Int,
        height: Int,
        dictionary: CGPDFDictionaryRef
    ) -> NSImage? {
        var bitsPerComponent = 8 as CGPDFInteger
        CGPDFDictionaryGetInteger(dictionary, "BitsPerComponent", &bitsPerComponent)
        guard bitsPerComponent == 8, width > 0, height > 0 else { return nil }

        let pixels = width * height
        guard pixels > 0, data.count >= pixels else { return nil }

        let components = data.count / pixels
        let space: CGColorSpace
        switch components {
        case 1: space = CGColorSpaceCreateDeviceGray()
        case 3: space = CGColorSpaceCreateDeviceRGB()
        default: return nil
        }

        let bytesPerRow = width * components
        guard data.count >= bytesPerRow * height,
              let provider = CGDataProvider(data: data as CFData)
        else { return nil }

        guard let cgImage = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 8 * components,
            bytesPerRow: bytesPerRow,
            space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        ) else { return nil }

        return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
    }

    // MARK: - Attachments

    /// Wraps an image as a text attachment sized to fit the page.
    static func attachment(for image: NSImage, maxWidth: CGFloat) -> NSTextAttachment? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else { return nil }

        let wrapper = FileWrapper(regularFileWithContents: png)
        wrapper.preferredFilename = "image.png"
        let attachment = NSTextAttachment(fileWrapper: wrapper)

        var size = image.size
        if size.width > maxWidth, size.width > 0 {
            size = NSSize(width: maxWidth, height: size.height * (maxWidth / size.width))
        }
        guard size.width > 0, size.height > 0 else { return attachment }

        attachment.bounds = NSRect(origin: .zero, size: size)
        if let cell = attachment.attachmentCell as? NSTextAttachmentCell {
            cell.image?.size = size
        } else {
            attachment.image = image
        }
        return attachment
    }
}
