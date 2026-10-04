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
    /// Kept alongside the width rather than assumed: an A4 document is 842
    /// points tall, and writing it back as 792 would quietly turn it into a
    /// sheet that exists in neither standard.
    var paperHeight: CGFloat = 792
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
            if size.height > 100 { paperHeight = size.height }
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
/// Word documents go through `DocxWriter`, which writes the package itself and
/// keeps what AppKit's own Office Open XML writer drops — tables, links, real
/// lists, highlighting, pictures — and carries an original's headers and
/// footers across. Everything else goes through AppKit: Rich Text and RTFD
/// round-trip perfectly, HTML and OpenDocument well, and Word 97–2004 just
/// well enough to be worth offering as an export.
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
            "Save as .docx, .rtf, .odt, .html, or .txt instead."
        }
    }

    /// Extensions a document opened from can be saved straight back into.
    ///
    /// `.doc` is writable but deliberately not here: macOS's Word 97 writer
    /// loses lists, links, and pictures, so a `.doc` saves as a `.docx` copy
    /// unless that's asked for by name. Templates and macro-enabled documents
    /// save as copies too — writing a template's contents over it would turn it
    /// into a document, and the macros can't be written at all.
    static let writableExtensions = ["docx", "rtf", "rtfd", "odt", "html", "txt"]

    static func canWrite(_ url: URL) -> Bool {
        writableExtensions.contains(url.pathExtension.lowercased())
    }

    // MARK: - What a format can't carry

    /// Names the things that won't survive writing `attributed` to `url`.
    ///
    /// Word, Rich Text with images, and RTFD keep everything the editor can
    /// hold. The formats that go through AppKit's writers each drop something,
    /// and it's worth saying what before a save quietly simplifies a document.
    static func losses(writing attributed: NSAttributedString, to url: URL) -> [String] {
        switch documentType(for: url) {
        case .plain:
            return ["all formatting"]
        case .rtf:
            // RTF the format can carry images; AppKit's RTF *writer* can't.
            // RTFD — the bundle form — can, which is what to steer towards.
            return hasAttachment(attributed) ? ["images"] : []
        case .openDocument:
            return hasAttachment(attributed) ? ["images"] : []
        case .docFormat:
            var losses: [String] = []
            if contains(attributed, where: { !$0.textLists.isEmpty }) { losses.append("numbered lists") }
            if hasLink(attributed) { losses.append("links") }
            if hasAttachment(attributed) { losses.append("images") }
            return losses
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
        case "doc": .docFormat
        case "odt": .openDocument
        case "rtf": .rtf
        case "rtfd": .rtfd
        case "html", "htm": .html
        case "txt", "text", "md", "markdown": .plain
        default: nil
        }
    }

    /// Writes `attributed` to `url`, carrying the page geometry through so the
    /// saved file keeps the paper size and margins it was opened with.
    ///
    /// `source` is the file the document was opened from; when that's a Word
    /// document and this is a Word save, its headers and footers come along.
    static func write(
        _ attributed: NSAttributedString,
        to url: URL,
        layout: PageLayout,
        documentAttributes: [NSAttributedString.DocumentAttributeKey: Any] = [:],
        source: URL? = nil
    ) throws {
        guard let type = documentType(for: url) else {
            throw WriteError.unsupported(url.pathExtension.lowercased())
        }

        if type == .officeOpenXML {
            try DocxWriter.write(
                attributed,
                to: url,
                layout: layout,
                documentAttributes: documentAttributes,
                carryingPartsFrom: source
            )
            return
        }

        let range = NSRange(location: 0, length: attributed.length)
        var attributes = documentAttributes
        attributes[.documentType] = type
        attributes[.paperSize] = NSValue(size: NSSize(width: layout.paperWidth, height: layout.paperHeight))
        attributes[.leftMargin] = NSNumber(value: Double(layout.leftMargin))
        attributes[.rightMargin] = NSNumber(value: Double(layout.rightMargin))
        attributes[.topMargin] = NSNumber(value: Double(layout.topMargin))
        attributes[.bottomMargin] = NSNumber(value: Double(layout.bottomMargin))

        if type == .rtfd {
            let wrapper = try attributed.fileWrapper(from: range, documentAttributes: attributes)
            try SafeFileWriter.write(to: url) { try wrapper.write(to: $0, options: [], originalContentsURL: nil) }
            return
        }

        let data = try attributed.data(from: range, documentAttributes: attributes)
        try SafeFileWriter.write(data, to: url)
    }
}
