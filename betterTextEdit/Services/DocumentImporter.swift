import AppKit
import Foundation
import PDFKit
import UniformTypeIdentifiers

/// Turns a file on disk into something the editor can show.
///
/// There are three read paths, and which one a file takes decides how it is
/// edited and whether Save can write it back:
///
/// 1. **Plain text and source code** — memory-mapped and decoded to a `String`,
///    edited as code, saved back in place.
/// 2. **Word processor documents** (`.docx`, `.doc`, `.rtf`, `.rtfd`, `.odt`,
///    `.webarchive`) — decoded into an `NSAttributedString`, *keeping* their
///    fonts, sizes, colours, paragraph spacing, alignment, lists, and tables.
///    Word's own formats go through `DocxReader`, which reads the package
///    itself; the rest go through AppKit's readers. They are edited as
///    formatted text and — for the formats that can be written — saved back in
///    the same format.
/// 3. **PDF** — handed to PDFKit and displayed as a real PDF, so the page looks
///    exactly as it was authored. Its text can be lifted out into an editable
///    formatted document on request.
enum DocumentImporter {
    // MARK: - Formats

    /// A word-processor container AppKit can decode on its own.
    enum RichKind: CaseIterable {
        case docx
        case doc
        case rtf
        case rtfd
        case openDocument
        case webArchive

        var documentType: NSAttributedString.DocumentType {
            switch self {
            case .docx: .officeOpenXML
            case .doc: .docFormat
            case .rtf: .rtf
            case .rtfd: .rtfd
            case .openDocument: .openDocument
            case .webArchive: .webArchive
            }
        }

        var displayName: String {
            switch self {
            case .docx: "Word document"
            case .doc: "Word 97–2004 document"
            case .rtf: "Rich Text document"
            case .rtfd: "Rich Text bundle"
            case .openDocument: "OpenDocument text"
            case .webArchive: "Web archive"
            }
        }
    }

    enum Format: Equatable {
        case plainText
        case rich(RichKind)
        case pdf
        case image

        var displayName: String {
            switch self {
            case .plainText: "Plain text"
            case let .rich(kind): kind.displayName
            case .pdf: "PDF"
            case .image: "Image"
            }
        }
    }

    // MARK: - Payload

    struct Payload {
        enum Content {
            case plain(String)
            case rich(NSAttributedString)
            case pdf(PDFDocument)
            case image(ImageDocument)
        }

        let content: Content
        let language: FileLanguage
        let format: Format
        var layout = PageLayout()
        var documentAttributes: [NSAttributedString.DocumentAttributeKey: Any] = [:]
        /// The file has embedded images that can't be written back out, so it
        /// must not be saved over.
        var hasUnreadableImages = false
        /// How many of those images betterTextEdit recovered for display.
        var displayedImageCount = 0
        /// Parts of a Word document that never reached the text — comments,
        /// tracked changes, text boxes — so saving over the original would lose
        /// them.
        var unsupportedFeatures: [String] = []
        /// The encoding and line endings of a text file, to write it back with.
        var textFormat = TextFileFormat.standard
    }

    // MARK: - Errors

    enum ImportError: LocalizedError {
        case unsupported(String)
        case notText
        case lockedPDF
        case noTextFound(String)

        var errorDescription: String? {
            switch self {
            case let .unsupported(name):
                "betterTextEdit can’t read \(name) files."
            case .notText:
                "This file isn’t text."
            case .lockedPDF:
                "This PDF is password protected, and wasn’t unlocked."
            case let .noTextFound(name):
                "This \(name) has no text betterTextEdit can extract."
            }
        }

        var recoverySuggestion: String? {
            switch self {
            case let .unsupported(name):
                "Export the \(name) file as Word, Rich Text, PDF, or plain text and open that instead."
            case .notText:
                "betterTextEdit opens text, Markdown, source code, Word, Rich Text, OpenDocument, and PDF files."
            case .lockedPDF:
                "Open it again and enter its password when asked."
            case .noTextFound:
                "It may contain only images or scanned pages."
            }
        }
    }

    // MARK: - Detection

    /// Formats that look like documents but have no public reader on macOS.
    private static let unreadable: [String: String] = [
        "pages": "Pages",
        "key": "Keynote",
        "numbers": "Numbers",
        "epub": "EPUB",
    ]

    static func format(for url: URL) -> Format {
        switch url.pathExtension.lowercased() {
        // Templates and macro-enabled documents are the same package with a
        // different label on the main part.
        case "docx", "dotx", "docm", "dotm": .rich(.docx)
        case "doc": .rich(.doc)
        case "rtf": .rich(.rtf)
        case "rtfd": .rich(.rtfd)
        case "odt", "fodt": .rich(.openDocument)
        case "webarchive": .rich(.webArchive)
        case "pdf": .pdf
        default: ImageLoader.handles(url) ? .image : .plainText
        }
    }

    /// Content types worth listing in the Open panel. `.data` stays last so any
    /// file can still be selected — a text editor should never refuse to try.
    static var openableContentTypes: [UTType] {
        let named = [
            "org.openxmlformats.wordprocessingml.document",
            "org.openxmlformats.wordprocessingml.template",
            "org.openxmlformats.wordprocessingml.document.macroenabled",
            "org.openxmlformats.wordprocessingml.template.macroenabled",
            "com.microsoft.word.doc",
            "org.oasis-open.opendocument.text",
        ].compactMap(UTType.init(_:))

        return [.plainText, .sourceCode, .json, .xml, .yaml, .html, .rtf, .rtfd, .pdf, .webArchive]
            + named
            + [.data]
    }

    // MARK: - Reading

    /// Reading happens on the main actor: AppKit's rich-text readers are
    /// documented as main-thread only, and `PDFDocument` parses lazily. Only the
    /// plain-text path, which can face very large files, hops off.
    @MainActor
    static func load(_ url: URL) async throws -> Payload {
        if let name = unreadable[url.pathExtension.lowercased()] {
            throw ImportError.unsupported(name)
        }

        return switch format(for: url) {
        case .plainText: try await loadPlainText(url)
        case let .rich(kind): try loadRichText(url, kind: kind)
        case .pdf: try loadPDF(url)
        case .image: try loadImage(url)
        }
    }

    /// Reads text, working out its encoding and line endings so it can be
    /// written back the same way — see `TextFileFormat`. `encoding` forces a
    /// particular encoding, for reopening a file that was guessed wrong.
    static func loadPlainText(_ url: URL, encoding: TextFileFormat.Encoding? = nil) async throws -> Payload {
        let (text, textFormat) = try await Task.detached(priority: .userInitiated) {
            try accessing(url) {
                let data = try Data(contentsOf: url, options: [.mappedIfSafe])
                do {
                    return try TextFileFormat.decode(data, as: encoding)
                } catch {
                    throw ImportError.notText
                }
            }
        }.value

        var payload = Payload(
            content: .plain(text),
            language: FileLanguage.detect(from: url.pathExtension),
            format: .plainText
        )
        payload.textFormat = textFormat
        return payload
    }

    @MainActor
    private static func loadRichText(_ url: URL, kind: RichKind) throws -> Payload {
        if kind == .docx, let payload = loadWordDocument(url) {
            return payload
        }

        var documentAttributes: NSDictionary?
        let attributed = try accessing(url) { () -> NSAttributedString in
            do {
                return try NSAttributedString(
                    url: url,
                    options: [.documentType: kind.documentType],
                    documentAttributes: &documentAttributes
                )
            } catch {
                // The extension can lie — .doc files are routinely RTF, and
                // .docx files are routinely Word 2003 XML. Let AppKit sniff.
                return try NSAttributedString(url: url, options: [:], documentAttributes: &documentAttributes)
            }
        }

        guard attributed.length > 0 else {
            throw ImportError.noTextFound(kind.displayName)
        }

        let attributes = (documentAttributes as? [NSAttributedString.DocumentAttributeKey: Any]) ?? [:]
        let layout = PageLayout(documentAttributes: attributes)

        // AppKit skipped any embedded pictures; put them back for display.
        var content = attributed
        var restored = 0
        if kind == .docx {
            let mutable = NSMutableAttributedString(attributedString: attributed)
            restored = DocxImages.insert(from: url, into: mutable, maxWidth: layout.textWidth)
            if restored > 0 { content = mutable }
        }

        return Payload(
            content: .rich(content),
            language: .richText,
            format: .rich(kind),
            layout: layout,
            documentAttributes: attributes,
            hasUnreadableImages: restored > 0 || hasSkippedImages(at: url, kind: kind),
            displayedImageCount: restored
        )
    }

    /// Reads a Word document with `DocxReader`. `nil` sends the file to
    /// AppKit's reader instead — a `.docx` that's really RTF or Word 2003 XML,
    /// or a package too damaged to walk — which is a second opinion worth having
    /// before telling anyone their document can't be opened.
    @MainActor
    private static func loadWordDocument(_ url: URL) -> Payload? {
        let result: DocxReader.Result
        do {
            result = try accessing(url) { try DocxReader.read(url) }
        } catch {
            return nil
        }
        guard result.text.length > 0 else { return nil }

        return Payload(
            content: .rich(result.text),
            language: .richText,
            format: .rich(.docx),
            layout: PageLayout(documentAttributes: result.documentAttributes),
            documentAttributes: result.documentAttributes,
            displayedImageCount: result.imageCount,
            unsupportedFeatures: result.unsupported
        )
    }

    // MARK: - Images macOS won't read

    /// Detects embedded images that AppKit's reader dropped on the floor.
    ///
    /// The Office Open XML reader ignores `<w:drawing>` entirely: a `.docx`
    /// whose package contains `word/media/photo.png` comes back as text with no
    /// attachment at all. Since the writer can't emit images either, saving over
    /// such a file would quietly delete the pictures from the only copy that has
    /// them — so a document where this is true is opened unsaved.
    ///
    /// Both formats are ZIP containers, and ZIP stores entry names uncompressed
    /// in each local file header, so the names can be read without inflating
    /// anything.
    private static func hasSkippedImages(at url: URL, kind: RichKind) -> Bool {
        let mediaPrefix: String
        switch kind {
        case .docx: mediaPrefix = "word/media/"
        case .openDocument: mediaPrefix = "Pictures/"
        // The RTF, RTFD, and web-archive readers do surface images as
        // attachments, so those are caught by the normal write-loss check.
        default: return false
        }

        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return false }
        return zipEntryNames(in: data).contains { $0.hasPrefix(mediaPrefix) }
    }

    private static func zipEntryNames(in data: Data) -> [String] {
        data.withUnsafeBytes { raw -> [String] in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return [] }
            let count = raw.count
            var names: [String] = []
            var index = 0

            while index + 30 <= count {
                // "PK\03\04" — a local file header.
                guard base[index] == 0x50, base[index + 1] == 0x4B,
                      base[index + 2] == 0x03, base[index + 3] == 0x04
                else {
                    index += 1
                    continue
                }

                let nameLength = Int(base[index + 26]) | Int(base[index + 27]) << 8
                let start = index + 30
                guard nameLength > 0, start + nameLength <= count else { break }

                if let name = String(bytes: UnsafeBufferPointer(start: base + start, count: nameLength), encoding: .utf8) {
                    names.append(name)
                }
                index = start + nameLength
            }
            return names
        }
    }

    @MainActor
    private static func loadPDF(_ url: URL) throws -> Payload {
        try accessing(url) {
            guard let document = PDFDocument(url: url) else { throw ImportError.notText }
            // Ask for the password rather than refuse. Once unlocked, the
            // document stays encrypted with that password when it's saved.
            if document.isLocked, !PDFPasswordPrompt.unlock(document, name: url.lastPathComponent) {
                throw ImportError.lockedPDF
            }
            guard document.pageCount > 0 else { throw ImportError.noTextFound("PDF") }
            return Payload(content: .pdf(document), language: .pdf, format: .pdf)
        }
    }

    @MainActor
    private static func loadImage(_ url: URL) throws -> Payload {
        try accessing(url) {
            Payload(content: .image(try ImageLoader.load(url)), language: .image, format: .image)
        }
    }

    // MARK: - PDF text extraction

    /// Lifts a PDF's text out as formatted text, keeping the fonts and sizes
    /// PDFKit reports for each run so the extracted document still reads like
    /// the original — and bringing the pictures along with it.
    ///
    /// Images can't be positioned against the text without tracking the graphics
    /// state through the whole content stream, so each page's images follow that
    /// page's text, in the order the page draws them.
    ///
    /// `recognized` supplies text for pages that have none of their own — what
    /// `TextRecognizer` read off a scan, keyed by page index. A recognised page
    /// brings no images along: its only image *is* the page, and that's the text
    /// now sitting in the document.
    @MainActor
    static func extractText(
        from document: PDFDocument,
        maxWidth: CGFloat = 468,
        recognized: [Int: NSAttributedString] = [:]
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()

        for index in 0 ..< document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let pageText = recognized[index]
                ?? page.attributedString
                ?? page.string.map(NSAttributedString.init(string:))
            let images = recognized[index] == nil ? PDFImageExtractor.images(on: page) : []
            guard (pageText?.length ?? 0) > 0 || !images.isEmpty else { continue }

            if result.length > 0 {
                result.append(NSAttributedString(string: "\n\n"))
            }
            if let pageText { result.append(pageText) }

            for image in images {
                guard let attachment = PDFImageExtractor.attachment(for: image, maxWidth: maxWidth) else { continue }
                result.append(NSAttributedString(string: "\n"))
                result.append(NSAttributedString(attachment: attachment))
                result.append(NSAttributedString(string: "\n"))
            }
        }

        // PDF text arrives without paragraph spacing; give it some so the
        // extracted document is readable rather than a solid block.
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = 8
        result.addAttribute(
            .paragraphStyle,
            value: paragraph,
            range: NSRange(location: 0, length: result.length)
        )
        return result
    }

    // MARK: - Helpers

    private static func accessing<T>(_ url: URL, _ body: () throws -> T) rethrows -> T {
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        return try body()
    }
}
