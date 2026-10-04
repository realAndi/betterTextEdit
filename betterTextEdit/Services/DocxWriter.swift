import AppKit
import Foundation

/// Writes formatted text as a Word document, without going through AppKit.
///
/// macOS can write Office Open XML on its own, but what it writes is a sketch
/// of the document rather than the document: tables come out as loose
/// paragraphs, links lose their destinations, lists become literal bullet
/// characters typed into the text, highlighting disappears, and pictures are
/// dropped without a word — there are no media parts in its packages at all.
/// It also spells some elements in ways Word's schema doesn't recognise.
///
/// This writer emits the package itself. Everything the text view can hold has
/// a WordprocessingML spelling, and each one is written the way Word writes it:
///
/// - **Runs** carry their typeface, size, weight, slant, colour, underline,
///   strikethrough, highlight, shading, baseline shift, and kerning.
/// - **Paragraphs** carry alignment, indents, spacing, line height, tab stops,
///   writing direction, and — for headings — an outline level, so Word's
///   navigation pane and tables of contents see them.
/// - **Lists** become real Word numbering (`numbering.xml`), so they renumber
///   when edited in Word; the marker AppKit types into the text is taken out
///   on the way, or Word would show it twice.
/// - **Tables** become `w:tbl`, including merged cells, cell colours, borders,
///   padding, and tables nested inside cells.
/// - **Links** become hyperlinks with external relationships.
/// - **Pictures** become inline drawings with their original bytes and display
///   size, so a JPEG stays a JPEG.
/// - **The page** keeps its paper size, orientation, and margins.
///
/// When the document came from a `.docx`, its headers and footers are carried
/// across from the original package verbatim — they never reached the text
/// view, so this is the only way they survive a save.
enum DocxWriter {
    /// Writes `attributed` to `url` as a `.docx` package.
    static func write(
        _ attributed: NSAttributedString,
        to url: URL,
        layout: PageLayout,
        documentAttributes: [NSAttributedString.DocumentAttributeKey: Any] = [:],
        carryingPartsFrom source: URL? = nil
    ) throws {
        let data = try package(
            attributed,
            layout: layout,
            documentAttributes: documentAttributes,
            carryingPartsFrom: source
        )
        try SafeFileWriter.write(data, to: url)
    }

    /// Builds the package in memory.
    static func package(
        _ attributed: NSAttributedString,
        layout: PageLayout,
        documentAttributes: [NSAttributedString.DocumentAttributeKey: Any] = [:],
        carryingPartsFrom source: URL? = nil
    ) throws -> Data {
        // Pull the carried parts out before anything else claims media names.
        let carried = source.flatMap(CarriedParts.init(source:))
        let builder = PackageBuilder(attributed: attributed, layout: layout, carried: carried, documentAttributes: documentAttributes)
        let body = builder.documentBody()

        var zip = ZipWriter()
        try zip.add("[Content_Types].xml", builder.contentTypes())
        try zip.add("_rels/.rels", builder.packageRelationships())
        try zip.add("docProps/core.xml", PackageBuilder.coreProperties(documentAttributes))
        try zip.add("docProps/app.xml", PackageBuilder.appProperties)
        try zip.add("word/document.xml", body)
        try zip.add("word/styles.xml", builder.styles())
        try zip.add("word/settings.xml", builder.settings())
        try zip.add("word/numbering.xml", builder.numbering())
        try zip.add("word/_rels/document.xml.rels", builder.documentRelationships())
        for (kind, xml) in [("footnotes", builder.footnotesXML), ("endnotes", builder.endnotesXML)] {
            guard let xml else { continue }
            try zip.add("word/\(kind).xml", xml)
            if let relationships = builder.noteRelationships(kind) {
                try zip.add("word/_rels/\(kind).xml.rels", relationships)
            }
        }
        for part in builder.extraParts {
            try zip.add(part.path, part.data, compress: part.compress)
        }
        return try zip.finish()
    }
}

// MARK: - Shared vocabulary

/// Units, colours, and escaping shared by the Word reader and writer.
enum WordML {
    static let main = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
    static let relationships = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    static let packageRelationships = "http://schemas.openxmlformats.org/package/2006/relationships"

    /// Twentieths of a point: Word's unit for indents, spacing, and page sizes.
    static func twips(_ points: CGFloat) -> Int {
        Int((points * 20).rounded())
    }

    /// English Metric Units, DrawingML's unit: 914 400 to the inch.
    static func emu(_ points: CGFloat) -> Int {
        Int((points * 12_700).rounded())
    }

    static func escape(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            // XML 1.0 has no spelling at all for most C0 controls, so a stray
            // one would make the whole part unreadable. Drop them.
            case "\u{0}" ... "\u{8}", "\u{B}", "\u{C}", "\u{E}" ... "\u{1F}", "\u{FFFE}", "\u{FFFF}":
                continue
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    /// An attribute value. Line breaks and tabs have to be written as
    /// character references here: a parser turns a literal one inside an
    /// attribute into a space, which would corrupt the base64 Word keeps a
    /// shape's real definition in.
    static func escapeAttribute(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.utf8.count)
        for scalar in escape(text).unicodeScalars {
            switch scalar {
            case "\n": result += "&#xA;"
            case "\r": result += "&#xD;"
            case "\t": result += "&#x9;"
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    /// `RRGGBB`, resolved against the light appearance — a document has paper
    /// behind it, so a dynamic colour means what it means on white.
    static func hex(_ color: NSColor) -> String? {
        var resolved: NSColor?
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.sRGB)
        }
        guard let rgb = resolved else { return nil }
        func byte(_ component: CGFloat) -> Int { Int((min(max(component, 0), 1) * 255).rounded()) }
        return String(format: "%02X%02X%02X", byte(rgb.redComponent), byte(rgb.greenComponent), byte(rgb.blueComponent))
    }

    static func color(hex: String) -> NSColor? {
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        return NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }

    /// Word's sixteen highlighter colours. A background that is exactly one of
    /// these is written as a highlight, which is what Word's own highlighter
    /// produces and what other word processors recognise; anything else is
    /// written as shading, which takes any colour.
    static let highlights: [String: String] = [
        "FFFF00": "yellow", "00FF00": "green", "00FFFF": "cyan", "FF00FF": "magenta",
        "0000FF": "blue", "FF0000": "red", "000080": "darkBlue", "008080": "darkCyan",
        "008000": "darkGreen", "800080": "darkMagenta", "800000": "darkRed",
        "808000": "darkYellow", "808080": "darkGray", "C0C0C0": "lightGray",
        "000000": "black", "FFFFFF": "white",
    ]

    static let highlightColors: [String: String] = Dictionary(
        uniqueKeysWithValues: highlights.map { ($0.value, $0.key) }
    )

    /// The nearest face macOS ships for the Office fonts it doesn't — by
    /// metrics where there's a close match, by classification otherwise.
    static func standIn(for family: String) -> String {
        let name = family.lowercased()
        let monospaced = ["consolas", "courier", "lucida console", "cascadia", "mono", "code"]
        let serif = ["cambria", "constantia", "garamond", "book antiqua", "palatino", "times", "georgia", "minion",
                     "baskerville", "caslon", "century", "bookman", "serif", "song", "mincho", "batang"]
        if monospaced.contains(where: name.contains) { return "Menlo" }
        if name.contains("sans") { return "Helvetica Neue" }
        if serif.contains(where: name.contains) { return name.contains("cambria") ? "Georgia" : "Times New Roman" }
        if name.hasPrefix("arial") || name.contains("calibri") || name.contains("aptos") || name.contains("segoe") {
            return "Helvetica Neue"
        }
        return "Helvetica Neue"
    }

    /// Sniffs an image's real format from its first bytes, since a file
    /// wrapper's name is only a suggestion.
    static func imageFormat(of data: Data) -> (ext: String, mime: String)? {
        let bytes = [UInt8](data.prefix(12))
        guard bytes.count >= 4 else { return nil }
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return ("png", "image/png") }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return ("jpeg", "image/jpeg") }
        if bytes.starts(with: [0x47, 0x49, 0x46, 0x38]) { return ("gif", "image/gif") }
        if bytes.starts(with: [0x42, 0x4D]) { return ("bmp", "image/bmp") }
        if bytes.starts(with: [0x49, 0x49, 0x2A, 0x00]) || bytes.starts(with: [0x4D, 0x4D, 0x00, 0x2A]) {
            return ("tiff", "image/tiff")
        }
        return nil
    }
}

// MARK: - Parts carried over from the original

/// What the package a document was opened from has that the text never held,
/// and that a save over it should carry across untouched: headers and footers,
/// named style definitions, custom document properties, and custom XML.
///
/// Headers and footers are self-contained parts, each with its own
/// relationships, so copying them byte for byte is lossless. Style definitions
/// are copied for the styles the text still uses, so Word's style gallery,
/// navigation pane, and tables of contents keep working after a save.
private struct CarriedParts {
    struct Reference {
        let element: String // "headerReference" or "footerReference"
        let type: String // "default", "first", or "even"
        let path: String // e.g. "word/header1.xml"
    }

    struct Linked {
        let type: String
        let path: String
    }

    var references: [Reference] = []
    /// Every file to copy, keyed by its path in the package.
    var files: [String: Data] = [:]
    var titlePage = false
    var evenAndOdd = false
    /// The original's style definitions, by id.
    var styles: [String: XMLTree] = [:]
    /// Parts the package itself points at — custom document properties.
    var packageParts: [Linked] = []
    /// Parts the document points at — the theme, and custom XML data stores.
    var documentParts: [Linked] = []
    var contentTypes: [String: String] = [:]

    init?(source: URL) {
        guard ["docx", "dotx", "docm", "dotm"].contains(source.pathExtension.lowercased()),
              let archive = ZipArchive(url: source),
              let document = archive.contents(named: "word/document.xml")
        else { return nil }

        var defaults: [String: String] = [:]
        var overrides: [String: String] = [:]
        if let types = archive.contents(named: "[Content_Types].xml").flatMap(XMLTree.parse) {
            for node in types.children {
                if node.qualifiedName.hasSuffix("Default"), let ext = node.rawAttributes["Extension"], let type = node.rawAttributes["ContentType"] {
                    defaults[ext.lowercased()] = type
                } else if node.qualifiedName.hasSuffix("Override"), let part = node.rawAttributes["PartName"], let type = node.rawAttributes["ContentType"] {
                    overrides[String(part.drop(while: { $0 == "/" }))] = type
                }
            }
        }
        func contentType(_ path: String) -> String? {
            overrides[path] ?? defaults[(path as NSString).pathExtension.lowercased()]
        }

        /// Copies a part, its relationships, and what those point at.
        func copy(_ path: String, depth: Int = 0) {
            guard depth < 4, files[path] == nil, let data = archive.contents(named: path) else { return }
            files[path] = data
            if let type = contentType(path) { contentTypes[path] = type }
            let relsPath = PackagePath.relationships(for: path)
            guard let rels = archive.contents(named: relsPath) else { return }
            files[relsPath] = rels
            let directory = (path as NSString).deletingLastPathComponent
            for target in RelationshipTargets(rels).inside.values {
                copy(PackagePath.resolve(target, from: directory), depth: depth + 1)
            }
        }

        let targets = RelationshipTargets(archive.contents(named: "word/_rels/document.xml.rels"))
        let section = FinalSectionParser()
        if section.parse(document) {
            for (element, type, id) in section.references {
                guard let target = targets.inside[id] else { continue }
                let path = PackagePath.resolve(target, from: "word")
                guard archive.contents(named: path) != nil else { continue }
                // The part's own relationships, and whatever they point at
                // inside the package — usually the pictures in a letterhead.
                copy(path)
                references.append(Reference(element: element, type: type, path: path))
            }
            titlePage = section.titlePage
        }
        evenAndOdd = references.contains { $0.type == "even" }
            && (archive.contents(named: "word/settings.xml").map {
                String(decoding: $0, as: UTF8.self).contains("evenAndOddHeaders")
            } ?? false)

        if let stylesData = archive.contents(named: "word/styles.xml"), let tree = XMLTree.parse(stylesData) {
            for node in tree.children where node.name == "w:style" {
                if let id = node["styleId"] { styles[id] = node }
            }
        }

        let packageTargets = RelationshipTargets(archive.contents(named: "_rels/.rels"))
        for (id, type) in packageTargets.types where type.hasSuffix("/custom-properties") {
            guard let target = packageTargets.inside[id] else { continue }
            let path = PackagePath.resolve(target, from: "")
            copy(path)
            if files[path] != nil { packageParts.append(Linked(type: type, path: path)) }
        }
        // The theme: shapes and lines kept whole take their colours from it,
        // and without it a theme colour falls back to black.
        for (id, type) in targets.types where type.hasSuffix("/theme") {
            guard let target = targets.inside[id] else { continue }
            let path = PackagePath.resolve(target, from: "word")
            copy(path)
            if files[path] != nil { documentParts.append(Linked(type: type, path: path)) }
        }
        for (id, type) in targets.types where type.hasSuffix("/customXml") {
            guard let target = targets.inside[id] else { continue }
            let path = PackagePath.resolve(target, from: "word")
            copy(path)
            if files[path] != nil { documentParts.append(Linked(type: type, path: path)) }
        }
    }

    /// Reads the body's last `w:sectPr` — the one that governs the end of the
    /// document, which is the one the single section written here inherits.
    private final class FinalSectionParser: NSObject, XMLParserDelegate {
        var references: [(String, String, String)] = []
        var titlePage = false
        private var depth = 0
        private var bodyDepth = -1
        private var inFinalSection = false
        private var current: [(String, String, String)] = []
        private var currentTitlePage = false

        func parse(_ data: Data) -> Bool {
            let parser = XMLParser(data: data)
            parser.delegate = self
            return parser.parse()
        }

        func parser(_: XMLParser, didStartElement element: String, namespaceURI _: String?,
                    qualifiedName _: String?, attributes: [String: String]) {
            depth += 1
            switch element {
            case "w:body":
                bodyDepth = depth
            case "w:sectPr" where depth == bodyDepth + 1:
                inFinalSection = true
                current = []
                currentTitlePage = false
            case "w:headerReference", "w:footerReference":
                guard inFinalSection, let id = attributes["r:id"] else { break }
                let name = String(element.dropFirst(2))
                current.append((name, attributes["w:type"] ?? "default", id))
            case "w:titlePg":
                if inFinalSection { currentTitlePage = attributes["w:val"].map { $0 != "0" && $0 != "false" } ?? true }
            default:
                break
            }
        }

        func parser(_: XMLParser, didEndElement element: String, namespaceURI _: String?, qualifiedName _: String?) {
            if element == "w:sectPr", inFinalSection, depth == bodyDepth + 1 {
                inFinalSection = false
                references = current
                titlePage = currentTitlePage
            }
            depth -= 1
        }
    }
}

/// Resolves relationship targets, which are relative to the folder of the part
/// that owns them and may climb out of it.
enum PackagePath {
    static func resolve(_ target: String, from directory: String) -> String {
        if target.hasPrefix("/") { return String(target.dropFirst()) }
        var parts = directory.isEmpty ? [] : directory.split(separator: "/").map(String.init)
        for component in target.split(separator: "/") {
            switch component {
            case "..": if !parts.isEmpty { parts.removeLast() }
            case ".": continue
            default: parts.append(String(component))
            }
        }
        return parts.joined(separator: "/")
    }

    /// `word/header1.xml` → `word/_rels/header1.xml.rels`.
    static func relationships(for path: String) -> String {
        let directory = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        return directory.isEmpty ? "_rels/\(name).rels" : "\(directory)/_rels/\(name).rels"
    }
}

/// A part's relationships, split into what points inside the package and what
/// points outside it.
struct RelationshipTargets {
    var inside: [String: String] = [:]
    var outside: [String: String] = [:]
    var types: [String: String] = [:]

    init(_ data: Data?) {
        guard let data else { return }
        let parser = XMLParser(data: data)
        let delegate = Delegate()
        parser.delegate = delegate
        parser.parse()
        inside = delegate.inside
        outside = delegate.outside
        types = delegate.types
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var inside: [String: String] = [:]
        var outside: [String: String] = [:]
        var types: [String: String] = [:]

        func parser(_: XMLParser, didStartElement element: String, namespaceURI _: String?,
                    qualifiedName _: String?, attributes: [String: String]) {
            guard element == "Relationship" || element.hasSuffix(":Relationship"),
                  let id = attributes["Id"], let target = attributes["Target"]
            else { return }
            types[id] = attributes["Type"]
            if attributes["TargetMode"] == "External" {
                outside[id] = target
            } else {
                inside[id] = target
            }
        }
    }
}

// MARK: - Building the package

private final class PackageBuilder {
    struct Part {
        let path: String
        let data: Data
        let compress: Bool
    }

    private struct Relationship {
        let id: String
        let type: String
        let target: String
        let external: Bool
    }

    private let text: NSAttributedString
    private let string: NSString
    private let layout: PageLayout
    private let carried: CarriedParts?
    private let documentAttributes: [NSAttributedString.DocumentAttributeKey: Any]

    private(set) var extraParts: [Part] = []
    /// Relationships belong to the part that uses them: a link in a footnote
    /// is listed in `footnotes.xml.rels`, not the document's.
    private var relationshipsByPart: [String: [Relationship]] = [:]
    private var part = "document"
    private var mediaByContent: [String: [Data: String]] = [:]
    private var usedPaths: Set<String> = []
    private var imageExtensions: Set<String> = []
    private var drawingID = 0
    private var hyperlinkIDs: [String: [String: String]] = [:]
    private let numberingRegistry = NumberingRegistry()
    private var headerFooterRelationships: [(CarriedParts.Reference, String)] = []

    /// Notes, keyed the way the Word reader tagged them (`footnote:3`), and
    /// the ids they're written under.
    private var noteIDs: [String: Int] = [:]
    private var emittedReferences: Set<String> = []
    /// Where each field's result starts and ends, by its `id|instruction` tag.
    private var fieldBounds: [String: (start: Int, end: Int)] = [:]
    /// Set while writing a note, so its first paragraph gets Word's own
    /// reference mark and its paragraphs the note style.
    private var pendingNoteMark: String?
    private var paragraphStyleOverride: String?
    /// Counts paragraphs as they're written, so the numbering registry can
    /// tell a list that carries on from one that was interrupted.
    private var paragraphCounter = 0

    private(set) var footnotesXML: String?
    private(set) var endnotesXML: String?

    /// Namespaces the document's root declares: the standard set, and any a
    /// kept object brought with it.
    private var rootNamespaces: [String: String] = PackageBuilder.standardNamespaces
    /// Content types of parts kept objects brought, by path.
    private var keptContentTypes: [String: String] = [:]
    /// Where each bookmark starts and ends, and the ids they're written under.
    private var bookmarkStarts: [Int: [String]] = [:]
    private var bookmarkEnds: [Int: [String]] = [:]
    private var bookmarkPoints: [Int: [String]] = [:]
    private var bookmarkIDs: [String: Int] = [:]
    private var openBookmarks: Set<String> = []
    /// Content controls: where each one inside a paragraph starts and ends.
    private var controlBounds: [String: (start: Int, end: Int)] = [:]
    private var writtenBlockControls: Set<String> = []
    /// Style ids the text refers to that the original package defines.
    private var sourceStyleIDs: Set<String> = []
    private var usedStyleIDs: Set<String> = []

    /// The body's dominant typeface and size, which become the document
    /// defaults so new text typed in Word matches what's already there.
    private var defaultFamily = "Helvetica"
    private var defaultHalfPoints = 24

    init(attributed: NSAttributedString, layout: PageLayout, carried: CarriedParts?,
         documentAttributes: [NSAttributedString.DocumentAttributeKey: Any] = [:]) {
        text = attributed
        string = attributed.string as NSString
        self.layout = layout
        self.carried = carried
        self.documentAttributes = documentAttributes

        // Fixed relationships first, so their ids are stable.
        relationshipsByPart["document"] = [
            Relationship(id: "rId1", type: Self.styleRel, target: "styles.xml", external: false),
            Relationship(id: "rId2", type: Self.settingsRel, target: "settings.xml", external: false),
            Relationship(id: "rId3", type: Self.numberingRel, target: "numbering.xml", external: false),
        ]

        if let carried {
            keptContentTypes.merge(carried.contentTypes) { current, _ in current }
            usedPaths.formUnion(carried.files.keys)
            for (path, data) in carried.files.sorted(by: { $0.key < $1.key }) {
                let ext = (path as NSString).pathExtension.lowercased()
                if path.hasPrefix("word/media/") || !["xml", "rels"].contains(ext) {
                    imageExtensions.insert(ext)
                }
                extraParts.append(Part(path: path, data: data, compress: Self.compressible(path)))
            }
            for reference in carried.references {
                let type = reference.element == "headerReference" ? Self.headerRel : Self.footerRel
                let id = addRelationship(type: type, target: String(reference.path.dropFirst("word/".count)))
                headerFooterRelationships.append((reference, id))
            }
            for linked in carried.documentParts {
                addRelationship(type: linked.type, target: Self.relativeToWord(linked.path))
            }
        }

        measureDefaults()
        registerKeptObjects()
        measureBookmarks()
        measureControls()
        measureStyles()
    }

    /// A package path as a target from `word/document.xml`.
    static func relativeToWord(_ path: String) -> String {
        path.hasPrefix("word/") ? String(path.dropFirst("word/".count)) : "../" + path
    }

    /// Claims the parts kept objects bring before any picture is named, so a
    /// new `image1.png` can't overwrite a chart's.
    private func registerKeptObjects() {
        var highest = 0
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if let rule = value as? HorizontalRuleAttachment, rule.originalXML != nil {
                for (prefix, uri) in rule.namespaces where rootNamespaces[prefix] == nil { rootNamespaces[prefix] = uri }
                for groups in rule.originalXML!.captures(of: #"<wp:docPr\b[^>]*?\bid="(\d+)""#) {
                    highest = max(highest, Int(groups[1]) ?? 0)
                }
            }
            guard let object = value as? PreservedObjectAttachment else { return }
            for (path, data) in object.parts where !usedPaths.contains(path) {
                usedPaths.insert(path)
                extraParts.append(Part(path: path, data: data, compress: Self.compressible(path)))
                if let type = object.contentTypes[path] { keptContentTypes[path] = type }
            }
            for (prefix, uri) in object.namespaces where rootNamespaces[prefix] == nil {
                rootNamespaces[prefix] = uri
            }
            for groups in object.xml.captures(of: #"<wp:docPr\b[^>]*?\bid="(\d+)""#) {
                highest = max(highest, Int(groups[1]) ?? 0)
            }
        }
        drawingID = highest
    }

    /// Each bookmark's first unbroken stretch — gaps of paragraph breaks
    /// allowed, since a bookmark can span paragraphs — and its points.
    private func measureBookmarks() {
        var spans: [String: (start: Int, end: Int)] = [:]
        var closed: Set<String> = []
        var points: [String: Int] = [:]
        text.enumerateAttribute(.wordBookmarks, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            for name in value as? [String] ?? [] {
                if name.hasPrefix("·") {
                    let real = String(name.dropFirst())
                    if points[real] == nil, spans[real] == nil { points[real] = range.location }
                    continue
                }
                guard !closed.contains(name) else { continue }
                if let span = spans[name] {
                    let gap = string.substring(with: NSRange(location: span.end, length: range.location - span.end))
                    if gap.allSatisfy({ $0 == "\n" || $0 == "\r" || $0 == "\u{2029}" }) {
                        spans[name] = (span.start, NSMaxRange(range))
                    } else {
                        closed.insert(name)
                    }
                } else {
                    spans[name] = (range.location, NSMaxRange(range))
                }
            }
        }
        var next = 0
        for (name, span) in spans.sorted(by: { $0.value.start < $1.value.start }) {
            bookmarkStarts[span.start, default: []].append(name)
            bookmarkEnds[span.end, default: []].append(name)
            bookmarkIDs[name] = next
            next += 1
        }
        for (name, location) in points.sorted(by: { $0.value < $1.value }) where bookmarkIDs[name] == nil {
            bookmarkPoints[location, default: []].append(name)
            bookmarkIDs[name] = next
            next += 1
        }
    }

    /// Content controls inside a paragraph: each one's first unbroken
    /// stretch, never across a paragraph break.
    private func measureControls() {
        var closed: Set<String> = []
        text.enumerateAttribute(.wordContentControl, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard let tag = value as? String, !closed.contains(tag) else { return }
            if let bounds = controlBounds[tag] {
                if bounds.end == range.location, !string.substring(with: range).contains(where: \.isNewline) {
                    controlBounds[tag] = (bounds.start, NSMaxRange(range))
                } else {
                    closed.insert(tag)
                }
            } else if !string.substring(with: range).contains(where: \.isNewline) {
                controlBounds[tag] = (range.location, NSMaxRange(range))
            }
        }
    }

    private func measureStyles() {
        let all = NSRange(location: 0, length: text.length)
        for key in [NSAttributedString.Key.wordParagraphStyle, .wordCharacterStyle] {
            text.enumerateAttribute(key, in: all) { value, _, _ in
                if let id = value as? String { usedStyleIDs.insert(id) }
            }
        }
        if let carried { sourceStyleIDs = usedStyleIDs.filter { carried.styles[$0] != nil } }
    }

    private static func compressible(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return !["png", "jpg", "jpeg", "gif", "gz", "zip"].contains(ext)
    }

    @discardableResult
    private func addRelationship(type: String, target: String, external: Bool = false) -> String {
        let id = "rId\((relationshipsByPart[part]?.count ?? 0) + 1)"
        relationshipsByPart[part, default: []].append(Relationship(id: id, type: type, target: target, external: external))
        return id
    }

    private func measureDefaults() {
        var families: [String: Int] = [:]
        var sizes: [Int: Int] = [:]
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, range, _ in
            guard let font = attributes[.font] as? NSFont else { return }
            families[Self.family(of: font, original: attributes[.wordFontName] as? String), default: 0] += range.length
            sizes[Int((font.pointSize * 2).rounded()), default: 0] += range.length
        }
        if let family = families.max(by: { $0.value < $1.value })?.key { defaultFamily = family }
        if let size = sizes.max(by: { $0.value < $1.value })?.key { defaultHalfPoints = size }
    }

    // MARK: Body

    func documentBody() -> String {
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
        xml += "<w:document\(namespaceDeclarations())><w:body>"
        measureFields()
        let (body, notes) = separateNotes(splitParagraphs())
        if body.isEmpty {
            xml += "<w:p/>"
        } else {
            writeBlocks(body[...], depth: 0, into: &xml)
        }
        // Bookmarks still open close at the end of the body.
        for name in openBookmarks.sorted() {
            xml += "<w:bookmarkEnd w:id=\"\(bookmarkIDs[name] ?? 0)\"/>"
        }
        openBookmarks.removeAll()
        xml += sectionProperties()
        xml += "</w:body></w:document>"

        footnotesXML = notesPart("footnote", notes: notes)
        endnotesXML = notesPart("endnote", notes: notes)
        if footnotesXML != nil { addRelationship(type: Self.footnotesRel, target: "footnotes.xml") }
        if endnotesXML != nil { addRelationship(type: Self.endnotesRel, target: "endnotes.xml") }
        return xml
    }

    static let standardNamespaces: [String: String] = [
        "w": WordML.main,
        "r": WordML.relationships,
        "wp": "http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing",
        "a": "http://schemas.openxmlformats.org/drawingml/2006/main",
        "pic": "http://schemas.openxmlformats.org/drawingml/2006/picture",
        "v": "urn:schemas-microsoft-com:vml",
        "o": "urn:schemas-microsoft-com:office:office",
        "w10": "urn:schemas-microsoft-com:office:word",
        "m": "http://schemas.openxmlformats.org/officeDocument/2006/math",
        "mc": "http://schemas.openxmlformats.org/markup-compatibility/2006",
        "wps": "http://schemas.microsoft.com/office/word/2010/wordprocessingShape",
        "wpg": "http://schemas.microsoft.com/office/word/2010/wordprocessingGroup",
        "wp14": "http://schemas.microsoft.com/office/word/2010/wordprocessingDrawing",
        "w14": "http://schemas.microsoft.com/office/word/2010/wordml",
        "w15": "http://schemas.microsoft.com/office/word/2012/wordml",
    ]

    /// Every namespace the parts might use — kept objects bring theirs — with
    /// Word's newer ones marked ignorable, as Word marks them.
    private func namespaceDeclarations() -> String {
        var result = ""
        for (prefix, uri) in rootNamespaces.sorted(by: { $0.key < $1.key }) {
            result += " xmlns:\(prefix)=\"\(WordML.escape(uri))\""
        }
        let ignorable = ["w14", "w15", "wp14", "w16se", "w16cid", "w16", "w16cex", "w16sdtdh", "w16sdtfl", "w16du"]
            .filter { rootNamespaces[$0] != nil }
        if !ignorable.isEmpty { result += " mc:Ignorable=\"\(ignorable.joined(separator: " "))\"" }
        return result
    }

    // MARK: Notes and fields

    /// Splits the Word reader's gathered notes back out of the body.
    ///
    /// A note keeps its place only while its reference does: if the reference
    /// mark has been deleted, the note's text is still on screen, so it's
    /// written as ordinary text rather than silently dropped. The rule above the
    /// notes is Word's to draw, so it goes whenever any note is written.
    private func separateNotes(_ paragraphs: [Paragraph]) -> ([Paragraph], [String: [Paragraph]]) {
        func key(_ paragraph: Paragraph) -> String? {
            guard string.length > 0 else { return nil }
            let location = paragraph.content.length > 0 ? paragraph.content.location : paragraph.mark
            return text.attribute(.wordNoteBody, at: min(location, string.length - 1), effectiveRange: nil) as? String
        }

        // Notes live after their rule, at the end. A paragraph elsewhere that
        // happens to carry a note's label — pasted from the notes, say — is
        // body text.
        guard let rule = paragraphs.lastIndex(where: { key($0) == "separator" }) else { return (paragraphs, [:]) }
        var bodies: [String: [Paragraph]] = [:]
        for paragraph in paragraphs[(rule + 1)...] {
            if let key = key(paragraph), key != "separator" { bodies[key, default: []].append(paragraph) }
        }

        // Ids in the order the references appear, which is how Word numbers.
        var counters: [String: Int] = [:]
        text.enumerateAttribute(.wordNoteReference, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            guard let key = value as? String, bodies[key] != nil, noteIDs[key] == nil else { return }
            let kind = key.hasPrefix("endnote") ? "endnote" : "footnote"
            counters[kind, default: 0] += 1
            noteIDs[key] = counters[kind]
        }

        var body: [Paragraph] = []
        var notes: [String: [Paragraph]] = [:]
        for (index, paragraph) in paragraphs.enumerated() {
            switch key(paragraph) {
            case "separator" where index == rule && !noteIDs.isEmpty:
                continue
            case let key? where index > rule && noteIDs[key] != nil:
                notes[key, default: []].append(paragraph)
            default:
                body.append(paragraph)
            }
        }
        return (body, notes)
    }

    private func notesPart(_ kind: String, notes: [String: [Paragraph]]) -> String? {
        let keys = noteIDs.filter { $0.key.hasPrefix(kind) }.sorted { $0.value < $1.value }
        guard !keys.isEmpty else { return nil }

        let previousPart = part
        part = kind + "s"
        defer {
            part = previousPart
            pendingNoteMark = nil
            paragraphStyleOverride = nil
        }

        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
        xml += "<w:\(kind)s\(namespaceDeclarations())>"
        // Word expects its separator lines to be defined, as ids -1 and 0.
        let spacing = "<w:pPr><w:spacing w:after=\"0\" w:line=\"240\" w:lineRule=\"auto\"/></w:pPr>"
        xml += "<w:\(kind) w:type=\"separator\" w:id=\"-1\"><w:p>\(spacing)<w:r><w:separator/></w:r></w:p></w:\(kind)>"
        xml += "<w:\(kind) w:type=\"continuationSeparator\" w:id=\"0\"><w:p>\(spacing)<w:r><w:continuationSeparator/></w:r></w:p></w:\(kind)>"

        let style = kind == "footnote" ? "Footnote" : "Endnote"
        for (key, id) in keys {
            guard let paragraphs = notes[key] else { continue }
            xml += "<w:\(kind) w:id=\"\(id)\">"
            pendingNoteMark = "<w:r><w:rPr><w:rStyle w:val=\"\(style)Reference\"/></w:rPr><w:\(kind)Ref/></w:r>"
            paragraphStyleOverride = "\(style)Text"
            var content = ""
            writeBlocks(paragraphs[...], depth: 0, into: &content)
            xml += content.isEmpty ? "<w:p/>" : content
            xml += "</w:\(kind)>"
        }
        return xml + "</w:\(kind)s>"
    }

    /// Finds each field's result: the first unbroken stretch of text carrying
    /// its tag, allowing only paragraph breaks in between — a table of contents
    /// spans many paragraphs. A copy of the result pasted somewhere else is
    /// then just text, rather than stretching one field over everything
    /// between the two.
    private func measureFields() {
        var closed: Set<String> = []
        text.enumerateAttribute(.wordField, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard let tag = value as? String, !closed.contains(tag) else { return }
            guard let bounds = fieldBounds[tag] else {
                fieldBounds[tag] = (range.location, NSMaxRange(range))
                return
            }
            let gap = string.substring(with: NSRange(location: bounds.end, length: range.location - bounds.end))
            if gap.allSatisfy({ $0 == "\n" || $0 == "\r" || $0 == "\u{2029}" }) {
                fieldBounds[tag] = (bounds.start, NSMaxRange(range))
            } else {
                closed.insert(tag)
            }
        }
    }

    private static func fieldInstruction(_ tag: String) -> String {
        tag.firstIndex(of: "|").map { String(tag[tag.index(after: $0)...]) } ?? tag
    }

    /// One paragraph of the source: its content, without the terminator, and
    /// the paragraph style that governs it.
    private struct Paragraph {
        let content: NSRange
        /// Where the paragraph's mark sits — its terminator, or its last
        /// character when there isn't one — whose attributes size an empty line.
        let mark: Int
        let style: NSParagraphStyle?
        var tables: [NSTextTableBlock] {
            style?.textBlocks.compactMap { $0 as? NSTextTableBlock } ?? []
        }
    }

    /// Splits on every paragraph separator the text system recognises: LF, CR,
    /// CRLF, and U+2029. A string that ends in a separator has no empty
    /// paragraph after it — Word's last paragraph mark is that separator.
    private func splitParagraphs() -> [Paragraph] {
        var result: [Paragraph] = []
        let length = string.length
        var start = 0
        var index = 0

        func style(at location: Int) -> NSParagraphStyle? {
            guard length > 0 else { return nil }
            return text.attribute(.paragraphStyle, at: min(location, length - 1), effectiveRange: nil) as? NSParagraphStyle
        }

        while index < length {
            let unit = string.character(at: index)
            if unit == 0x0A || unit == 0x0D || unit == 0x2029 {
                result.append(Paragraph(content: NSRange(location: start, length: index - start), mark: index, style: style(at: start)))
                if unit == 0x0D, index + 1 < length, string.character(at: index + 1) == 0x0A {
                    index += 1
                }
                start = index + 1
            }
            index += 1
        }
        if start < length {
            result.append(Paragraph(content: NSRange(location: start, length: length - start), mark: length - 1, style: style(at: start)))
        }
        return result
    }

    /// Writes a run of paragraphs, gathering those inside a table at this
    /// nesting depth into the table they belong to.
    private func writeBlocks(_ paragraphs: ArraySlice<Paragraph>, depth: Int, into xml: inout String) {
        var index = paragraphs.startIndex
        while index < paragraphs.endIndex {
            let paragraph = paragraphs[index]
            let tables = paragraph.tables
            guard tables.count > depth else {
                // A content control round whole paragraphs wraps the run of
                // them that carry its label.
                if let tag = blockControl(of: paragraph), !writtenBlockControls.contains(tag) {
                    writtenBlockControls.insert(tag)
                    var end = index + 1
                    while end < paragraphs.endIndex, paragraphs[end].tables.count <= depth,
                          blockControl(of: paragraphs[end]) == tag {
                        end += 1
                    }
                    xml += "<w:sdt>" + Self.controlProperties(tag) + "<w:sdtContent>"
                    for inner in paragraphs[index ..< end] { writeParagraph(inner, into: &xml) }
                    xml += "</w:sdtContent></w:sdt>"
                    index = end
                    continue
                }
                writeParagraph(paragraph, into: &xml)
                index += 1
                continue
            }

            let table = tables[depth].table
            var end = index + 1
            while end < paragraphs.endIndex {
                let next = paragraphs[end].tables
                guard next.count > depth, next[depth].table === table else { break }
                end += 1
            }
            writeTable(table, paragraphs[index ..< end], depth: depth, into: &xml)
            index = end
        }
    }

    private func blockControl(of paragraph: Paragraph) -> String? {
        guard string.length > 0 else { return nil }
        let location = paragraph.content.length > 0 ? paragraph.content.location : paragraph.mark
        return text.attribute(.wordBlockContentControl, at: min(location, string.length - 1), effectiveRange: nil) as? String
    }

    /// A control's `w:sdtPr`, from its `id|xml` label — without a pointer to
    /// placeholder text in the original's glossary, which isn't carried.
    static func controlProperties(_ tag: String) -> String {
        guard let bar = tag.firstIndex(of: "|") else { return "<w:sdtPr/>" }
        var properties = String(tag[tag.index(after: bar)...])
        properties = properties.replacingMatches(of: #"<w:placeholder\b.*?</w:placeholder>"#) { _ in "" }
        return properties
    }

    // MARK: Tables

    private struct CellKey: Hashable {
        let row: Int
        let column: Int
    }

    private func writeTable(_ table: NSTextTable, _ paragraphs: ArraySlice<Paragraph>, depth: Int, into xml: inout String) {
        // Cells are keyed by position rather than by block identity: an edit can
        // copy a paragraph style, and with it the block, but never moves it.
        var cells: [CellKey: (block: NSTextTableBlock, paragraphs: [Paragraph])] = [:]
        for paragraph in paragraphs {
            let block = paragraph.tables[depth]
            let key = CellKey(row: block.startingRow, column: block.startingColumn)
            cells[key, default: (block, [])].paragraphs.append(paragraph)
        }

        let columns = max(table.numberOfColumns, cells.values.map { $0.block.startingColumn + $0.block.columnSpan }.max() ?? 1, 1)
        let rows = cells.values.map { $0.block.startingRow + $0.block.rowSpan }.max() ?? 1
        let widths = columnWidths(table: table, cells: cells.values.map(\.block), columns: columns)

        xml += "<w:tbl><w:tblPr>"
        xml += tableWidth(table)
        xml += "<w:tblLayout w:type=\"autofit\"/>"
        xml += "<w:tblCellMar><w:left w:w=\"0\" w:type=\"dxa\"/><w:right w:w=\"0\" w:type=\"dxa\"/></w:tblCellMar>"
        xml += "<w:tblLook w:val=\"0000\" w:firstRow=\"0\" w:lastRow=\"0\" w:firstColumn=\"0\" w:lastColumn=\"0\" w:noHBand=\"1\" w:noVBand=\"1\"/>"
        xml += "</w:tblPr><w:tblGrid>"
        for width in widths {
            xml += "<w:gridCol w:w=\"\(WordML.twips(width))\"/>"
        }
        xml += "</w:tblGrid>"

        for row in 0 ..< rows {
            xml += "<w:tr>"
            var column = 0
            while column < columns {
                if let cell = cells[CellKey(row: row, column: column)] {
                    let span = max(cell.block.columnSpan, 1)
                    xml += "<w:tc>"
                    xml += cellProperties(cell.block, widths: widths, column: column, merge: cell.block.rowSpan > 1 ? "restart" : nil)
                    let content = cell.paragraphs[...]
                    var inner = ""
                    writeBlocks(content, depth: depth + 1, into: &inner)
                    xml += inner
                    // A cell must end with a paragraph, even after a nested table.
                    if !inner.hasSuffix("</w:p>"), !inner.hasSuffix("<w:p/>") { xml += "<w:p/>" }
                    xml += "</w:tc>"
                    column += span
                } else if let above = cells.values.first(where: {
                    $0.block.startingColumn == column
                        && $0.block.startingRow < row
                        && row < $0.block.startingRow + $0.block.rowSpan
                }) {
                    // Covered by a cell merged down from a row above.
                    xml += "<w:tc>"
                    xml += cellProperties(above.block, widths: widths, column: column, merge: "continue")
                    xml += "<w:p/></w:tc>"
                    column += max(above.block.columnSpan, 1)
                } else {
                    // A hole in a ragged table. Word wants the grid filled.
                    xml += "<w:tc><w:tcPr><w:tcW w:w=\"\(WordML.twips(widths[column]))\" w:type=\"dxa\"/></w:tcPr><w:p/></w:tc>"
                    column += 1
                }
            }
            xml += "</w:tr>"
        }
        xml += "</w:tbl>"
    }

    private func tableWidth(_ table: NSTextTable) -> String {
        let value = table.value(for: .width)
        switch table.valueType(for: .width) {
        case .percentageValueType where value > 0:
            return "<w:tblW w:w=\"\(Int((min(value, 100) * 50).rounded()))\" w:type=\"pct\"/>"
        case .absoluteValueType where value > 0:
            return "<w:tblW w:w=\"\(WordML.twips(value))\" w:type=\"dxa\"/>"
        default:
            return "<w:tblW w:w=\"0\" w:type=\"auto\"/>"
        }
    }

    /// Column widths in points. Cells that state an absolute width win; the
    /// rest share whatever the measure has left.
    private func columnWidths(table: NSTextTable, cells: [NSTextTableBlock], columns: Int) -> [CGFloat] {
        var available = layout.textWidth
        let tableWidth = table.value(for: .width)
        switch table.valueType(for: .width) {
        case .percentageValueType where tableWidth > 0: available = layout.textWidth * min(tableWidth, 100) / 100
        case .absoluteValueType where tableWidth > 0: available = tableWidth
        default: break
        }

        var widths = [CGFloat?](repeating: nil, count: columns)
        for block in cells where block.columnSpan == 1 && block.startingColumn < columns {
            let value = block.value(for: .width)
            guard value > 0 else { continue }
            let points = block.valueType(for: .width) == .percentageValueType
                ? available * value / 100
                : value + block.width(for: .padding, edge: .minX) + block.width(for: .padding, edge: .maxX)
            widths[block.startingColumn] = max(widths[block.startingColumn] ?? 0, points)
        }

        let claimed = widths.compactMap { $0 }.reduce(0, +)
        let unclaimed = widths.filter { $0 == nil }.count
        let share = unclaimed > 0 ? max((available - claimed) / CGFloat(unclaimed), 36) : 0
        return widths.map { $0 ?? share }
    }

    private func cellProperties(_ block: NSTextTableBlock, widths: [CGFloat], column: Int, merge: String?) -> String {
        let span = max(block.columnSpan, 1)
        let width = widths[column ..< min(column + span, widths.count)].reduce(0, +)

        var xml = "<w:tcPr><w:tcW w:w=\"\(WordML.twips(width))\" w:type=\"dxa\"/>"
        if span > 1 { xml += "<w:gridSpan w:val=\"\(span)\"/>" }
        if let merge { xml += merge == "restart" ? "<w:vMerge w:val=\"restart\"/>" : "<w:vMerge/>" }

        let edges: [(String, NSRectEdge)] = [("top", .minY), ("left", .minX), ("bottom", .maxY), ("right", .maxX)]
        let borders = edges.compactMap { name, edge -> String? in
            let width = block.width(for: .border, edge: edge)
            guard width > 0 else { return nil }
            let color = block.borderColor(for: edge).flatMap(WordML.hex) ?? "000000"
            // Border widths are in eighths of a point, from 2 to 96.
            let size = min(max(Int((width * 8).rounded()), 2), 96)
            return "<w:\(name) w:val=\"single\" w:sz=\"\(size)\" w:space=\"0\" w:color=\"\(color)\"/>"
        }
        if !borders.isEmpty { xml += "<w:tcBorders>\(borders.joined())</w:tcBorders>" }

        if let background = block.backgroundColor, let fill = WordML.hex(background), background.alphaComponent > 0 {
            xml += "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"\(fill)\"/>"
        }

        let padding = edges.map { name, edge in (name, block.width(for: .padding, edge: edge)) }
        if padding.contains(where: { $0.1 > 0 }) {
            xml += "<w:tcMar>"
            for (name, width) in padding {
                xml += "<w:\(name) w:w=\"\(WordML.twips(width))\" w:type=\"dxa\"/>"
            }
            xml += "</w:tcMar>"
        }

        switch block.verticalAlignment {
        case .middleAlignment: xml += "<w:vAlign w:val=\"center\"/>"
        case .bottomAlignment: xml += "<w:vAlign w:val=\"bottom\"/>"
        default: break
        }
        return xml + "</w:tcPr>"
    }

    // MARK: Paragraphs

    private func writeParagraph(_ paragraph: Paragraph, into xml: inout String) {
        let style = paragraph.style
        var content = paragraph.content

        // A list item's marker is typed into the text by AppKit, but Word draws
        // its own from the numbering definition — so take AppKit's out.
        var list: (numID: Int, level: Int)?
        paragraphCounter += 1
        if let lists = style?.textLists, !lists.isEmpty {
            list = numberingRegistry.register(lists, paragraph: paragraphCounter)
            content = strippingMarker(from: content, lists: lists)
        }

        let markAttributes = string.length > 0
            ? text.attributes(at: min(paragraph.mark, string.length - 1), effectiveRange: nil)
            : [:]
        let first = string.length > 0
            ? text.attributes(at: min(paragraph.content.length > 0 ? paragraph.content.location : paragraph.mark, string.length - 1), effectiveRange: nil)
            : [:]
        let styleID = first[.wordParagraphStyle] as? String
        // A style copied from the original carries its own formatting, so
        // everything here is said outright rather than left to inherit.
        let explicit = styleID.map(sourceStyleIDs.contains) ?? false

        xml += "<w:p>"
        xml += paragraphProperties(style, list: list, markAttributes: markAttributes, styleID: styleID,
                                   extras: first[.wordParagraphExtras] as? String,
                                   keptSpacing: first[.wordParagraphSpacing] as? String, explicit: explicit)
        if let mark = pendingNoteMark {
            xml += mark
            pendingNoteMark = nil
        }
        writeRuns(in: content, explicit: explicit, into: &xml)

        // Bookmarks that close at, or mark, the end of the paragraph.
        let end = NSMaxRange(content)
        for location in end ... min(paragraph.mark + 1, max(end, string.length)) {
            for name in bookmarkPoints.removeValue(forKey: location) ?? [] {
                let id = bookmarkIDs[name] ?? 0
                xml += "<w:bookmarkStart w:id=\"\(id)\" w:name=\"\(WordML.escape(name))\"/><w:bookmarkEnd w:id=\"\(id)\"/>"
            }
            for name in bookmarkStarts.removeValue(forKey: location) ?? [] {
                xml += "<w:bookmarkStart w:id=\"\(bookmarkIDs[name] ?? 0)\" w:name=\"\(WordML.escape(name))\"/>"
                openBookmarks.insert(name)
            }
            for name in bookmarkEnds.removeValue(forKey: location) ?? [] where openBookmarks.contains(name) {
                xml += "<w:bookmarkEnd w:id=\"\(bookmarkIDs[name] ?? 0)\"/>"
                openBookmarks.remove(name)
            }
        }
        xml += "</w:p>"
    }

    /// Removes the `\t1.\t` AppKit puts at the start of a list item, when what's
    /// there really is a marker — the one this list would draw, or something
    /// that plainly looks like one.
    private func strippingMarker(from range: NSRange, lists: [NSTextList]) -> NSRange {
        guard range.length > 0 else { return range }

        // A marker the Word reader put there is labelled with its own text, so
        // it comes out exactly — and only when the paragraph still starts with
        // it, since text typed straight after a marker can inherit the label.
        if let marker = text.attribute(.wordListMarker, at: range.location, effectiveRange: nil) as? String,
           !marker.isEmpty, string.substring(with: range).hasPrefix(marker) {
            let length = min(marker.utf16.count, range.length)
            return NSRange(location: range.location + length, length: range.length - length)
        }

        let paragraph = string.substring(with: range)
        var scalars = Substring(paragraph)
        var consumed = 0

        while scalars.first == "\t" {
            scalars = scalars.dropFirst()
            consumed += 1
        }
        guard let tab = scalars.firstIndex(of: "\t") else { return range }
        let marker = String(scalars[..<tab])
        guard !marker.isEmpty, marker.count <= 16 else { return range }

        let list = lists[lists.count - 1]
        let item = text.itemNumber(in: list, at: range.location)
        let expected = list.marker(forItemNumber: item)
        let looksLikeMarker = marker == expected
            || marker.range(of: #"^[\(\[]?[0-9A-Za-z]{1,6}[\.\):\]]?$"#, options: .regularExpression) != nil
            || marker.unicodeScalars.allSatisfy { "•◦▪▫■□●○◆◇–-—*·✓✔➢➤▸►".unicodeScalars.contains($0) }
        guard looksLikeMarker else { return range }

        let removed = consumed + marker.utf16.count + 1
        return NSRange(location: range.location + removed, length: max(range.length - removed, 0))
    }

    private func paragraphProperties(
        _ style: NSParagraphStyle?,
        list: (numID: Int, level: Int)?,
        markAttributes: [NSAttributedString.Key: Any],
        styleID: String? = nil,
        extras: String? = nil,
        keptSpacing: String? = nil,
        explicit: Bool = false
    ) -> String {
        var xml = "<w:pPr>"

        let headerLevel = style?.headerLevel ?? 0
        if let styleID {
            xml += "<w:pStyle w:val=\"\(WordML.escape(styleID))\"/>"
            if (1 ... 6).contains(headerLevel) { xml += "<w:keepNext/>" }
        } else if (1 ... 6).contains(headerLevel) {
            xml += "<w:pStyle w:val=\"Heading\(headerLevel)\"/><w:keepNext/>"
        } else if let paragraphStyleOverride {
            xml += "<w:pStyle w:val=\"\(paragraphStyleOverride)\"/>"
        }

        // Kept verbatim: a drop cap's frame.
        if let extras { xml += extras }

        if let list {
            xml += "<w:numPr><w:ilvl w:val=\"\(list.level)\"/><w:numId w:val=\"\(list.numID)\"/></w:numPr>"
        } else if explicit {
            xml += "<w:numPr><w:ilvl w:val=\"0\"/><w:numId w:val=\"0\"/></w:numPr>"
        }

        // Borders and shading come from the paragraph's own text block.
        let box = style?.textBlocks.last { !($0 is NSTextTableBlock) }
        let offset = box.map(Self.contentOffset) ?? 0
        if let box {
            xml += borders(box)
            if let fill = box.backgroundColor.flatMap(WordML.hex) {
                xml += "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"\(fill)\"/>"
            } else if explicit {
                xml += "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"auto\"/>"
            }
        } else if explicit {
            xml += "<w:pBdr><w:top w:val=\"nil\"/><w:left w:val=\"nil\"/><w:bottom w:val=\"nil\"/><w:right w:val=\"nil\"/></w:pBdr>"
            xml += "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"auto\"/>"
        }

        if let style {
            // A list's own stops — the ones AppKit uses to place the marker and
            // then the text — are what the numbering's hanging indent does in
            // Word. Left in, Word would tab the text to the marker's stop.
            let stops = list == nil
                ? style.tabStops
                : style.tabStops.filter { $0.location > style.headIndent }
            if !stops.isEmpty, style.tabStops != NSParagraphStyle.default.tabStops {
                xml += "<w:tabs>"
                for tab in stops {
                    let kind: String = switch tab.alignment {
                    case .center: "center"
                    case .right: tab.options[.columnTerminators] != nil ? "decimal" : "right"
                    default: "left"
                    }
                    let leader = (tab.options[.wordLeader] as? String).map { " w:leader=\"\(WordML.escape($0))\"" } ?? ""
                    xml += "<w:tab w:val=\"\(kind)\"\(leader) w:pos=\"\(WordML.twips(tab.location + offset))\"/>"
                }
                xml += "</w:tabs>"
            }

            if style.baseWritingDirection == .rightToLeft { xml += "<w:bidi/>" }

            xml += keptSpacing ?? spacing(style, explicit: explicit)
            xml += indentation(style, isList: list != nil, level: list?.level ?? 0, box: box, explicit: explicit)

            switch style.alignment {
            case .center: xml += "<w:jc w:val=\"center\"/>"
            case .right: xml += "<w:jc w:val=\"\(style.baseWritingDirection == .rightToLeft ? "left" : "right")\"/>"
            case .justified: xml += "<w:jc w:val=\"both\"/>"
            case .left: xml += style.baseWritingDirection == .rightToLeft ? "<w:jc w:val=\"right\"/>" : (explicit ? "<w:jc w:val=\"left\"/>" : "")
            default: xml += explicit ? "<w:jc w:val=\"\(style.baseWritingDirection == .rightToLeft ? "right" : "left")\"/>" : ""
            }
        } else if let list {
            xml += indentation(nil, isList: true, level: list.level, box: nil, explicit: explicit)
        }

        if (1 ... 6).contains(headerLevel) {
            xml += "<w:outlineLvl w:val=\"\(headerLevel - 1)\"/>"
        } else if explicit {
            xml += "<w:outlineLvl w:val=\"9\"/>"
        }

        // The paragraph mark's own formatting, which is what gives an empty
        // line its height in Word.
        let mark = runProperties(markAttributes, includeStyle: false, explicit: explicit)
        if !mark.isEmpty { xml += "<w:rPr>\(mark)</w:rPr>" }

        xml += "</w:pPr>"
        return xml == "<w:pPr></w:pPr>" ? "" : xml
    }

    /// How far into its block a paragraph's text starts: the block's margin,
    /// border, and padding on the leading side. The reader moved the
    /// paragraph's indents into the block; this is what puts them back.
    private static func contentOffset(_ block: NSTextBlock) -> CGFloat {
        block.width(for: .margin, edge: .minX) + block.width(for: .border, edge: .minX) + block.width(for: .padding, edge: .minX)
    }

    private func borders(_ block: NSTextBlock) -> String {
        let styles = (block as? WordParagraphBlock)?.borderStyles ?? [:]
        let edges: [(String, NSRectEdge)] = [("top", .minY), ("left", .minX), ("bottom", .maxY), ("right", .maxX)]
        var xml = ""
        for (side, edge) in edges {
            let width = block.width(for: .border, edge: edge)
            guard width > 0 else { continue }
            let size = min(max(Int((width * 8).rounded()), 2), 96)
            let space = Int(block.width(for: .padding, edge: edge).rounded())
            let color = block.borderColor(for: edge).flatMap(WordML.hex) ?? "auto"
            xml += "<w:\(side) w:val=\"\(WordML.escape(styles[side] ?? "single"))\" w:sz=\"\(size)\" w:space=\"\(space)\" w:color=\"\(color)\"/>"
        }
        if let between = (block as? WordParagraphBlock)?.betweenBorder {
            let parts = between.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            if parts.count == 4 {
                let size = min(max(Int(((Double(parts[1]) ?? 0.5) * 8).rounded()), 2), 96)
                xml += "<w:between w:val=\"\(WordML.escape(parts[0]))\" w:sz=\"\(size)\" w:space=\"\(Int(Double(parts[2]) ?? 0))\" w:color=\"\(WordML.escape(parts[3]))\"/>"
            }
        }
        return xml.isEmpty ? "" : "<w:pBdr>\(xml)</w:pBdr>"
    }

    private func spacing(_ style: NSParagraphStyle, explicit: Bool = false) -> String {
        var attributes = ""
        if style.paragraphSpacingBefore > 0 || explicit {
            attributes += " w:before=\"\(WordML.twips(style.paragraphSpacingBefore))\""
        }
        if style.paragraphSpacing > 0 || explicit {
            attributes += " w:after=\"\(WordML.twips(style.paragraphSpacing))\""
        }
        if style.minimumLineHeight > 0, style.minimumLineHeight == style.maximumLineHeight {
            attributes += " w:line=\"\(WordML.twips(style.minimumLineHeight))\" w:lineRule=\"exact\""
        } else if style.minimumLineHeight > 0 {
            attributes += " w:line=\"\(WordML.twips(style.minimumLineHeight))\" w:lineRule=\"atLeast\""
        } else if style.lineHeightMultiple > 0, abs(style.lineHeightMultiple - 1) > 0.01 {
            attributes += " w:line=\"\(Int((style.lineHeightMultiple * 240).rounded()))\" w:lineRule=\"auto\""
        } else if explicit {
            attributes += " w:line=\"240\" w:lineRule=\"auto\""
        }
        return attributes.isEmpty ? "" : "<w:spacing\(attributes)/>"
    }

    private func indentation(_ style: NSParagraphStyle?, isList: Bool, level: Int, box: NSTextBlock? = nil, explicit: Bool = false) -> String {
        let offset = box.map(Self.contentOffset) ?? 0
        var left = (style?.headIndent ?? 0) + offset
        let first = (style?.firstLineHeadIndent ?? 0) + offset
        var hanging = left - first

        if isList {
            // AppKit draws a list's marker at the first tab stop past the
            // first-line indent, then tabs on to the text. Word draws it at
            // `left - hanging` — so the hanging indent is the distance from
            // that stop to the text.
            let marker = style?.tabStops.first { $0.location + offset > first && $0.location + offset < left }
                .map { $0.location + offset } ?? first
            hanging = left - marker
            // A list paragraph with flat indents would put the number on top
            // of the text; give it the room Word would.
            if hanging <= 0 {
                left = max(left, CGFloat(level + 1) * 36)
                hanging = 18
            }
        }

        var right: CGFloat = 0
        if let box {
            right = box.width(for: .margin, edge: .maxX) + box.width(for: .border, edge: .maxX) + box.width(for: .padding, edge: .maxX)
        } else if let tail = style?.tailIndent {
            // Positive tail indents are measured from the leading margin.
            right = tail < 0 ? -tail : (tail > 0 ? max(layout.textWidth - tail, 0) : 0)
        }

        var attributes = ""
        if left != 0 || explicit { attributes += " w:left=\"\(WordML.twips(left))\"" }
        if right > 0 || explicit { attributes += " w:right=\"\(WordML.twips(right))\"" }
        if hanging > 0 {
            attributes += " w:hanging=\"\(WordML.twips(hanging))\""
        } else if hanging < 0 {
            attributes += " w:firstLine=\"\(WordML.twips(-hanging))\""
        } else if explicit {
            attributes += " w:firstLine=\"0\""
        }
        return attributes.isEmpty ? "" : "<w:ind\(attributes)/>"
    }

    // MARK: Runs

    private func writeRuns(in range: NSRange, explicit: Bool = false, into xml: inout String) {
        guard range.length > 0 else { return }

        var openLink: String?
        var openControl: String?
        var pendingProperties = ""
        var pendingText = ""
        var pendingSymbolFont: String?

        func flushText() {
            guard !pendingText.isEmpty else { return }
            xml += "<w:r>"
            if !pendingProperties.isEmpty { xml += "<w:rPr>\(pendingProperties)</w:rPr>" }
            xml += runContent(pendingText, symbolFont: pendingSymbolFont)
            xml += "</w:r>"
            pendingText = ""
        }

        func setLink(_ link: String?) {
            guard link != openLink else { return }
            flushText()
            if openLink != nil { xml += "</w:hyperlink>" }
            if let link { xml += hyperlinkStart(link) }
            openLink = link
        }

        text.enumerateAttributes(in: range, options: []) { attributes, runRange, _ in
            // The number at the head of a note: Word draws its own.
            if attributes[.wordNoteLabel] != nil { return }

            // Bookmarks that start here — or mark this spot.
            if bookmarkPoints[runRange.location] != nil || bookmarkStarts[runRange.location] != nil {
                flushText()
                for name in bookmarkPoints.removeValue(forKey: runRange.location) ?? [] {
                    let id = bookmarkIDs[name] ?? 0
                    xml += "<w:bookmarkStart w:id=\"\(id)\" w:name=\"\(WordML.escape(name))\"/><w:bookmarkEnd w:id=\"\(id)\"/>"
                }
                for name in bookmarkStarts.removeValue(forKey: runRange.location) ?? [] {
                    xml += "<w:bookmarkStart w:id=\"\(bookmarkIDs[name] ?? 0)\" w:name=\"\(WordML.escape(name))\"/>"
                    openBookmarks.insert(name)
                }
            }

            // A content control inside the paragraph opens round its text.
            let control = attributes[.wordContentControl] as? String
            if let control, openControl == nil, controlBounds[control]?.start == runRange.location {
                setLink(nil)
                flushText()
                xml += "<w:sdt>" + Self.controlProperties(control) + "<w:sdtContent>"
                openControl = control
            }

            // A field's codes go round its result, outside any link, so the
            // result can carry links of its own — a table of contents does.
            let field = attributes[.wordField] as? String
            if let field, fieldBounds[field]?.start == runRange.location {
                setLink(nil)
                flushText()
                let instruction = WordML.escape(Self.fieldInstruction(field))
                xml += "<w:r><w:fldChar w:fldCharType=\"begin\"/></w:r>"
                xml += "<w:r><w:instrText xml:space=\"preserve\"> \(instruction) </w:instrText></w:r>"
                xml += "<w:r><w:fldChar w:fldCharType=\"separate\"/></w:r>"
            }
            defer {
                let end = NSMaxRange(runRange)
                if let field, fieldBounds[field]?.end == end {
                    setLink(nil)
                    flushText()
                    xml += "<w:r><w:fldChar w:fldCharType=\"end\"/></w:r>"
                }
                if let open = openControl, open == control, controlBounds[open]?.end == end {
                    setLink(nil)
                    flushText()
                    xml += "</w:sdtContent></w:sdt>"
                    openControl = nil
                }
                if let ending = bookmarkEnds[end], ending.contains(where: openBookmarks.contains) {
                    flushText()
                    for name in ending where openBookmarks.contains(name) {
                        xml += "<w:bookmarkEnd w:id=\"\(bookmarkIDs[name] ?? 0)\"/>"
                        openBookmarks.remove(name)
                    }
                    bookmarkEnds[end] = nil
                }
            }

            // A footnote or endnote reference becomes the real thing, provided
            // its note is still there to point at.
            // A second copy of the same mark is just its text.
            if let key = attributes[.wordNoteReference] as? String, let id = noteIDs[key],
               !emittedReferences.contains(key) {
                emittedReferences.insert(key)
                setLink(nil)
                flushText()
                let kind = key.hasPrefix("endnote") ? "endnote" : "footnote"
                let style = kind == "footnote" ? "FootnoteReference" : "EndnoteReference"
                xml += "<w:r><w:rPr><w:rStyle w:val=\"\(style)\"/></w:rPr><w:\(kind)Reference w:id=\"\(id)\"/></w:r>"
                return
            }

            let link = Self.linkTarget(attributes[.link])
            let runExplicit = explicit || (attributes[.wordCharacterStyle] as? String).map(sourceStyleIDs.contains) == true

            if let attachment = attributes[.attachment] as? NSTextAttachment {
                // An equation sits in the paragraph, not in a run — and not in
                // a hyperlink.
                let bare = (attachment as? PreservedObjectAttachment)?.xml.hasPrefix("<m:") == true
                setLink(bare ? nil : link)
                flushText()
                let properties = runProperties(attributes, includeStyle: link != nil, explicit: runExplicit)
                // An attachment run is one character; anything else in the
                // range is ordinary text that happens to share the attributes.
                let runText = string.substring(with: runRange)
                for character in runText {
                    if character == "\u{FFFC}" {
                        if let object = attachment as? PreservedObjectAttachment {
                            let kept = keptObject(object)
                            if bare {
                                xml += kept
                            } else {
                                xml += "<w:r>" + (properties.isEmpty ? "" : "<w:rPr>\(properties)</w:rPr>") + kept + "</w:r>"
                            }
                        } else if let content = attachment is HorizontalRuleAttachment
                            ? rule(attachment as! HorizontalRuleAttachment) : drawing(for: attachment) {
                            xml += "<w:r>"
                            if !properties.isEmpty { xml += "<w:rPr>\(properties)</w:rPr>" }
                            xml += content + "</w:r>"
                        }
                    } else {
                        pendingProperties = properties
                        pendingSymbolFont = nil
                        pendingText.append(character)
                        flushText()
                    }
                }
                return
            }

            setLink(link)
            let properties = runProperties(attributes, includeStyle: link != nil, explicit: runExplicit)
            if properties != pendingProperties {
                flushText()
                pendingProperties = properties
                pendingSymbolFont = (attributes[.font] as? NSFont)?.familyName.flatMap { SymbolFonts.isSymbolFont($0) ? $0 : nil }
            }
            // A stray object-replacement character with nothing attached is
            // invisible in the text view; keep it that way.
            pendingText += string.substring(with: runRange).replacingOccurrences(of: "\u{FFFC}", with: "")
        }

        flushText()
        if openLink != nil { xml += "</w:hyperlink>" }
        if openControl != nil { xml += "</w:sdtContent></w:sdt>" }
    }

    /// Text, with the characters that have element spellings in Word turned
    /// into those elements.
    private func runContent(_ text: String, symbolFont: String? = nil) -> String {
        var xml = ""
        var buffer = ""

        func flush() {
            guard !buffer.isEmpty else { return }
            xml += "<w:t xml:space=\"preserve\">\(WordML.escape(buffer))</w:t>"
            buffer = ""
        }

        for scalar in text.unicodeScalars {
            switch scalar {
            case "\t": flush(); xml += "<w:tab/>"
            case "\u{2028}", "\u{B}": flush(); xml += "<w:br/>"
            case "\u{C}": flush(); xml += "<w:br w:type=\"page\"/>"
            case "\u{AD}": flush(); xml += "<w:softHyphen/>"
            case "\u{2011}": flush(); xml += "<w:noBreakHyphen/>"
            case "\u{F000}" ... "\u{F0FF}" where symbolFont != nil:
                // A dingbat, the way Word writes one.
                flush()
                xml += "<w:sym w:font=\"\(WordML.escape(symbolFont!))\" w:char=\"\(String(format: "%04X", scalar.value))\"/>"
            default: buffer.unicodeScalars.append(scalar)
            }
        }
        flush()
        return xml
    }

    private static func linkTarget(_ value: Any?) -> String? {
        switch value {
        case let url as URL: url.absoluteString
        case let string as String where !string.isEmpty: string
        default: nil
        }
    }

    private func hyperlinkStart(_ target: String) -> String {
        if target.hasPrefix("#") {
            return "<w:hyperlink w:anchor=\"\(WordML.escape(String(target.dropFirst())))\" w:history=\"1\">"
        }
        let id: String
        if let existing = hyperlinkIDs[part]?[target] {
            id = existing
        } else {
            id = addRelationship(type: Self.hyperlinkRel, target: target, external: true)
            hyperlinkIDs[part, default: [:]][target] = id
        }
        return "<w:hyperlink r:id=\"\(id)\" w:history=\"1\">"
    }

    /// The `w:rPr` contents for a run, in the order the schema requires.
    ///
    /// `explicit` spells out what's off as well as what's on, for text whose
    /// Word style would otherwise lend it formatting it doesn't have here.
    private func runProperties(_ attributes: [NSAttributedString.Key: Any], includeStyle: Bool, explicit: Bool = false) -> String {
        var xml = ""
        if let characterStyle = attributes[.wordCharacterStyle] as? String {
            xml += "<w:rStyle w:val=\"\(WordML.escape(characterStyle))\"/>"
        } else if includeStyle {
            xml += "<w:rStyle w:val=\"Hyperlink\"/>"
        }

        let font = attributes[.font] as? NSFont
        if let font {
            let family = WordML.escape(Self.family(of: font, original: attributes[.wordFontName] as? String))
            xml += "<w:rFonts w:ascii=\"\(family)\" w:hAnsi=\"\(family)\" w:eastAsia=\"\(family)\" w:cs=\"\(family)\"/>"
            let traits = font.fontDescriptor.symbolicTraits
            let weight = (font.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any])?[.weight] as? CGFloat ?? 0
            if traits.contains(.bold) || weight >= 0.3 {
                xml += "<w:b/><w:bCs/>"
            } else if explicit {
                xml += "<w:b w:val=\"0\"/><w:bCs w:val=\"0\"/>"
            }
            if traits.contains(.italic) {
                xml += "<w:i/><w:iCs/>"
            } else if explicit {
                xml += "<w:i w:val=\"0\"/><w:iCs w:val=\"0\"/>"
            }
        }

        let caps = attributes[.wordCaps] as? String
        if caps == "caps" { xml += "<w:caps/>" } else if explicit { xml += "<w:caps w:val=\"0\"/>" }
        if caps == "smallCaps" { xml += "<w:smallCaps/>" } else if explicit { xml += "<w:smallCaps w:val=\"0\"/>" }

        if let strike = attributes[.strikethroughStyle] as? Int, strike != 0 {
            // `.double` is 0x9, which shares its low bit with `.single` — so this
            // has to be a containment test, not a bitwise and.
            xml += NSUnderlineStyle(rawValue: strike).contains(.double) ? "<w:dstrike/>" : "<w:strike/>"
        } else if explicit {
            xml += "<w:strike w:val=\"0\"/>"
        }
        if let stroke = attributes[.strokeWidth] as? CGFloat, stroke > 0 { xml += "<w:outline/>" }
        if attributes[.shadow] != nil { xml += "<w:shadow/>" }
        if attributes[.wordHidden] != nil { xml += "<w:vanish/>" } else if explicit { xml += "<w:vanish w:val=\"0\"/>" }

        if let color = attributes[.foregroundColor] as? NSColor, let hex = WordML.hex(color), hex != "000000" || explicit {
            xml += "<w:color w:val=\"\(hex)\"/>"
        }
        if let kern = attributes[.kern] as? CGFloat, kern != 0 {
            xml += "<w:spacing w:val=\"\(WordML.twips(kern))\"/>"
        }
        if let expansion = attributes[.expansion] as? CGFloat, expansion != 0 {
            let scale = Int((exp(expansion) * 100).rounded())
            if scale != 100 { xml += "<w:w w:val=\"\(min(max(scale, 1), 600))\"/>" }
        }
        if let offset = attributes[.baselineOffset] as? CGFloat, offset != 0, (attributes[.superscript] as? Int ?? 0) == 0 {
            xml += "<w:position w:val=\"\(Int((offset * 2).rounded()))\"/>"
        }
        if let font {
            // Word draws super- and subscript at about two thirds of the run's
            // size, so a run already shown small here goes out at the size Word
            // will shrink to what's on screen — not shrunk a second time. Small
            // capitals are drawn smaller here too, and saved at their real size.
            let shifted = (attributes[.superscript] as? Int ?? 0) != 0
            let points = (attributes[.wordCapsSize] as? CGFloat) ?? font.pointSize
            let size = Int((points * (shifted ? 3 : 2)).rounded())
            xml += "<w:sz w:val=\"\(size)\"/><w:szCs w:val=\"\(size)\"/>"
        }

        var shading: String?
        if let background = attributes[.backgroundColor] as? NSColor, background.alphaComponent > 0,
           let hex = WordML.hex(background) {
            if let highlight = WordML.highlights[hex] {
                xml += "<w:highlight w:val=\"\(highlight)\"/>"
            } else {
                shading = hex
            }
        }

        if let underline = attributes[.underlineStyle] as? Int, underline != 0 {
            let style = NSUnderlineStyle(rawValue: underline)
            let kind: String = if style.contains(.double) {
                "double"
            } else if style.contains(.thick) {
                "thick"
            } else if style.contains(.patternDot) {
                "dotted"
            } else if style.contains(.patternDash) || style.contains(.patternDashDot) || style.contains(.patternDashDotDot) {
                "dash"
            } else if style.contains(.byWord) {
                "words"
            } else {
                "single"
            }
            let color = (attributes[.underlineColor] as? NSColor).flatMap(WordML.hex)
            xml += "<w:u w:val=\"\(kind)\"\(color.map { " w:color=\"\($0)\"" } ?? "")/>"
        } else if explicit {
            xml += "<w:u w:val=\"none\"/>"
        }

        if let border = attributes[.wordRunBorder] as? String {
            let parts = border.split(separator: "|")
            let width = parts.first.flatMap { Double($0) } ?? 0.5
            let size = min(max(Int((width * 8).rounded()), 2), 96)
            let color = parts.count > 1 ? String(parts[1]) : "auto"
            xml += "<w:bdr w:val=\"single\" w:sz=\"\(size)\" w:space=\"0\" w:color=\"\(WordML.escape(color))\"/>"
        }

        if let shading { xml += "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"\(shading)\"/>" }

        if let superscript = attributes[.superscript] as? Int, superscript != 0 {
            xml += "<w:vertAlign w:val=\"\(superscript > 0 ? "superscript" : "subscript")\"/>"
        }
        return xml
    }

    /// The family name Word should look for. The system font's private names
    /// mean nothing outside macOS, so they're mapped to the nearest face every
    /// Mac and most other systems have.
    ///
    /// A run that was shown in a stand-in because this Mac lacks the typeface
    /// the document named — Calibri, usually — goes back out under that name,
    /// as long as it's still in the stand-in; if someone has since chosen a
    /// different font for it, that choice wins.
    static func family(of font: NSFont, original: String? = nil) -> String {
        let family = font.familyName ?? font.fontName
        if let original, family == WordML.standIn(for: original) { return original }
        guard family.hasPrefix(".") else { return family }
        return font.fontDescriptor.symbolicTraits.contains(.monoSpace) ? "Menlo" : "Helvetica Neue"
    }

    // MARK: Rules and kept objects

    /// A horizontal line, written as Word's own *Insert ▸ Horizontal Line*.
    private func rule(_ rule: HorizontalRuleAttachment) -> String {
        if let original = rule.originalXML {
            return original.replacingMatches(of: #"(<wp:docPr\b[^>]*?\bid=")(\d+)(")"#) { groups in
                drawingID += 1
                return "\(groups[1])\(drawingID)\(groups[3])"
            }
        }
        let height = String(format: "%.2fpt", rule.thickness)
        let percent = Int((rule.widthFraction * 1000).rounded())
        let align = rule.alignment == .left ? "left" : rule.alignment == .right ? "right" : "center"
        let fill = WordML.hex(rule.color) ?? "A0A0A0"
        // A coloured line is drawn flat; Word's standard one has a groove.
        let shade = fill == "A0A0A0" ? "" : " o:hrnoshade=\"t\""
        return "<w:pict><v:rect style=\"width:0;height:\(height)\" o:hralign=\"\(align)\" o:hrstd=\"t\"\(shade) "
            + "o:hrpct=\"\(percent)\" o:hr=\"t\" fillcolor=\"#\(fill)\" stroked=\"f\"/></w:pict>"
    }

    /// A kept object, as it came in — with its relationships given ids in this
    /// package, and its drawing ids renumbered so no two drawings share one.
    private func keptObject(_ object: PreservedObjectAttachment) -> String {
        var ids: [String: String] = [:]
        for relationship in object.relationships {
            ids[relationship.id] = relationship.external
                ? addRelationship(type: relationship.type, target: relationship.target, external: true)
                : addRelationship(type: relationship.type, target: Self.relativeToWord(relationship.target))
        }

        let prefixes = Set(object.namespaces.filter { $0.value == WordML.relationships }.map(\.key) + ["r"])
        var xml = object.xml.replacingMatches(of: #"(\s)([A-Za-z0-9]+):([A-Za-z]+)="([^"]*)""#) { groups in
            guard prefixes.contains(groups[2]), let id = ids[groups[4]] else { return groups[0] }
            return "\(groups[1])\(groups[2]):\(groups[3])=\"\(id)\""
        }
        xml = xml.replacingMatches(of: #"(<wp:docPr\b[^>]*?\bid=")(\d+)(")"#) { groups in
            drawingID += 1
            return "\(groups[1])\(drawingID)\(groups[3])"
        }
        return xml
    }

    // MARK: Pictures

    private func drawing(for attachment: NSTextAttachment) -> String? {
        guard let image = imagePart(for: attachment) else { return nil }

        drawingID += 1
        let id = drawingID
        let cx = WordML.emu(image.size.width)
        let cy = WordML.emu(image.size.height)
        let name = WordML.escape((image.path as NSString).lastPathComponent)

        return """
        <w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0"><wp:extent cx="\(cx)" cy="\(cy)"/>\
        <wp:effectExtent l="0" t="0" r="0" b="0"/><wp:docPr id="\(id)" name="Picture \(id)"/>\
        <wp:cNvGraphicFramePr><a:graphicFrameLocks noChangeAspect="1"/></wp:cNvGraphicFramePr>\
        <a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">\
        <pic:pic><pic:nvPicPr><pic:cNvPr id="\(id)" name="\(name)"/><pic:cNvPicPr/></pic:nvPicPr>\
        <pic:blipFill><a:blip r:embed="\(image.relationship)"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>\
        <pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(cx)" cy="\(cy)"/></a:xfrm>\
        <a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic></a:graphicData></a:graphic>\
        </wp:inline></w:drawing>
        """
    }

    private func imagePart(for attachment: NSTextAttachment) -> (path: String, relationship: String, size: CGSize)? {
        var data = attachment.fileWrapper?.regularFileContents ?? attachment.contents
        var format = data.flatMap(WordML.imageFormat(of:))
        var image = attachment.image ?? (attachment.attachmentCell as? NSTextAttachmentCell)?.image
        if image == nil, let data { image = NSImage(data: data) }

        // Word reads PNG, JPEG, GIF, BMP, and TIFF. Anything else — HEIC,
        // WebP, a PDF dropped in as a picture — goes out as PNG.
        if format == nil {
            guard let image, let png = Self.png(from: image) else { return nil }
            data = png
            format = ("png", "image/png")
        }
        guard let data, let format else { return nil }

        var size = attachment.bounds.size
        if size.width <= 0 || size.height <= 0 {
            size = (attachment.attachmentCell as? NSTextAttachmentCell)?.cellSize() ?? image?.size ?? .zero
        }
        if size.width <= 0 || size.height <= 0, let rep = NSBitmapImageRep(data: data) {
            size = CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        }
        guard size.width > 0, size.height > 0 else { return nil }

        let relationship: String
        let path: String
        if let existing = mediaByContent[part]?[data] {
            relationship = existing
            path = "word/" + (relationshipsByPart[part]?.first { $0.id == existing }?.target ?? "")
        } else {
            // One copy of the bytes per package, however many parts show them.
            if let shared = mediaByContent.values.lazy.compactMap({ $0[data] }).first,
               let target = relationshipsByPart.values.lazy.flatMap({ $0 }).first(where: { $0.id == shared && $0.type == Self.imageRel })?.target {
                path = "word/" + target
            } else {
                var counter = 1
                var candidate = "word/media/image\(counter).\(format.ext)"
                while usedPaths.contains(candidate) {
                    counter += 1
                    candidate = "word/media/image\(counter).\(format.ext)"
                }
                path = candidate
                usedPaths.insert(path)
                imageExtensions.insert(format.ext)
                extraParts.append(Part(path: path, data: data, compress: false))
            }
            relationship = addRelationship(type: Self.imageRel, target: String(path.dropFirst("word/".count)))
            mediaByContent[part, default: [:]][data] = relationship
        }

        return (path, relationship, size)
    }

    private static func png(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: Section

    private func sectionProperties() -> String {
        var xml = "<w:sectPr>"
        for (reference, id) in headerFooterRelationships {
            xml += "<w:\(reference.element) w:type=\"\(reference.type)\" r:id=\"\(id)\"/>"
        }

        // Settings the editor doesn't show — columns, page borders, line
        // numbering — come back from the original, slotted into the order the
        // schema requires. A printer-settings part isn't carried, so its
        // pointer isn't either.
        var extras: [String: String] = [:]
        for element in documentAttributes[.wordSectionExtras] as? [String] ?? [] {
            guard let name = element.captures(of: #"^<w:([A-Za-z]+)"#).first?[1] else { continue }
            extras[name, default: ""] += element
        }
        let width = WordML.twips(layout.paperWidth)
        let height = WordML.twips(layout.paperHeight)
        let orientation = layout.paperWidth > layout.paperHeight ? " w:orient=\"landscape\"" : ""

        for name in ["footnotePr", "endnotePr", "type", "pgSz", "pgMar", "paperSrc", "pgBorders", "lnNumType",
                     "pgNumType", "cols", "formProt", "vAlign", "noEndnote", "titlePg", "textDirection", "bidi",
                     "rtlGutter", "docGrid"] {
            switch name {
            case "pgSz":
                xml += "<w:pgSz w:w=\"\(width)\" w:h=\"\(height)\"\(orientation)/>"
            case "pgMar":
                xml += "<w:pgMar w:top=\"\(WordML.twips(layout.topMargin))\" w:right=\"\(WordML.twips(layout.rightMargin))\" "
                    + "w:bottom=\"\(WordML.twips(layout.bottomMargin))\" w:left=\"\(WordML.twips(layout.leftMargin))\" "
                    + "w:header=\"720\" w:footer=\"720\" w:gutter=\"0\"/>"
            case "cols":
                xml += extras["cols"] ?? "<w:cols w:space=\"720\"/>"
            case "titlePg":
                if carried?.titlePage == true { xml += "<w:titlePg/>" }
            default:
                xml += extras[name] ?? ""
            }
        }
        xml += "</w:sectPr>"
        return xml
    }

    // MARK: Other parts

    static let styleRel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles"
    static let settingsRel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/settings"
    static let numberingRel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering"
    static let hyperlinkRel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink"
    static let imageRel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/image"
    static let headerRel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/header"
    static let footerRel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/footer"
    static let footnotesRel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/footnotes"
    static let endnotesRel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/endnotes"

    func documentRelationships() -> String {
        relationships(for: "document")
    }

    /// The relationships of a note part, if it has any.
    func noteRelationships(_ part: String) -> String? {
        (relationshipsByPart[part] ?? []).isEmpty ? nil : relationships(for: part)
    }

    private func relationships(for part: String) -> String {
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
        xml += "<Relationships xmlns=\"\(WordML.packageRelationships)\">"
        for relationship in relationshipsByPart[part] ?? [] {
            let mode = relationship.external ? " TargetMode=\"External\"" : ""
            xml += "<Relationship Id=\"\(relationship.id)\" Type=\"\(relationship.type)\" "
                + "Target=\"\(WordML.escape(relationship.target))\"\(mode)/>"
        }
        return xml + "</Relationships>"
    }

    func contentTypes() -> String {
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
        xml += "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
        xml += "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>"
        xml += "<Default Extension=\"xml\" ContentType=\"application/xml\"/>"
        let mimes = ["png": "image/png", "jpeg": "image/jpeg", "jpg": "image/jpeg", "gif": "image/gif",
                     "bmp": "image/bmp", "tiff": "image/tiff", "tif": "image/tiff", "emf": "image/x-emf",
                     "wmf": "image/x-wmf", "svg": "image/svg+xml"]
        for ext in imageExtensions.sorted() {
            let mime = mimes[ext] ?? "application/octet-stream"
            xml += "<Default Extension=\"\(WordML.escape(ext))\" ContentType=\"\(mime)\"/>"
        }

        // One entry per part, however many reasons there are to list it.
        let wordprocessing = "application/vnd.openxmlformats-officedocument.wordprocessingml"
        var overrides = keptContentTypes.filter { !$0.key.hasSuffix(".rels") }
        overrides["word/document.xml"] = "\(wordprocessing).document.main+xml"
        overrides["word/styles.xml"] = "\(wordprocessing).styles+xml"
        overrides["word/settings.xml"] = "\(wordprocessing).settings+xml"
        overrides["word/numbering.xml"] = "\(wordprocessing).numbering+xml"
        if footnotesXML != nil { overrides["word/footnotes.xml"] = "\(wordprocessing).footnotes+xml" }
        if endnotesXML != nil { overrides["word/endnotes.xml"] = "\(wordprocessing).endnotes+xml" }
        for reference in carried?.references ?? [] {
            let kind = reference.element == "headerReference" ? "header" : "footer"
            overrides[reference.path] = "\(wordprocessing).\(kind)+xml"
        }
        overrides["docProps/core.xml"] = "application/vnd.openxmlformats-package.core-properties+xml"
        overrides["docProps/app.xml"] = "application/vnd.openxmlformats-officedocument.extended-properties+xml"
        for (path, type) in overrides.sorted(by: { $0.key < $1.key }) {
            xml += "<Override PartName=\"/\(WordML.escape(path))\" ContentType=\"\(WordML.escape(type))\"/>"
        }
        return xml + "</Types>"
    }

    /// The package's own relationships — the document, its properties, and
    /// custom properties carried from the original.
    func packageRelationships() -> String {
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
        xml += "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
        xml += "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/>"
        xml += "<Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties\" Target=\"docProps/core.xml\"/>"
        xml += "<Relationship Id=\"rId3\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties\" Target=\"docProps/app.xml\"/>"
        for (index, linked) in (carried?.packageParts ?? []).enumerated() {
            xml += "<Relationship Id=\"rId\(index + 4)\" Type=\"\(WordML.escape(linked.type))\" Target=\"\(WordML.escape(linked.path))\"/>"
        }
        return xml + "</Relationships>"
    }

    static let appProperties = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>\
    <Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties">\
    <Application>betterTextEdit</Application></Properties>
    """

    static func coreProperties(_ attributes: [NSAttributedString.DocumentAttributeKey: Any]) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let now = formatter.string(from: Date())
        let created = (attributes[.creationTime] as? Date).map(formatter.string(from:)) ?? now

        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
        xml += "<cp:coreProperties xmlns:cp=\"http://schemas.openxmlformats.org/package/2006/metadata/core-properties\" "
            + "xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:dcterms=\"http://purl.org/dc/terms/\" "
            + "xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\">"
        if let title = attributes[.title] as? String, !title.isEmpty {
            xml += "<dc:title>\(WordML.escape(title))</dc:title>"
        }
        if let subject = attributes[.subject] as? String, !subject.isEmpty {
            xml += "<dc:subject>\(WordML.escape(subject))</dc:subject>"
        }
        if let author = attributes[.author] as? String, !author.isEmpty {
            xml += "<dc:creator>\(WordML.escape(author))</dc:creator>"
        }
        if let keywords = attributes[.keywords] as? [String], !keywords.isEmpty {
            xml += "<cp:keywords>\(WordML.escape(keywords.joined(separator: ", ")))</cp:keywords>"
        }
        xml += "<dcterms:created xsi:type=\"dcterms:W3CDTF\">\(created)</dcterms:created>"
        xml += "<dcterms:modified xsi:type=\"dcterms:W3CDTF\">\(now)</dcterms:modified>"
        return xml + "</cp:coreProperties>"
    }

    func settings() -> String {
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
        xml += "<w:settings xmlns:w=\"\(WordML.main)\">"
        xml += "<w:defaultTabStop w:val=\"720\"/>"
        if carried?.evenAndOdd == true { xml += "<w:evenAndOddHeaders/>" }
        xml += "<w:characterSpacingControl w:val=\"doNotCompress\"/>"
        if footnotesXML != nil {
            xml += "<w:footnotePr><w:footnote w:id=\"-1\"/><w:footnote w:id=\"0\"/></w:footnotePr>"
        }
        if endnotesXML != nil {
            xml += "<w:endnotePr><w:endnote w:id=\"-1\"/><w:endnote w:id=\"0\"/></w:endnotePr>"
        }
        // Without this, Word opens the file in Compatibility Mode.
        xml += "<w:compat><w:compatSetting w:name=\"compatibilityMode\" "
            + "w:uri=\"http://schemas.microsoft.com/office/word\" w:val=\"15\"/></w:compat>"
        return xml + "</w:settings>"
    }

    /// Styles: document defaults matched to the body text, and the handful of
    /// named styles the body refers to. They carry structure, not looks — every
    /// run already says how it looks — so a heading is a heading to Word's
    /// navigation pane without Word restyling it.
    func styles() -> String {
        let family = WordML.escape(defaultFamily)
        let width = layout.textWidth
        let copied = copiedStyles()
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
        xml += "<w:styles xmlns:w=\"\(WordML.main)\">"
        xml += "<w:docDefaults><w:rPrDefault><w:rPr>"
        xml += "<w:rFonts w:ascii=\"\(family)\" w:hAnsi=\"\(family)\" w:eastAsia=\"\(family)\" w:cs=\"\(family)\"/>"
        xml += "<w:sz w:val=\"\(defaultHalfPoints)\"/><w:szCs w:val=\"\(defaultHalfPoints)\"/>"
        xml += "<w:lang w:val=\"en-US\" w:eastAsia=\"en-US\" w:bidi=\"ar-SA\"/>"
        xml += "</w:rPr></w:rPrDefault><w:pPrDefault><w:pPr>"
        xml += "<w:spacing w:after=\"0\" w:line=\"240\" w:lineRule=\"auto\"/>"
        xml += "</w:pPr></w:pPrDefault></w:docDefaults>"

        xml += "<w:style w:type=\"paragraph\" w:default=\"1\" w:styleId=\"Normal\"><w:name w:val=\"Normal\"/><w:qFormat/></w:style>"
        xml += "<w:style w:type=\"character\" w:default=\"1\" w:styleId=\"DefaultParagraphFont\">"
            + "<w:name w:val=\"Default Paragraph Font\"/><w:uiPriority w:val=\"1\"/><w:semiHidden/><w:unhideWhenUsed/></w:style>"
        xml += "<w:style w:type=\"table\" w:default=\"1\" w:styleId=\"TableNormal\"><w:name w:val=\"Normal Table\"/>"
            + "<w:uiPriority w:val=\"99\"/><w:semiHidden/><w:unhideWhenUsed/><w:tblPr><w:tblInd w:w=\"0\" w:type=\"dxa\"/>"
            + "<w:tblCellMar><w:top w:w=\"0\" w:type=\"dxa\"/><w:left w:w=\"108\" w:type=\"dxa\"/>"
            + "<w:bottom w:w=\"0\" w:type=\"dxa\"/><w:right w:w=\"108\" w:type=\"dxa\"/></w:tblCellMar></w:tblPr></w:style>"
        xml += "<w:style w:type=\"numbering\" w:default=\"1\" w:styleId=\"NoList\"><w:name w:val=\"No List\"/>"
            + "<w:uiPriority w:val=\"99\"/><w:semiHidden/><w:unhideWhenUsed/></w:style>"

        for level in 1 ... 6 where copied["Heading\(level)"] == nil {
            xml += "<w:style w:type=\"paragraph\" w:styleId=\"Heading\(level)\"><w:name w:val=\"heading \(level)\"/>"
                + "<w:basedOn w:val=\"Normal\"/><w:next w:val=\"Normal\"/><w:uiPriority w:val=\"9\"/><w:qFormat/>"
                + "<w:pPr><w:keepNext/><w:outlineLvl w:val=\"\(level - 1)\"/></w:pPr></w:style>"
        }

        if copied["Hyperlink"] == nil {
            xml += "<w:style w:type=\"character\" w:styleId=\"Hyperlink\"><w:name w:val=\"Hyperlink\"/>"
                + "<w:basedOn w:val=\"DefaultParagraphFont\"/><w:uiPriority w:val=\"99\"/><w:unhideWhenUsed/>"
                + "<w:rPr><w:color w:val=\"0563C1\"/><w:u w:val=\"single\"/></w:rPr></w:style>"
        }

        // Notes: the reference mark is raised; the text style is plain, since
        // every run says how it looks.
        for kind in ["Footnote", "Endnote"] {
            if copied["\(kind)Text"] == nil {
                xml += "<w:style w:type=\"paragraph\" w:styleId=\"\(kind)Text\"><w:name w:val=\"\(kind.lowercased()) text\"/>"
                    + "<w:basedOn w:val=\"Normal\"/><w:uiPriority w:val=\"99\"/><w:unhideWhenUsed/></w:style>"
            }
            if copied["\(kind)Reference"] == nil {
                xml += "<w:style w:type=\"character\" w:styleId=\"\(kind)Reference\"><w:name w:val=\"\(kind.lowercased()) reference\"/>"
                    + "<w:basedOn w:val=\"DefaultParagraphFont\"/><w:uiPriority w:val=\"99\"/><w:unhideWhenUsed/>"
                    + "<w:rPr><w:vertAlign w:val=\"superscript\"/></w:rPr></w:style>"
            }
        }

        // Headers and footers carried over from Word usually ask for these by
        // name, and lay out page numbers on their tab stops.
        for name in ["Header", "Footer"] where copied[name] == nil {
            xml += "<w:style w:type=\"paragraph\" w:styleId=\"\(name)\"><w:name w:val=\"\(name.lowercased())\"/>"
                + "<w:basedOn w:val=\"Normal\"/><w:uiPriority w:val=\"99\"/><w:unhideWhenUsed/><w:pPr><w:tabs>"
                + "<w:tab w:val=\"center\" w:pos=\"\(WordML.twips(width / 2))\"/>"
                + "<w:tab w:val=\"right\" w:pos=\"\(WordML.twips(width))\"/></w:tabs></w:pPr></w:style>"
        }

        for (_, definition) in copied.sorted(by: { $0.key < $1.key }) { xml += definition }
        return xml + "</w:styles>"
    }

    /// The styles the text names, as the original defined them — with what
    /// they're based on, linked to, and followed by — so Word still knows them
    /// by name. A style the original didn't define (the text came from
    /// somewhere else) gets a bare definition so the reference holds.
    ///
    /// The document defaults and Normal stay this writer's own: every run
    /// here says how it looks, and the original's defaults would otherwise
    /// seep into text that doesn't name a style.
    private func copiedStyles() -> [String: String] {
        let ownBase: Set<String> = ["Normal", "DefaultParagraphFont", "TableNormal", "NoList"]
        var result: [String: String] = [:]
        var queue = Array(usedStyleIDs)
        var seen = Set(queue)
        while let id = queue.popLast() {
            guard !ownBase.contains(id) else { continue }
            if let node = carried?.styles[id] {
                var definition = node.xml
                definition = definition.replacingMatches(of: #"<w:numPr>.*?</w:numPr>"#) { _ in "" }
                definition = definition.replacingMatches(of: #" w:default="(1|true|on)""#) { _ in "" }
                result[id] = definition
                for dependency in [node.value("w:basedOn"), node.value("w:link"), node.value("w:next")].compactMap({ $0 })
                    where !seen.contains(dependency) && carried?.styles[dependency] != nil {
                    seen.insert(dependency)
                    queue.append(dependency)
                }
            } else {
                let isCharacter = text.containsAttribute(.wordCharacterStyle, value: id)
                result[id] = "<w:style w:type=\"\(isCharacter ? "character" : "paragraph")\" w:customStyle=\"1\" "
                    + "w:styleId=\"\(WordML.escape(id))\"><w:name w:val=\"\(WordML.escape(id))\"/>"
                    + "<w:basedOn w:val=\"\(isCharacter ? "DefaultParagraphFont" : "Normal")\"/></w:style>"
            }
        }
        return result
    }

    func numbering() -> String {
        numberingRegistry.xml()
    }
}

// MARK: - Numbering

/// Turns AppKit's lists into Word numbering definitions.
///
/// AppKit describes a list item with a stack of `NSTextList`s — the outermost
/// list first — and consecutive items of one list share the same objects. Word
/// describes it with a numbering instance (`w:num`) pointing at an abstract
/// definition with up to nine levels. So each outermost list becomes one
/// instance — which is what makes a second, separate list start again from 1 —
/// and its nested lists supply the formats of the levels beneath.
private final class NumberingRegistry {
    private struct Level {
        var format: String // numFmt
        var text: String // lvlText
        var start: Int
    }

    private struct InstanceKey: Hashable {
        let list: ObjectIdentifier
        let run: Int
    }

    private var instances: [InstanceKey: Int] = [:]
    private var levels: [[Level?]] = []
    /// For each outermost list: the paragraph it last appeared in, and which
    /// unbroken run of it that was.
    private var lastSeen: [ObjectIdentifier: (paragraph: Int, run: Int)] = [:]

    /// The two systems disagree about a list that's interrupted by an ordinary
    /// paragraph. AppKit starts it again from the top — that's what its
    /// `itemNumber(in:at:)` reports, and what the markers typed into the text
    /// say. Word carries on counting. So a list made here gets a fresh Word
    /// instance after each interruption; a list read from Word keeps one
    /// instance throughout, because carrying on is what it did in Word.
    func register(_ lists: [NSTextList], paragraph: Int) -> (numID: Int, level: Int) {
        let outer = ObjectIdentifier(lists[0])
        var run = lastSeen[outer]?.run ?? 0
        if !(lists[0] is WordTextList), let last = lastSeen[outer], last.paragraph < paragraph - 1 {
            run += 1
        }
        lastSeen[outer] = (paragraph, run)

        let key = InstanceKey(list: outer, run: run)
        let index: Int
        if let existing = instances[key] {
            index = existing
        } else {
            index = levels.count
            instances[key] = index
            levels.append([Level?](repeating: nil, count: 9))
        }

        let depth = min(lists.count, 9)
        for level in 0 ..< depth where levels[index][level] == nil {
            levels[index][level] = Self.level(for: lists[level], at: level, prepend: lists[level].listOptions.contains(.prependEnclosingMarker))
        }
        return (index + 1, depth - 1)
    }

    private static func level(for list: NSTextList, at level: Int, prepend: Bool) -> Level {
        let format = list.markerFormat.rawValue
        let start = max(list.startingItemNumber, 1)

        // A list read from Word remembers exactly how Word spelled it.
        if let word = list as? WordTextList {
            return Level(format: word.wordFormat, text: word.wordLevelText, start: start)
        }

        guard let open = format.firstIndex(of: "{"), let close = format[open...].firstIndex(of: "}") else {
            // A literal marker with no counter in it at all.
            return Level(format: "bullet", text: format.isEmpty ? "•" : format, start: start)
        }

        let token = String(format[format.index(after: open) ..< close])
        let prefix = String(format[..<open])
        let suffix = String(format[format.index(after: close)...])

        let bullets = ["disc": "•", "circle": "◦", "square": "▪", "hyphen": "–", "check": "✓", "box": "□", "diamond": "◆"]
        if let bullet = bullets[token] {
            return Level(format: "bullet", text: prefix + bullet + suffix, start: start)
        }

        let numberFormat: String = switch token {
        case "lower-alpha", "lower-latin": "lowerLetter"
        case "upper-alpha", "upper-latin": "upperLetter"
        case "lower-roman": "lowerRoman"
        case "upper-roman": "upperRoman"
        default: "decimal" // decimal, and the octal and hex forms Word has no spelling for
        }

        var counter = "%\(level + 1)"
        if prepend, level > 0 {
            counter = (1 ... level).map { "%\($0)." }.joined() + counter
        }
        return Level(format: numberFormat, text: prefix + counter + suffix, start: start)
    }

    func xml() -> String {
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
        xml += "<w:numbering xmlns:w=\"\(WordML.main)\">"
        for (index, definition) in levels.enumerated() {
            xml += "<w:abstractNum w:abstractNumId=\"\(index)\"><w:multiLevelType w:val=\"hybridMultilevel\"/>"
            for level in 0 ..< 9 {
                // Levels nobody used still need a definition; fill them the way
                // Word does, alternating numbers and bullets.
                let entry = definition[level] ?? Level(
                    format: level.isMultiple(of: 2) ? "decimal" : "bullet",
                    text: level.isMultiple(of: 2) ? "%\(level + 1)." : "◦",
                    start: 1
                )
                let left = 720 * (level + 1)
                xml += "<w:lvl w:ilvl=\"\(level)\"><w:start w:val=\"\(entry.start)\"/>"
                xml += "<w:numFmt w:val=\"\(entry.format)\"/>"
                xml += "<w:lvlText w:val=\"\(WordML.escape(entry.text))\"/>"
                xml += "<w:lvlJc w:val=\"left\"/>"
                xml += "<w:pPr><w:ind w:left=\"\(left)\" w:hanging=\"360\"/></w:pPr>"
                xml += "</w:lvl>"
            }
            xml += "</w:abstractNum>"
        }
        for index in levels.indices {
            xml += "<w:num w:numId=\"\(index + 1)\"><w:abstractNumId w:val=\"\(index)\"/></w:num>"
        }
        return xml + "</w:numbering>"
    }
}
