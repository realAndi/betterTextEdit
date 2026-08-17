import AppKit
import Foundation

/// Puts the pictures back into a Word document.
///
/// macOS's Office Open XML reader ignores `<w:drawing>` completely, so a `.docx`
/// full of photographs arrives as text with nothing where the images were. The
/// pictures are right there in the package — `word/media/…` — so this reads them
/// out and threads them back into the attributed string.
///
/// Placement comes from counting characters: `word/document.xml` is walked in
/// order, accumulating the text inside `<w:t>` runs and a newline per `<w:p>`,
/// and each drawing records how many characters preceded it. That offset lines
/// up with AppKit's own output, which is built from the same runs in the same
/// order. Lists and tables can nudge it — AppKit synthesises bullet and cell
/// text of its own — so offsets are clamped and images land near, not
/// necessarily exactly at, their original spot.
///
/// This is display only. Nothing here can write images back: AppKit's `.docx`
/// writer emits no media parts at all, which is why documents with pictures
/// open unsaved.
enum DocxImages {
    /// Inserts every image found in `url`'s package into `text`.
    /// Returns how many were added.
    @discardableResult
    static func insert(from url: URL, into text: NSMutableAttributedString, maxWidth: CGFloat) -> Int {
        guard let archive = ZipArchive(url: url),
              let documentXML = archive.contents(named: "word/document.xml")
        else { return 0 }

        let document = DrawingParser()
        guard document.parse(documentXML), !document.drawings.isEmpty else { return 0 }

        let relationships = RelationshipParser()
        if let relsXML = archive.contents(named: "word/_rels/document.xml.rels") {
            _ = relationships.parse(relsXML)
        }
        guard !relationships.targets.isEmpty else { return 0 }

        // Insert from the back so earlier offsets stay valid.
        var inserted = 0
        for drawing in document.drawings.sorted(by: { $0.offset > $1.offset }) {
            guard let target = relationships.targets[drawing.relationshipID],
                  let data = archive.contents(named: mediaPath(for: target)),
                  let image = NSImage(data: data)
            else { continue }

            let attachment = attachment(for: image, data: data, target: target, drawing: drawing, maxWidth: maxWidth)
            let offset = min(max(drawing.offset, 0), text.length)
            text.insert(NSAttributedString(attachment: attachment), at: offset)
            inserted += 1
        }
        return inserted
    }

    /// Relationship targets are relative to `word/`, and may point back out of it.
    private static func mediaPath(for target: String) -> String {
        if target.hasPrefix("/") {
            return String(target.dropFirst())
        }
        if target.hasPrefix("../") {
            return String(target.dropFirst(3))
        }
        return "word/" + target
    }

    private static func attachment(
        for image: NSImage,
        data: Data,
        target: String,
        drawing: Drawing,
        maxWidth: CGFloat
    ) -> NSTextAttachment {
        // Carry the file's own bytes rather than a re-encode: setting
        // `attachment.image` would make AppKit rewrite the picture as a PNG,
        // which for a photographed JPEG is both lossy work and much larger.
        let wrapper = FileWrapper(regularFileWithContents: data)
        wrapper.preferredFilename = (target as NSString).lastPathComponent
        let attachment = NSTextAttachment(fileWrapper: wrapper)

        // Word records a display size, which is usually not the pixel size.
        var size = drawing.size == .zero ? image.size : drawing.size
        if size.width > maxWidth, size.width > 0 {
            size = NSSize(width: maxWidth, height: size.height * (maxWidth / size.width))
        }
        guard size.width > 0, size.height > 0 else { return attachment }

        attachment.bounds = NSRect(origin: .zero, size: size)
        if let cell = attachment.attachmentCell as? NSTextAttachmentCell {
            // TextKit 1 lays attachments out through the cell, so this is what
            // actually decides how big the picture draws.
            cell.image?.size = size
        } else {
            attachment.image = image
        }
        return attachment
    }

    // MARK: - document.xml

    fileprivate struct Drawing {
        let offset: Int
        let relationshipID: String
        let size: NSSize
    }

    private final class DrawingParser: NSObject, XMLParserDelegate {
        var drawings: [Drawing] = []

        private var offset = 0
        private var pendingSize: NSSize = .zero
        private var insideTextRun = false

        func parse(_ data: Data) -> Bool {
            let parser = XMLParser(data: data)
            parser.delegate = self
            return parser.parse()
        }

        func parser(
            _: XMLParser,
            didStartElement element: String,
            namespaceURI _: String?,
            qualifiedName _: String?,
            attributes: [String: String]
        ) {
            switch element {
            case "w:t":
                insideTextRun = true

            case "wp:extent":
                // English Metric Units: 914400 to the inch, 72 points to the inch.
                let width = Double(attributes["cx"] ?? "") ?? 0
                let height = Double(attributes["cy"] ?? "") ?? 0
                pendingSize = NSSize(width: width / 12_700, height: height / 12_700)

            case "a:blip":
                if let id = attributes["r:embed"] ?? attributes["r:link"] {
                    drawings.append(Drawing(offset: offset, relationshipID: id, size: pendingSize))
                    pendingSize = .zero
                }

            case "v:imagedata":
                // The older VML spelling, still emitted by some writers.
                if let id = attributes["r:id"] {
                    drawings.append(Drawing(offset: offset, relationshipID: id, size: .zero))
                }

            case "w:tab", "w:br":
                offset += 1

            default:
                break
            }
        }

        func parser(_: XMLParser, foundCharacters string: String) {
            guard insideTextRun else { return }
            // NSAttributedString indexes in UTF-16, so measure the same way.
            offset += string.utf16.count
        }

        func parser(
            _: XMLParser,
            didEndElement element: String,
            namespaceURI _: String?,
            qualifiedName _: String?
        ) {
            switch element {
            case "w:t": insideTextRun = false
            case "w:p": offset += 1 // the paragraph break AppKit will have added
            default: break
            }
        }
    }

    // MARK: - document.xml.rels

    private final class RelationshipParser: NSObject, XMLParserDelegate {
        var targets: [String: String] = [:]

        func parse(_ data: Data) -> Bool {
            let parser = XMLParser(data: data)
            parser.delegate = self
            return parser.parse()
        }

        func parser(
            _: XMLParser,
            didStartElement element: String,
            namespaceURI _: String?,
            qualifiedName _: String?,
            attributes: [String: String]
        ) {
            guard element == "Relationship",
                  let id = attributes["Id"],
                  let target = attributes["Target"],
                  attributes["TargetMode"] != "External"
            else { return }
            targets[id] = target
        }
    }
}
