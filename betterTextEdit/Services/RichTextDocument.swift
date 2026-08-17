import AppKit
import Foundation
import UniformTypeIdentifiers

// MARK: - Page layout

/// The page geometry a word-processor document carries with it.
///
/// Word, Rich Text, and OpenDocument files all record a paper size and margins,
/// and AppKit hands them back in the document attributes. Laying the text out at
/// the document's real measure is what makes line breaks — and therefore the
/// whole look of a page — match what Word shows.
struct PageLayout: Equatable {
    var paperWidth: CGFloat = 612 // US Letter at 72 dpi
    var leftMargin: CGFloat = 72
    var rightMargin: CGFloat = 72
    var topMargin: CGFloat = 72
    var bottomMargin: CGFloat = 72

    /// The width text actually flows in.
    var textWidth: CGFloat {
        max(paperWidth - leftMargin - rightMargin, 200)
    }

    init() {}

    init(documentAttributes: [NSAttributedString.DocumentAttributeKey: Any]?) {
        guard let attributes = documentAttributes else { return }

        if let paper = attributes[.paperSize] as? NSValue {
            let size = paper.sizeValue
            if size.width > 100 { paperWidth = size.width }
        }
        if let value = attributes[.leftMargin] as? NSNumber { leftMargin = CGFloat(value.doubleValue) }
        if let value = attributes[.rightMargin] as? NSNumber { rightMargin = CGFloat(value.doubleValue) }
        if let value = attributes[.topMargin] as? NSNumber { topMargin = CGFloat(value.doubleValue) }
        if let value = attributes[.bottomMargin] as? NSNumber { bottomMargin = CGFloat(value.doubleValue) }

        // Guard against files that claim margins wider than the page.
        if leftMargin + rightMargin > paperWidth - 100 {
            leftMargin = 72
            rightMargin = 72
        }
    }
}

// MARK: - Writing

/// Writes formatted text back out in a format other apps can open.
///
/// AppKit can *write* Office Open XML, so a document opened from `.docx`,
/// edited here, and saved goes back to disk as a real `.docx` — Word, Pages, and
/// Google Docs all open the result. The same call handles `.rtf`, `.rtfd`, and
/// `.html`. Formats macOS can only read (`.doc`, `.odt`, `.webarchive`) are
/// saved as `.docx` instead, which is why they open unsaved.
enum RichTextWriter {
    enum WriteError: LocalizedError {
        case unsupported(String)

        var errorDescription: String? {
            switch self {
            case let .unsupported(ext):
                ".\(ext) files can’t be written by macOS."
            }
        }

        var recoverySuggestion: String? {
            "Save as .docx, .rtf, .html, or .txt instead."
        }
    }

    /// Extensions we can write formatting into, best first.
    static let writableExtensions = ["docx", "rtf", "rtfd", "html", "txt"]

    static var savePanelContentTypes: [UTType] {
        let docx = UTType("org.openxmlformats.wordprocessingml.document")
        return [docx, .rtf, .rtfd, .html, .plainText].compactMap { $0 }
    }

    static func canWrite(_ url: URL) -> Bool {
        writableExtensions.contains(url.pathExtension.lowercased())
    }

    // MARK: - What a format can't carry

    /// Names the things that won't survive writing `attributed` to `url`.
    ///
    /// macOS's Office Open XML writer keeps fonts, sizes, colours, styles, and
    /// paragraph spacing, but it flattens tables into plain paragraphs, drops
    /// link destinations, and turns real lists into literal bullet characters.
    /// Rich Text keeps all of it — and Word opens Rich Text — so it's worth
    /// telling the user before a save quietly simplifies their document.
    static func losses(writing attributed: NSAttributedString, to url: URL) -> [String] {
        switch documentType(for: url) {
        case .plain:
            return ["all formatting"]
        case .officeOpenXML:
            var losses: [String] = []
            if contains(attributed, where: { style in
                style.textBlocks.contains { $0 is NSTextTableBlock }
            }) {
                losses.append("tables")
            }
            if hasLink(attributed) {
                losses.append("links")
            }
            if hasAttachment(attributed) {
                losses.append("images")
            }
            return losses
        case .rtf:
            // RTF the format can carry images; AppKit's RTF *writer* can't.
            // RTFD — the bundle form — can, which is what to steer towards.
            return hasAttachment(attributed) ? ["images"] : []
        default:
            return []
        }
    }

    private static func contains(
        _ attributed: NSAttributedString,
        where predicate: (NSParagraphStyle) -> Bool
    ) -> Bool {
        var found = false
        attributed.enumerateAttribute(
            .paragraphStyle,
            in: NSRange(location: 0, length: attributed.length),
            options: []
        ) { value, _, stop in
            if let style = value as? NSParagraphStyle, predicate(style) {
                found = true
                stop.pointee = true
            }
        }
        return found
    }

    private static func hasLink(_ attributed: NSAttributedString) -> Bool {
        has(.link, in: attributed)
    }

    private static func hasAttachment(_ attributed: NSAttributedString) -> Bool {
        has(.attachment, in: attributed)
    }

    private static func has(_ key: NSAttributedString.Key, in attributed: NSAttributedString) -> Bool {
        var found = false
        attributed.enumerateAttribute(
            key,
            in: NSRange(location: 0, length: attributed.length),
            options: []
        ) { value, _, stop in
            if value != nil {
                found = true
                stop.pointee = true
            }
        }
        return found
    }

    private static func documentType(for url: URL) -> NSAttributedString.DocumentType? {
        switch url.pathExtension.lowercased() {
        case "docx": .officeOpenXML
        case "rtf": .rtf
        case "rtfd": .rtfd
        case "html", "htm": .html
        case "txt", "text", "md", "markdown": .plain
        default: nil
        }
    }

    /// Writes `attributed` to `url`, carrying the page geometry through so the
    /// saved file keeps the paper size and margins it was opened with.
    static func write(
        _ attributed: NSAttributedString,
        to url: URL,
        layout: PageLayout,
        documentAttributes: [NSAttributedString.DocumentAttributeKey: Any] = [:]
    ) throws {
        guard let type = documentType(for: url) else {
            throw WriteError.unsupported(url.pathExtension.lowercased())
        }

        let range = NSRange(location: 0, length: attributed.length)
        var attributes = documentAttributes
        attributes[.documentType] = type
        attributes[.paperSize] = NSValue(size: NSSize(width: layout.paperWidth, height: 792))
        attributes[.leftMargin] = NSNumber(value: Double(layout.leftMargin))
        attributes[.rightMargin] = NSNumber(value: Double(layout.rightMargin))
        attributes[.topMargin] = NSNumber(value: Double(layout.topMargin))
        attributes[.bottomMargin] = NSNumber(value: Double(layout.bottomMargin))

        if type == .rtfd {
            let wrapper = try attributed.fileWrapper(from: range, documentAttributes: attributes)
            try wrapper.write(to: url, options: .atomic, originalContentsURL: nil)
            return
        }

        let data = try attributed.data(from: range, documentAttributes: attributes)
        try data.write(to: url, options: .atomic)
    }
}
