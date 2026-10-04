import AppKit
import PDFKit
import Vision

/// Reads text out of pixels — a scanned PDF page, a photographed receipt, a
/// screenshot — with the Vision framework, on the device.
///
/// The first choice is `RecognizeDocumentsRequest`, new in macOS 26, because it
/// understands a page as a document rather than as a pile of lines: it returns
/// paragraphs in reading order, which is what lets a two-column scan come out as
/// two columns of prose instead of every line interleaved with its neighbour,
/// and it names the title. Plain line recognition is kept as the fallback for
/// anything the document model can't make sense of.
enum TextRecognizer {
    struct Paragraph: Sendable, Equatable {
        let text: String
        let isTitle: Bool
    }

    /// Recognises the text in `image`, as paragraphs in reading order.
    ///
    /// `@concurrent` so the work happens off the main actor whoever calls it:
    /// a page takes a second or so, and a scanned book takes minutes.
    @concurrent
    static func paragraphs(in image: CGImage) async throws -> [Paragraph] {
        if let structured = try? await documentParagraphs(in: image), !structured.isEmpty {
            return structured
        }
        return try await lineParagraphs(in: image)
    }

    private static func documentParagraphs(in image: CGImage) async throws -> [Paragraph] {
        var request = RecognizeDocumentsRequest()
        request.textRecognitionOptions.useLanguageCorrection = true
        request.textRecognitionOptions.automaticallyDetectLanguage = true

        var paragraphs: [Paragraph] = []
        for observation in try await request.perform(on: image) {
            let title = observation.document.title?.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            var titleUsed = false
            for paragraph in observation.document.paragraphs {
                let text = paragraph.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                // The title comes back as a paragraph too; mark it rather than
                // add it twice.
                let isTitle = !titleUsed && text == title
                if isTitle { titleUsed = true }
                paragraphs.append(Paragraph(text: text, isTitle: isTitle))
            }
        }
        return paragraphs
    }

    private static func lineParagraphs(in image: CGImage) async throws -> [Paragraph] {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true

        // Vision's coordinates run up from the bottom, so the top of the page
        // is the largest y.
        return try await request.perform(on: image)
            .sorted { $0.boundingBox.origin.y + $0.boundingBox.height > $1.boundingBox.origin.y + $1.boundingBox.height }
            .compactMap { $0.topCandidates(1).first?.string }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { Paragraph(text: $0, isTitle: false) }
    }

    // MARK: - Formatting the result

    /// Recognised paragraphs as a formatted document: Helvetica, because it's on
    /// every Mac and every copy of Word maps it, and a bold heading where Vision
    /// found a title.
    static func attributedText(from paragraphs: [Paragraph]) -> NSAttributedString {
        let body = NSFont(name: "Helvetica", size: 12) ?? .systemFont(ofSize: 12)
        let heading = NSFont(name: "Helvetica-Bold", size: 18) ?? .boldSystemFont(ofSize: 18)
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = 8

        let result = NSMutableAttributedString()
        for (index, paragraph) in paragraphs.enumerated() {
            let text = paragraph.text + (index < paragraphs.count - 1 ? "\n" : "")
            result.append(NSAttributedString(string: text, attributes: [
                .font: paragraph.isTitle ? heading : body,
                .foregroundColor: NSColor.black,
                .paragraphStyle: style,
            ]))
        }
        return result
    }

    // MARK: - Pages as pictures

    /// True when a page has no text layer worth the name — what a scanner or a
    /// phone camera produces.
    @MainActor
    static func needsRecognition(_ page: PDFPage) -> Bool {
        (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The longest side, in pixels, a page is rendered at for recognition. Twice
    /// a Letter page's height is plenty for body text; a poster-sized page is
    /// scaled down to this rather than allocated at hundreds of megapixels.
    private static let maximumPixels: CGFloat = 4000

    /// Renders a page as Vision will see it: upright, on white, at about twice
    /// its printed size.
    ///
    /// On the main actor because `PDFDocument` isn't safe to touch from two
    /// threads at once. Drawing a page takes a few tens of milliseconds; it's
    /// the recognition afterwards that's slow, and that's what runs elsewhere.
    @MainActor
    static func image(of page: PDFPage, scale preferred: CGFloat = 2) -> CGImage? {
        let box = page.bounds(for: .cropBox)
        let quarterTurn = (page.rotation / 90) % 2 != 0
        let size = quarterTurn ? CGSize(width: box.height, height: box.width) : box.size
        guard size.width > 0, size.height > 0 else { return nil }

        let scale = min(preferred, maximumPixels / max(size.width, size.height))
        let width = Int((size.width * scale).rounded())
        let height = Int((size.height * scale).rounded())
        guard width > 0, height > 0,
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              )
        else { return nil }

        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        // `draw(with:to:)` applies the page's own rotation and crop offset, so
        // a page scanned sideways and rotated upright in the file is read
        // upright here too.
        page.draw(with: .cropBox, to: context)
        return context.makeImage()
    }
}
