import AppKit
import Foundation

/// Reads a Word document into formatted text, without going through AppKit.
///
/// macOS's own Office Open XML reader gets the broad strokes — fonts, sizes,
/// paragraphs, tables — and drops a great deal of the rest: every list comes
/// back as a bulleted one whatever Word numbered it, hyperlinks lose their
/// destinations, pictures vanish, highlighting and shading disappear, headings
/// stop being headings, and colours drift because they're read in the wrong
/// colour space.
///
/// This reader walks the package itself. It resolves formatting the way Word
/// does — document defaults, then the paragraph style and everything it's
/// based on, then the character style, then what's set directly on the run —
/// and it numbers lists by running Word's own counters over `numbering.xml`.
/// Pictures are placed exactly where their drawing sits in the text, at the
/// size Word displays them. Fields show their results; a `HYPERLINK` field
/// becomes a link. Tracked changes are shown accepted. Footnotes and endnotes
/// are gathered at the end. Text boxes follow the paragraph they're anchored to.
///
/// The result is built in AppKit's own vocabulary — `NSTextList`, `NSTextTable`,
/// `NSTextAttachment` — so the text view edits it natively, and `DocxWriter`
/// can turn it straight back into the same Word structures.
enum DocxReader {
    struct Result {
        let text: NSAttributedString
        let documentAttributes: [NSAttributedString.DocumentAttributeKey: Any]
        /// Parts of the package that never reached the text, by name — so a
        /// save over the original can say what it would lose.
        let unsupported: [String]
        let imageCount: Int
    }

    enum ReadError: Error {
        case notAPackage
        case noDocument
        case malformed
    }

    static func read(_ url: URL) throws -> Result {
        guard let archive = ZipArchive(url: url) else { throw ReadError.notAPackage }
        return try read(archive)
    }

    static func read(_ archive: ZipArchive) throws -> Result {
        // The main part is whatever the package relationships say it is — it's
        // `word/document.xml` in practice, but templates and macro-enabled
        // documents are entitled to call it something else.
        let packageRels = RelationshipTargets(archive.contents(named: "_rels/.rels"))
        let mainPath = packageRels.types.first { $0.value.hasSuffix("/officeDocument") }
            .flatMap { packageRels.inside[$0.key] }
            .map { PackagePath.resolve($0, from: "") } ?? "word/document.xml"

        guard let documentData = archive.contents(named: mainPath) else { throw ReadError.noDocument }
        guard let document = XMLTree.parse(documentData) else { throw ReadError.malformed }

        let context = ReadContext(archive: archive, mainPath: mainPath)
        context.namespaces = document.namespaces
        let builder = DocumentBuilder(context: context)
        builder.build(document)

        return Result(
            text: builder.output,
            documentAttributes: builder.documentAttributes(),
            unsupported: context.unsupportedFeatures(document: document),
            imageCount: builder.imageCount
        )
    }
}

// MARK: - A small XML tree

/// Just enough of a DOM to walk WordprocessingML: element names normalised to
/// their conventional prefixes whatever the file actually used, attributes by
/// local name, and text.
///
/// Normalising is what makes the reader work on every writer's output. Word
/// always says `w:p`, but the schema only fixes the namespace, not the prefix,
/// and ISO 29500 Strict documents use different namespace URIs altogether.
final class XMLTree {
    let name: String
    var attributes: [String: String]
    var children: [XMLTree] = []
    var text = ""
    /// The element's name and attributes exactly as written, for writing the
    /// element back out verbatim — see `xml`.
    var qualifiedName = ""
    var rawAttributes: [String: String] = [:]
    /// Every namespace prefix the part declared, gathered at the root.
    var namespaces: [String: String] = [:]
    /// Which element of this name this is, counting from the start of the
    /// part — how its exact text is found again in `source`.
    var ordinal = 0
    /// The part's text, shared by every element parsed from it.
    var source: XMLSource?

    /// The part's text, kept so elements can be copied out of it byte for byte.
    final class XMLSource {
        let text: String
        init(_ text: String) { self.text = text }
    }

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    /// The element exactly as it appears in the part — every byte, every
    /// attribute in its original order.
    ///
    /// This matters for more than tidiness. Word keeps a checksum of a VML
    /// shape beside the DrawingML it really draws from, and if the VML has been
    /// rewritten — even just reordered — it ignores the DrawingML and draws the
    /// plain fallback. A horizontal line that was grey and grooved comes back
    /// black. So anything kept whole is cut from the original text, not
    /// rebuilt from the parse.
    var originalXML: String? {
        guard let text = source?.text else { return nil }
        let opening = "<" + qualifiedName
        let closing = "</" + qualifiedName + ">"

        func isStart(_ range: Range<String.Index>) -> Bool {
            guard range.upperBound < text.endIndex else { return false }
            return [" ", ">", "/", "\t", "\n", "\r"].contains(text[range.upperBound])
        }

        // The nth start tag with this name.
        var cursor = text.startIndex
        var seen = -1
        var start: String.Index?
        while let found = text.range(of: opening, range: cursor ..< text.endIndex) {
            cursor = found.upperBound
            guard isStart(found) else { continue }
            seen += 1
            if seen == ordinal { start = found.lowerBound; break }
        }
        guard let start else { return nil }

        // Its end: the matching close tag, counting nested ones of the same name.
        guard let tagEnd = text.range(of: ">", range: start ..< text.endIndex) else { return nil }
        if text[text.index(before: tagEnd.lowerBound)] == "/" { return String(text[start ..< tagEnd.upperBound]) }
        var depth = 1
        cursor = tagEnd.upperBound
        while depth > 0 {
            let nextOpen = text.range(of: opening, range: cursor ..< text.endIndex)
            guard let nextClose = text.range(of: closing, range: cursor ..< text.endIndex) else { return nil }
            if let nextOpen, nextOpen.lowerBound < nextClose.lowerBound {
                cursor = nextOpen.upperBound
                if isStart(nextOpen), let end = text.range(of: ">", range: nextOpen.upperBound ..< text.endIndex),
                   text[text.index(before: end.lowerBound)] != "/" {
                    depth += 1
                }
            } else {
                depth -= 1
                cursor = nextClose.upperBound
            }
        }
        return String(text[start ..< cursor])
    }

    /// The element as XML, with its original prefixes. Text is kept only in
    /// leaf elements — which is the only place WordprocessingML puts any; the
    /// rest is indentation.
    var xml: String {
        var result = "<" + qualifiedName
        for (key, value) in rawAttributes.sorted(by: { $0.key < $1.key }) {
            result += " \(key)=\"\(WordML.escapeAttribute(value))\""
        }
        if children.isEmpty, text.isEmpty { return result + "/>" }
        result += ">"
        if children.isEmpty {
            result += WordML.escape(text)
        } else {
            for child in children { result += child.xml }
        }
        return result + "</\(qualifiedName)>"
    }

    func child(_ name: String) -> XMLTree? {
        children.first { $0.name == name }
    }

    func children(_ name: String) -> [XMLTree] {
        children.filter { $0.name == name }
    }

    subscript(attribute: String) -> String? {
        attributes[attribute]
    }

    /// The `w:val` of a child, which is how most properties are spelled.
    func value(_ child: String) -> String? {
        self.child(child)?["val"]
    }

    /// Every descendant with this name, depth first.
    func descendants(_ name: String) -> [XMLTree] {
        var found: [XMLTree] = []
        var stack = children.reversed() as [XMLTree]
        while let node = stack.popLast() {
            if node.name == name { found.append(node) }
            stack.append(contentsOf: node.children.reversed())
        }
        return found
    }

    var allText: String {
        children.isEmpty ? text : text + children.map(\.allText).joined()
    }

    static let prefixes: [String: String] = [
        "http://schemas.openxmlformats.org/wordprocessingml/2006/main": "w",
        "http://purl.oclc.org/ooxml/wordprocessingml/main": "w",
        "http://schemas.openxmlformats.org/officeDocument/2006/relationships": "r",
        "http://purl.oclc.org/ooxml/officeDocument/relationships": "r",
        "http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing": "wp",
        "http://purl.oclc.org/ooxml/drawingml/wordprocessingDrawing": "wp",
        "http://schemas.openxmlformats.org/drawingml/2006/main": "a",
        "http://purl.oclc.org/ooxml/drawingml/main": "a",
        "http://schemas.openxmlformats.org/drawingml/2006/picture": "pic",
        "http://purl.oclc.org/ooxml/drawingml/picture": "pic",
        "http://schemas.openxmlformats.org/markup-compatibility/2006": "mc",
        "urn:schemas-microsoft-com:vml": "v",
        "urn:schemas-microsoft-com:office:office": "o",
        "http://schemas.openxmlformats.org/officeDocument/2006/math": "m",
        "http://purl.oclc.org/ooxml/officeDocument/math": "m",
        "http://schemas.microsoft.com/office/word/2010/wordprocessingShape": "wps",
        "http://schemas.microsoft.com/office/word/2010/wordprocessingGroup": "wpg",
        "http://schemas.openxmlformats.org/package/2006/relationships": "rel",
        "http://schemas.openxmlformats.org/package/2006/metadata/core-properties": "cp",
        "http://purl.org/dc/elements/1.1/": "dc",
        "http://schemas.microsoft.com/office/word/2010/wordml": "w14",
    ]

    static func parse(_ data: Data) -> XMLTree? {
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = true
        let builder = Builder()
        builder.source = XMLSource(String(decoding: data, as: UTF8.self))
        parser.delegate = builder
        // A half-read part is worse than none: it would open as a document that
        // looks complete and save back missing everything after the error.
        guard parser.parse() else { return nil }
        builder.root?.namespaces = builder.namespaces
        return builder.root
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var root: XMLTree?
        var namespaces: [String: String] = [:]
        var source: XMLSource?
        private var stack: [XMLTree] = []
        private var counts: [String: Int] = [:]

        func parser(_: XMLParser, didStartMappingPrefix prefix: String, toURI uri: String) {
            if namespaces[prefix] == nil { namespaces[prefix] = uri }
        }

        func parser(_: XMLParser, didStartElement element: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String]) {
            let prefix = namespaceURI.flatMap { XMLTree.prefixes[$0] } ?? "?"
            var local: [String: String] = [:]
            for (key, value) in attributes {
                let name = key.split(separator: ":").last.map(String.init) ?? key
                // `xml:space` and friends aren't formatting; everything else is
                // looked up by its local name.
                if local[name] == nil || key.hasPrefix("w:") { local[name] = value }
            }
            let node = XMLTree(name: "\(prefix):\(element)", attributes: local)
            node.qualifiedName = qualifiedName ?? element
            node.rawAttributes = attributes
            node.ordinal = counts[node.qualifiedName, default: 0]
            counts[node.qualifiedName, default: 0] += 1
            node.source = source
            if let parent = stack.last {
                parent.children.append(node)
            } else {
                root = node
            }
            stack.append(node)
        }

        func parser(_: XMLParser, foundCharacters string: String) {
            stack.last?.text += string
        }

        func parser(_: XMLParser, didEndElement _: String, namespaceURI _: String?, qualifiedName _: String?) {
            stack.removeLast()
        }
    }
}

// MARK: - Measures

private enum Measure {
    /// A Word measure in points. Transitional files give bare numbers in the
    /// unit the attribute calls for; Strict ones may spell the unit out.
    static func points(_ value: String?, unit: CGFloat) -> CGFloat? {
        guard let value, !value.isEmpty else { return nil }
        let suffixes: [(String, CGFloat)] = [("pt", 1), ("in", 72), ("cm", 72 / 2.54), ("mm", 72 / 25.4), ("pc", 12), ("pi", 12)]
        for (suffix, scale) in suffixes where value.hasSuffix(suffix) {
            return Double(value.dropLast(suffix.count)).map { CGFloat($0) * scale }
        }
        return Double(value).map { CGFloat($0) * unit }
    }

    static func twips(_ value: String?) -> CGFloat? { points(value, unit: 1.0 / 20) }
    static func halfPoints(_ value: String?) -> CGFloat? { points(value, unit: 0.5) }
    static func eighths(_ value: String?) -> CGFloat? { points(value, unit: 1.0 / 8) }
    static func emu(_ value: String?) -> CGFloat? { points(value, unit: 1.0 / 12_700) }

    /// An on/off property: present with no value means on.
    static func isOn(_ node: XMLTree?) -> Bool? {
        guard let node else { return nil }
        guard let value = node["val"] else { return true }
        return !["0", "false", "off", "none"].contains(value.lowercased())
    }
}

// MARK: - Properties

/// Run formatting, every field optional so that each layer of the style
/// hierarchy only says what it sets.
private struct RunProperties {
    var font: String?
    var fontTheme: String?
    var eastAsiaFont: String?
    var size: CGFloat?
    var bold: Bool?
    var italic: Bool?
    var underline: String?
    var underlineColor: String?
    var strike: Bool?
    var doubleStrike: Bool?
    var color: String?
    var highlight: String?
    var shading: String?
    var verticalAlign: String?
    var position: CGFloat?
    var spacing: CGFloat?
    var hidden: Bool?
    var shadow: Bool?
    var caps: Bool?
    var smallCaps: Bool?
    var outline: Bool?
    /// Horizontal scale as a percentage (`w:w`).
    var scale: CGFloat?
    /// A box round the run (`w:bdr`), as `width|RRGGBB`.
    var border: String?
    /// The size from which Word kerns type (`w:kern`). Below it, and when it
    /// isn't set, Word doesn't kern at all.
    var kernFrom: CGFloat?
    /// The ligatures Word sets (`w14:ligatures`): none unless asked for.
    var ligatures: String?

    init() {}

    init(_ node: XMLTree?) {
        guard let node else { return }
        if let fonts = node.child("w:rFonts") {
            font = fonts["ascii"] ?? fonts["hAnsi"]
            fontTheme = fonts["asciiTheme"] ?? fonts["hAnsiTheme"]
            eastAsiaFont = fonts["eastAsia"]
        }
        size = Measure.halfPoints(node.value("w:sz"))
        bold = Measure.isOn(node.child("w:b"))
        italic = Measure.isOn(node.child("w:i"))
        if let u = node.child("w:u") {
            underline = u["val"] ?? "single"
            underlineColor = u["color"]
        }
        strike = Measure.isOn(node.child("w:strike"))
        doubleStrike = Measure.isOn(node.child("w:dstrike"))
        color = node.value("w:color")
        highlight = node.value("w:highlight")
        if let fill = node.child("w:shd")?["fill"], fill.lowercased() != "auto" { shading = fill }
        verticalAlign = node.value("w:vertAlign")
        position = Measure.halfPoints(node.value("w:position"))
        spacing = Measure.twips(node.value("w:spacing"))
        hidden = Measure.isOn(node.child("w:vanish"))
        shadow = Measure.isOn(node.child("w:shadow"))
        caps = Measure.isOn(node.child("w:caps"))
        smallCaps = Measure.isOn(node.child("w:smallCaps"))
        outline = Measure.isOn(node.child("w:outline"))
        scale = node.value("w:w").flatMap { Double($0.replacingOccurrences(of: "%", with: "")) }.map { CGFloat($0) }
        if let bdr = node.child("w:bdr"), let style = bdr["val"] {
            border = ["nil", "none"].contains(style)
                ? "none"
                : "\(Measure.eighths(bdr["sz"]) ?? 0.5)|\(bdr["color"].flatMap { $0.lowercased() == "auto" ? nil : $0 } ?? "000000")"
        }
        kernFrom = Measure.halfPoints(node.value("w:kern"))
        ligatures = node.value("w14:ligatures")
    }

    /// Lays `other` over this, keeping whatever it doesn't set.
    func merged(with other: RunProperties) -> RunProperties {
        var result = self
        if other.font != nil || other.fontTheme != nil {
            result.font = other.font
            result.fontTheme = other.fontTheme
        }
        result.eastAsiaFont = other.eastAsiaFont ?? eastAsiaFont
        result.size = other.size ?? size
        result.bold = other.bold ?? bold
        result.italic = other.italic ?? italic
        result.underline = other.underline ?? underline
        result.underlineColor = other.underlineColor ?? underlineColor
        result.strike = other.strike ?? strike
        result.doubleStrike = other.doubleStrike ?? doubleStrike
        result.color = other.color ?? color
        result.highlight = other.highlight ?? highlight
        result.shading = other.shading ?? shading
        result.verticalAlign = other.verticalAlign ?? verticalAlign
        result.position = other.position ?? position
        result.spacing = other.spacing ?? spacing
        result.hidden = other.hidden ?? hidden
        result.shadow = other.shadow ?? shadow
        result.caps = other.caps ?? caps
        result.smallCaps = other.smallCaps ?? smallCaps
        result.outline = other.outline ?? outline
        result.scale = other.scale ?? scale
        result.border = other.border ?? border
        result.kernFrom = other.kernFrom ?? kernFrom
        result.ligatures = other.ligatures ?? ligatures
        return result
    }
}

private struct ParagraphProperties {
    struct Tab {
        let kind: String
        let position: CGFloat
        var leader: String?
    }

    /// One side of a paragraph border: Word's line style, its width, the gap
    /// between it and the text, and its colour.
    struct Border: Equatable {
        let style: String
        let width: CGFloat
        let space: CGFloat
        let color: String?
    }

    var alignment: String?
    var left: CGFloat?
    var right: CGFloat?
    var firstLine: CGFloat?
    var hanging: CGFloat?
    var before: CGFloat?
    var after: CGFloat?
    var beforeAuto: Bool?
    var afterAuto: Bool?
    var line: CGFloat?
    var lineRule: String?
    var tabs: [Tab]?
    var clearedTabs: [CGFloat] = []
    var numID: String?
    var level: Int?
    var outlineLevel: Int?
    var bidi: Bool?
    var pageBreakBefore: Bool?
    var keepNext: Bool?
    var keepLines: Bool?
    var widowControl: Bool?
    var contextual: Bool?
    /// Paragraph borders by side — `top`, `left`, `bottom`, `right`, `between`.
    var borders: [String: Border] = [:]
    var shading: String?
    /// A frame — the device Word builds drop caps from — kept as raw XML.
    var frame: String?
    var runProperties = RunProperties()

    init() {}

    init(_ node: XMLTree?) {
        guard let node else { return }
        alignment = node.value("w:jc")
        if let ind = node.child("w:ind") {
            left = Measure.twips(ind["left"] ?? ind["start"])
            right = Measure.twips(ind["right"] ?? ind["end"])
            firstLine = Measure.twips(ind["firstLine"])
            hanging = Measure.twips(ind["hanging"])
        }
        if let spacing = node.child("w:spacing") {
            before = Measure.twips(spacing["before"])
            after = Measure.twips(spacing["after"])
            beforeAuto = spacing["beforeAutospacing"].map { $0 == "1" || $0 == "true" || $0 == "on" }
            afterAuto = spacing["afterAutospacing"].map { $0 == "1" || $0 == "true" || $0 == "on" }
            lineRule = spacing["lineRule"]
            if let raw = spacing["line"] {
                // `auto` lines are in 240ths of a line; the others in twips.
                line = (lineRule ?? "auto") == "auto" ? Double(raw).map { CGFloat($0) / 240 } : Measure.twips(raw)
            }
        }
        if let tabs = node.child("w:tabs") {
            var kept: [Tab] = []
            for tab in tabs.children("w:tab") {
                guard let position = Measure.twips(tab["pos"]) else { continue }
                if tab["val"] == "clear" {
                    clearedTabs.append(position)
                } else {
                    let leader = tab["leader"].flatMap { $0 == "none" ? nil : $0 }
                    kept.append(Tab(kind: tab["val"] ?? "left", position: position, leader: leader))
                }
            }
            self.tabs = kept
        }
        if let numPr = node.child("w:numPr") {
            numID = numPr.value("w:numId")
            level = numPr.value("w:ilvl").flatMap { Int($0) }
        }
        outlineLevel = node.value("w:outlineLvl").flatMap { Int($0) }
        bidi = Measure.isOn(node.child("w:bidi"))
        pageBreakBefore = Measure.isOn(node.child("w:pageBreakBefore"))
        keepNext = Measure.isOn(node.child("w:keepNext"))
        keepLines = Measure.isOn(node.child("w:keepLines"))
        widowControl = Measure.isOn(node.child("w:widowControl"))
        contextual = Measure.isOn(node.child("w:contextualSpacing"))
        if let pBdr = node.child("w:pBdr") {
            for (side, names) in [("top", ["w:top"]), ("left", ["w:left", "w:start"]), ("bottom", ["w:bottom"]),
                                  ("right", ["w:right", "w:end"]), ("between", ["w:between"])] {
                guard let edge = names.lazy.compactMap({ pBdr.child($0) }).first, let style = edge["val"] else { continue }
                borders[side] = Border(
                    style: style,
                    width: Measure.eighths(edge["sz"]) ?? 0.5,
                    space: Measure.points(edge["space"], unit: 1) ?? 0,
                    color: edge["color"].flatMap { $0.lowercased() == "auto" ? nil : $0 }
                )
            }
        }
        if let fill = node.child("w:shd")?["fill"], fill.lowercased() != "auto" { shading = fill }
        if let frame = node.child("w:framePr") { self.frame = frame.xml }
        runProperties = RunProperties(node.child("w:rPr"))
    }

    func merged(with other: ParagraphProperties) -> ParagraphProperties {
        var result = self
        result.alignment = other.alignment ?? alignment
        result.left = other.left ?? left
        result.right = other.right ?? right
        // First-line and hanging are two spellings of one value; whichever the
        // nearer layer gives replaces both.
        if other.firstLine != nil || other.hanging != nil {
            result.firstLine = other.firstLine
            result.hanging = other.hanging
        }
        result.before = other.before ?? before
        result.after = other.after ?? after
        result.beforeAuto = other.beforeAuto ?? beforeAuto
        result.afterAuto = other.afterAuto ?? afterAuto
        if other.line != nil {
            result.line = other.line
            result.lineRule = other.lineRule
        }
        if let tabs = other.tabs {
            let cleared = Set(other.clearedTabs.map { Int($0.rounded()) })
            let inherited = (self.tabs ?? []).filter { !cleared.contains(Int($0.position.rounded())) }
            result.tabs = (inherited + tabs).sorted { $0.position < $1.position }
        }
        result.numID = other.numID ?? numID
        result.level = other.level ?? level
        result.outlineLevel = other.outlineLevel ?? outlineLevel
        result.bidi = other.bidi ?? bidi
        result.pageBreakBefore = other.pageBreakBefore ?? pageBreakBefore
        result.keepNext = other.keepNext ?? keepNext
        result.keepLines = other.keepLines ?? keepLines
        result.widowControl = other.widowControl ?? widowControl
        result.contextual = other.contextual ?? contextual
        // Each side is set or cleared on its own; `nil` and `none` clear one
        // the style set.
        for (side, border) in other.borders { result.borders[side] = border }
        result.shading = other.shading ?? shading
        result.frame = other.frame ?? frame
        result.runProperties = runProperties.merged(with: other.runProperties)
        return result
    }
}

// MARK: - Styles, numbering, and the rest of the package

private final class ReadContext {
    struct Style {
        let id: String
        let name: String
        let type: String
        let basedOn: String?
        let paragraph: ParagraphProperties
        let run: RunProperties
        let table: XMLTree?
    }

    struct NumberingLevel {
        var start = 1
        var format = "decimal"
        var text = "%1."
        var suffix = "tab"
        var legal = false
        var paragraph = ParagraphProperties()
        var run = RunProperties()
        var restart: Int?
    }

    let archive: ZipArchive
    let mainPath: String
    let relationships: RelationshipTargets

    private(set) var styles: [String: Style] = [:]
    private(set) var defaultParagraphStyle: String?
    private(set) var defaultTableStyle: String?
    private(set) var defaultRun = RunProperties()
    private(set) var defaultParagraph = ParagraphProperties()
    private(set) var majorFont = "Calibri Light"
    private(set) var minorFont = "Calibri"
    private(set) var defaultTabInterval: CGFloat = 36

    /// numId → abstractNumId.
    private(set) var instances: [String: String] = [:]
    /// numId → level → start override.
    private(set) var startOverrides: [String: [Int: Int]] = [:]
    /// numId → level → a whole replacement level.
    private(set) var levelOverrides: [String: [Int: NumberingLevel]] = [:]
    /// abstractNumId → its levels.
    private(set) var abstracts: [String: [Int: NumberingLevel]] = [:]
    private var styleLinks: [String: String] = [:] // abstractNumId → numbering style id

    /// The document part's namespace prefixes.
    var namespaces: [String: String] = [:]
    private var contentTypeDefaults: [String: String] = [:]
    private var contentTypeOverrides: [String: String] = [:]

    func contentType(for path: String) -> String? {
        contentTypeOverrides[path] ?? contentTypeDefaults[(path as NSString).pathExtension.lowercased()]
    }

    private(set) var footnotes: [String: XMLTree] = [:]
    private(set) var endnotes: [String: XMLTree] = [:]
    private(set) var footnoteRelationships = RelationshipTargets(nil)
    private(set) var endnoteRelationships = RelationshipTargets(nil)

    init(archive: ZipArchive, mainPath: String) {
        self.archive = archive
        self.mainPath = mainPath
        relationships = RelationshipTargets(archive.contents(named: PackagePath.relationships(for: mainPath)))
        if let types = archive.contents(named: "[Content_Types].xml").flatMap(XMLTree.parse) {
            for node in types.children {
                if node.qualifiedName.hasSuffix("Default"), let ext = node.rawAttributes["Extension"], let type = node.rawAttributes["ContentType"] {
                    contentTypeDefaults[ext.lowercased()] = type
                } else if node.qualifiedName.hasSuffix("Override"), let part = node.rawAttributes["PartName"], let type = node.rawAttributes["ContentType"] {
                    contentTypeOverrides[String(part.drop(while: { $0 == "/" }))] = type
                }
            }
        }

        let directory = (mainPath as NSString).deletingLastPathComponent
        func part(ofType suffix: String) -> String? {
            relationships.types.first { $0.value.hasSuffix("/" + suffix) }
                .flatMap { relationships.inside[$0.key] }
                .map { PackagePath.resolve($0, from: directory) }
        }

        if let path = part(ofType: "theme"), let theme = archive.contents(named: path).flatMap(XMLTree.parse) {
            readTheme(theme)
        }
        if let path = part(ofType: "styles"), let styles = archive.contents(named: path).flatMap(XMLTree.parse) {
            readStyles(styles)
        }
        if let path = part(ofType: "numbering"), let numbering = archive.contents(named: path).flatMap(XMLTree.parse) {
            readNumbering(numbering)
        }
        if let path = part(ofType: "settings"), let settings = archive.contents(named: path).flatMap(XMLTree.parse),
           let interval = Measure.twips(settings.value("w:defaultTabStop")), interval > 0 {
            defaultTabInterval = interval
        }
        if let path = part(ofType: "footnotes"), let notes = archive.contents(named: path).flatMap(XMLTree.parse) {
            footnotes = Self.notes(in: notes, element: "w:footnote")
            footnoteRelationships = RelationshipTargets(archive.contents(named: PackagePath.relationships(for: path)))
        }
        if let path = part(ofType: "endnotes"), let notes = archive.contents(named: path).flatMap(XMLTree.parse) {
            endnotes = Self.notes(in: notes, element: "w:endnote")
            endnoteRelationships = RelationshipTargets(archive.contents(named: PackagePath.relationships(for: path)))
        }
    }

    private static func notes(in root: XMLTree, element: String) -> [String: XMLTree] {
        var notes: [String: XMLTree] = [:]
        for note in root.children(element) {
            // Separators and continuation notices are Word's furniture.
            guard let id = note["id"], note["type"] == nil || note["type"] == "normal" else { continue }
            notes[id] = note
        }
        return notes
    }

    private func readTheme(_ theme: XMLTree) {
        guard let scheme = theme.descendants("a:fontScheme").first else { return }
        if let major = scheme.child("a:majorFont")?.child("a:latin")?["typeface"], !major.isEmpty { majorFont = major }
        if let minor = scheme.child("a:minorFont")?.child("a:latin")?["typeface"], !minor.isEmpty { minorFont = minor }
    }

    private func readStyles(_ root: XMLTree) {
        if let defaults = root.child("w:docDefaults") {
            defaultRun = RunProperties(defaults.child("w:rPrDefault")?.child("w:rPr"))
            defaultParagraph = ParagraphProperties(defaults.child("w:pPrDefault")?.child("w:pPr"))
        }
        for node in root.children("w:style") {
            guard let id = node["styleId"] else { continue }
            let type = node["type"] ?? "paragraph"
            let style = Style(
                id: id,
                name: node.value("w:name") ?? id,
                type: type,
                basedOn: node.value("w:basedOn"),
                paragraph: ParagraphProperties(node.child("w:pPr")),
                run: RunProperties(node.child("w:rPr")),
                table: node.child("w:tblPr")
            )
            styles[id] = style
            if Measure.isOn(node.child("w:default")) == true || node["default"] == "1" || node["default"] == "true" {
                if type == "paragraph" { defaultParagraphStyle = id }
                if type == "table" { defaultTableStyle = id }
            }
        }
        // Generated documents often leave the default unmarked. Word then uses
        // the paragraph style called Normal, line spacing and all.
        if defaultParagraphStyle == nil {
            defaultParagraphStyle = styles.values.first { $0.type == "paragraph" && $0.name.lowercased() == "normal" }?.id
                ?? styles["Normal"].flatMap { $0.type == "paragraph" ? $0.id : nil }
        }
    }

    private func readNumbering(_ root: XMLTree) {
        for abstract in root.children("w:abstractNum") {
            guard let id = abstract["abstractNumId"] else { continue }
            var levels: [Int: NumberingLevel] = [:]
            for node in abstract.children("w:lvl") {
                guard let index = node["ilvl"].flatMap(Int.init) else { continue }
                levels[index] = Self.level(node)
            }
            abstracts[id] = levels
            if let link = abstract.value("w:numStyleLink") { styleLinks[id] = link }
        }
        for num in root.children("w:num") {
            guard let id = num["numId"], let abstract = num.value("w:abstractNumId") else { continue }
            instances[id] = abstract
            for override in num.children("w:lvlOverride") {
                guard let level = override["ilvl"].flatMap(Int.init) else { continue }
                if let start = override.value("w:startOverride").flatMap(Int.init) {
                    startOverrides[id, default: [:]][level] = start
                }
                if let replacement = override.child("w:lvl") {
                    levelOverrides[id, default: [:]][level] = Self.level(replacement)
                }
            }
        }
    }

    private static func level(_ node: XMLTree) -> NumberingLevel {
        var level = NumberingLevel()
        level.start = node.value("w:start").flatMap(Int.init) ?? 1
        level.format = node.value("w:numFmt") ?? "decimal"
        level.text = node.value("w:lvlText") ?? ""
        level.suffix = node.value("w:suff") ?? "tab"
        level.legal = Measure.isOn(node.child("w:isLgl")) ?? false
        level.paragraph = ParagraphProperties(node.child("w:pPr"))
        level.run = RunProperties(node.child("w:rPr"))
        level.restart = node.value("w:lvlRestart").flatMap(Int.init)
        return level
    }

    /// The abstract definition a numbering instance draws from, following a
    /// `numStyleLink` through the numbering style it names.
    func abstractID(for numID: String) -> String? {
        guard var abstract = instances[numID] else { return nil }
        var hops = 0
        while let link = styleLinks[abstract], hops < 4,
              let linkedNum = styles[link].flatMap({ resolvedParagraph(style: $0.id).numID }),
              let target = instances[linkedNum], target != abstract {
            abstract = target
            hops += 1
        }
        return abstract
    }

    func level(numID: String, level: Int) -> NumberingLevel? {
        if let replacement = levelOverrides[numID]?[level] { return replacement }
        guard let abstract = abstractID(for: numID) else { return nil }
        return abstracts[abstract]?[level]
    }

    // MARK: Style resolution

    private var paragraphCache: [String: ParagraphProperties] = [:]
    private var runCache: [String: RunProperties] = [:]

    /// A style's paragraph properties with its whole `basedOn` chain applied.
    func resolvedParagraph(style id: String) -> ParagraphProperties {
        if let cached = paragraphCache[id] { return cached }
        var chain: [Style] = []
        var current = styles[id]
        while let style = current, chain.count < 16, !chain.contains(where: { $0.id == style.id }) {
            chain.append(style)
            current = style.basedOn.flatMap { styles[$0] }
        }
        var result = ParagraphProperties()
        for style in chain.reversed() {
            var layer = style.paragraph
            layer.runProperties = layer.runProperties.merged(with: style.run)
            result = result.merged(with: layer)
        }
        paragraphCache[id] = result
        return result
    }

    func resolvedRun(style id: String) -> RunProperties {
        if let cached = runCache[id] { return cached }
        var chain: [Style] = []
        var current = styles[id]
        while let style = current, chain.count < 16, !chain.contains(where: { $0.id == style.id }) {
            chain.append(style)
            current = style.basedOn.flatMap { styles[$0] }
        }
        let result = chain.reversed().reduce(RunProperties()) { $0.merged(with: $1.run) }
        runCache[id] = result
        return result
    }

    /// A table style's own `tblPr`, nearest first along its `basedOn` chain.
    func tableStyleProperties(_ id: String?) -> [XMLTree] {
        var result: [XMLTree] = []
        var current = (id ?? defaultTableStyle).flatMap { styles[$0] }
        var seen: Set<String> = []
        while let style = current, !seen.contains(style.id) {
            seen.insert(style.id)
            if let table = style.table { result.append(table) }
            current = style.basedOn.flatMap { styles[$0] }
        }
        return result
    }

    /// `heading 1` … `heading 9`, by name rather than id: ids are localised
    /// ("berschrift1"), names aren't.
    func headingLevel(style id: String?) -> Int? {
        var current = id.flatMap { styles[$0] }
        var hops = 0
        while let style = current, hops < 8 {
            let name = style.name.lowercased()
            if name.hasPrefix("heading "), let level = Int(name.dropFirst("heading ".count)) { return level }
            if name == "title" { return 1 }
            current = style.basedOn.flatMap { styles[$0] }
            hops += 1
        }
        return nil
    }

    func themeFont(_ theme: String) -> String {
        theme.lowercased().hasPrefix("major") ? majorFont : minorFont
    }

    // MARK: What won't round-trip

    func unsupportedFeatures(document: XMLTree) -> [String] {
        var features: [String] = []

        // Only comments that are there: Word, and the apps that write for it,
        // leave an empty comments part behind, which has nothing to lose.
        let directory = (mainPath as NSString).deletingLastPathComponent
        let commentsPath = relationships.types.first { $0.value.hasSuffix("/comments") }
            .flatMap { relationships.inside[$0.key] }
            .map { PackagePath.resolve($0, from: directory) } ?? "word/comments.xml"
        if let comments = archive.contents(named: commentsPath).flatMap(XMLTree.parse), !comments.children("w:comment").isEmpty {
            features.append("comments")
        }
        let all = Self.elementNames(in: document)
        if all.contains("w:ins") || all.contains("w:del") { features.append("tracked changes") }
        if document.descendants("w:sectPr").count > 1 { features.append("section layouts") }
        return features
    }

    private static func elementNames(in root: XMLTree) -> Set<String> {
        var names: Set<String> = []
        var stack = [root]
        while let node = stack.popLast() {
            names.insert(node.name)
            stack.append(contentsOf: node.children)
        }
        return names
    }
}

// MARK: - Building the text

/// A list item's marker, as typed into the text, labelled with its own text so
/// the writer can take exactly this back out rather than guessing at what looks
/// like a marker.
extension NSAttributedString.Key {
    static let wordListMarker = NSAttributedString.Key("betterTextEdit.wordListMarker")
    /// The typeface a run asked for when this Mac doesn't have it — Calibri,
    /// Cambria, and Aptos, most often, which ship with Office rather than with
    /// macOS. The run is shown in a stand-in, and the original name is written
    /// back out so the document doesn't change typeface by being opened here.
    static let wordFontName = NSAttributedString.Key("betterTextEdit.wordFontName")
    /// A field's result — a table of contents, a page number, a date — tagged
    /// `id|instruction`, so the field itself can be written back around it
    /// rather than freezing it into plain text.
    static let wordField = NSAttributedString.Key("betterTextEdit.wordField")
    /// A footnote or endnote reference mark in the body, tagged `footnote:3`.
    static let wordNoteReference = NSAttributedString.Key("betterTextEdit.wordNoteReference")
    /// The text of a footnote or endnote, gathered at the end of the document
    /// and tagged with the same key as its reference — or `separator` for the
    /// rule above them.
    static let wordNoteBody = NSAttributedString.Key("betterTextEdit.wordNoteBody")
    /// The number shown at the start of a note's text, which Word draws itself.
    static let wordNoteLabel = NSAttributedString.Key("betterTextEdit.wordNoteLabel")

    /// The labels above describe where something came from in the Word file.
    /// None of them should spread to text typed next to a labelled run.
    static let wordStructureLabels: [NSAttributedString.Key] = [
        .wordListMarker, .wordField, .wordNoteReference, .wordNoteBody, .wordNoteLabel,
        // A heading keeps with the paragraph after it; what's typed after one
        // is that next paragraph, which shouldn't.
        .wordPagination,
        // Text typed after hidden text would otherwise be invisible too.
        .wordHidden,
    ]
}

/// A list that remembers the Word numbering it came from, so writing it back
/// reproduces `1.2.` or `(a)` exactly rather than AppKit's nearest equivalent.
final class WordTextList: NSTextList {
    var wordFormat = "decimal"
    var wordLevelText = "%1."
}

private final class DocumentBuilder {
    let output = NSMutableAttributedString()
    private(set) var imageCount = 0
    private let context: ReadContext

    private var section: XMLTree?
    private var noteReferences: [(kind: String, number: Int, id: String)] = []
    private var footnoteCounter = 0
    private var endnoteCounter = 0

    /// Word counts per abstract definition, not per instance: two instances of
    /// one definition continue each other unless one restarts.
    private var counters: [String: [Int: Int]] = [:]
    private var startedInstances: Set<String> = []
    /// The AppKit list objects currently open for each numbering instance, one
    /// per level, so consecutive items share them the way AppKit expects.
    private var openLists: [String: [WordTextList]] = [:]

    /// The paragraph just written, whose spacing after can still change once
    /// the next one is known — Word decides some spacing between pairs.
    private struct Previous {
        let styleID: String?
        let contextual: Bool
        let afterAuto: Bool
        let isList: Bool
        let depth: Int
        let range: NSRange
        let style: NSMutableParagraphStyle
    }

    private var previous: Previous?

    init(context: ReadContext) {
        self.context = context
    }

    func build(_ document: XMLTree) {
        guard let body = document.child("w:body") else { return }
        section = body.child("w:sectPr")
        if let section, let size = section.child("w:pgSz"), let width = Measure.twips(size["w"]) {
            let margins = section.child("w:pgMar")
            textWidth = width - (Measure.twips(margins?["left"]) ?? 72) - (Measure.twips(margins?["right"]) ?? 72)
        }
        writeBlocks(body.children, blocks: [], relationships: context.relationships)
        appendNotes()
        applyBookmarks()
    }

    /// The width text flows in, for sizing rules given in points.
    private var textWidth: CGFloat = 468
    private var characterStyle: String?

    func documentAttributes() -> [NSAttributedString.DocumentAttributeKey: Any] {
        var attributes: [NSAttributedString.DocumentAttributeKey: Any] = [
            .documentType: NSAttributedString.DocumentType.officeOpenXML,
        ]
        if let section {
            if let size = section.child("w:pgSz"),
               let width = Measure.twips(size["w"]), let height = Measure.twips(size["h"]) {
                attributes[.paperSize] = NSValue(size: NSSize(width: width, height: height))
            }
            if let margins = section.child("w:pgMar") {
                if let top = Measure.twips(margins["top"]) { attributes[.topMargin] = abs(top) }
                if let bottom = Measure.twips(margins["bottom"]) { attributes[.bottomMargin] = abs(bottom) }
                if let left = Measure.twips(margins["left"] ?? margins["start"]) { attributes[.leftMargin] = left }
                if let right = Measure.twips(margins["right"] ?? margins["end"]) { attributes[.rightMargin] = right }
            }
        }
        // Section settings the editor has no way to show — columns, page
        // borders, line numbers — kept for the writer to put back.
        if let section {
            let handled: Set<String> = ["w:pgSz", "w:pgMar", "w:headerReference", "w:footerReference", "w:titlePg", "w:sectPrChange"]
            let extras = section.children.filter { !handled.contains($0.name) }.map(\.xml)
            if !extras.isEmpty { attributes[.wordSectionExtras] = extras }
        }
        if let core = context.archive.contents(named: "docProps/core.xml").flatMap(XMLTree.parse) {
            if let title = core.child("dc:title")?.allText, !title.isEmpty { attributes[.title] = title }
            if let author = core.child("dc:creator")?.allText, !author.isEmpty { attributes[.author] = author }
            if let subject = core.child("dc:subject")?.allText, !subject.isEmpty { attributes[.subject] = subject }
        }
        return attributes
    }

    // MARK: Blocks

    private func writeBlocks(_ nodes: [XMLTree], blocks: [NSTextBlock], relationships: RelationshipTargets) {
        for node in nodes {
            switch node.name {
            case "w:p":
                writeParagraph(node, blocks: blocks, relationships: relationships)
            case "w:tbl":
                writeTable(node, blocks: blocks, relationships: relationships)
            case "w:sdt":
                let start = output.length
                writeBlocks(node.child("w:sdtContent")?.children ?? [], blocks: blocks, relationships: relationships)
                tagContentControl(node, key: .wordBlockContentControl, from: start)
            case "w:bookmarkStart", "w:bookmarkEnd":
                recordBookmark(node)
            case "w:customXml", "w:ins", "w:moveTo", "w:smartTag":
                writeBlocks(node.children, blocks: blocks, relationships: relationships)
            case "mc:AlternateContent":
                writeBlocks(Self.alternate(node), blocks: blocks, relationships: relationships)
            default:
                break
            }
        }
    }

    /// Markup-compatibility blocks offer a choice of renderings; the first
    /// choice is the modern one and the fallback is for old readers.
    private static func alternate(_ node: XMLTree) -> [XMLTree] {
        (node.child("mc:Choice") ?? node.child("mc:Fallback"))?.children ?? []
    }

    // MARK: Paragraphs

    private func writeParagraph(_ node: XMLTree, blocks: [NSTextBlock], relationships: RelationshipTargets) {
        let direct = ParagraphProperties(node.child("w:pPr"))
        let styleID = node.child("w:pPr")?.value("w:pStyle") ?? context.defaultParagraphStyle
        var properties = context.defaultParagraph
        if let styleID { properties = properties.merged(with: context.resolvedParagraph(style: styleID)) }
        // What the style says runs look like. The paragraph's own `w:rPr`
        // formats only its mark, never the text in it.
        let base = context.defaultRun.merged(with: properties.runProperties)
        let mark = base.merged(with: direct.runProperties)

        // Numbering can come from the style or the paragraph; either way, the
        // level's own indents sit between the style and direct formatting.
        let numID = direct.numID ?? properties.numID
        let level = direct.level ?? properties.level ?? 0
        var numbering: ReadContext.NumberingLevel?
        if let numID, numID != "0", let definition = context.level(numID: numID, level: level) {
            numbering = definition
            properties = properties.merged(with: definition.paragraph)
        }
        properties = properties.merged(with: direct)

        let paragraphStart = output.length
        let pendingBreak = properties.pageBreakBefore == true

        let paragraphStyle = makeParagraphStyle(properties, styleID: styleID, blocks: blocks, numbering: numbering, level: level)

        if pendingBreak, output.length > 0 {
            output.append(NSAttributedString(string: "\u{C}", attributes: attributes(for: base, paragraph: paragraphStyle)))
        }

        if let numbering, let numID {
            appendMarker(numID: numID, level: level, definition: numbering, mark: mark, paragraphStyle: paragraphStyle)
        }

        writeInline(node.children, base: base, paragraph: paragraphStyle, link: nil, relationships: relationships)

        // A section break in the middle of the document starts a new page,
        // unless it says it's continuous.
        if let sectionBreak = node.child("w:pPr")?.child("w:sectPr"),
           (sectionBreak.value("w:type") ?? "nextPage") != "continuous" {
            output.append(NSAttributedString(string: "\u{C}", attributes: attributes(for: mark, paragraph: paragraphStyle)))
        }

        // The paragraph mark carries the paragraph's own run formatting, which
        // is what sizes an empty line.
        output.append(NSAttributedString(string: "\n", attributes: attributes(for: mark, paragraph: paragraphStyle)))

        settleSpacing(after: previous, properties: properties, styleID: styleID, isList: numbering != nil,
                      depth: blocks.count, style: paragraphStyle, isFirst: paragraphStart == 0)
        let range = NSRange(location: paragraphStart, length: output.length - paragraphStart)
        output.addAttribute(.paragraphStyle, value: paragraphStyle.copy(), range: range)
        if let last = lastBorder, last.end == -1 { lastBorder?.end = output.length }
        previous = Previous(
            styleID: styleID,
            contextual: properties.contextual == true,
            afterAuto: properties.afterAuto == true,
            isList: numbering != nil,
            depth: blocks.count,
            range: range,
            style: paragraphStyle
        )

        if let styleID, styleID != context.defaultParagraphStyle {
            output.addAttribute(.wordParagraphStyle, value: styleID, range: range)
        }
        // How the paragraph breaks across pages. Word keeps widows and orphans
        // off a page's edges unless a paragraph says otherwise.
        let pagination = [
            properties.keepNext == true ? "keepNext" : nil,
            properties.keepLines == true ? "keepLines" : nil,
            properties.widowControl == false ? "noWidowControl" : nil,
        ].compactMap { $0 }
        if !pagination.isEmpty {
            output.addAttribute(.wordPagination, value: pagination.joined(separator: " "), range: range)
        }
        if let frame = properties.frame {
            output.addAttribute(.wordParagraphExtras, value: frame, range: range)
            if let spacing = node.child("w:pPr")?.child("w:spacing") {
                output.addAttribute(.wordParagraphSpacing, value: spacing.originalXML ?? spacing.xml, range: range)
            }
        }
    }

    /// The spacing Word works out between a pair of paragraphs rather than
    /// for each one alone.
    ///
    /// - Contextual spacing — on Word's own List Paragraph style, among
    ///   others — drops the space between neighbours of the same style, which
    ///   is what keeps a list's items together.
    /// - Automatic spacing, the HTML kind, gives items of a list none between
    ///   them, and the top of the document none above it.
    ///
    /// That the gap between two paragraphs is the larger of their spacings
    /// rather than the sum is true of every paragraph in Word, and is left to
    /// layout — see `WordLayoutManager` — so the values here stay Word's own.
    private func settleSpacing(
        after previous: Previous?,
        properties: ParagraphProperties,
        styleID: String?,
        isList: Bool,
        depth: Int,
        style: NSMutableParagraphStyle,
        isFirst: Bool
    ) {
        if isFirst, properties.beforeAuto == true { style.paragraphSpacingBefore = 0 }
        guard let previous, previous.depth == depth else { return }
        var previousAfter = previous.style.paragraphSpacing

        if previous.styleID == styleID {
            if properties.contextual == true { style.paragraphSpacingBefore = 0 }
            if previous.contextual { previousAfter = 0 }
        }
        if properties.beforeAuto == true, previous.afterAuto, isList, previous.isList {
            previousAfter = 0
            style.paragraphSpacingBefore = 0
        }

        guard previousAfter != previous.style.paragraphSpacing else { return }
        previous.style.paragraphSpacing = previousAfter
        output.addAttribute(.paragraphStyle, value: previous.style.copy(), range: previous.range)
    }

    private func makeParagraphStyle(
        _ properties: ParagraphProperties,
        styleID: String?,
        blocks: [NSTextBlock],
        numbering: ReadContext.NumberingLevel?,
        level: Int
    ) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        let rtl = properties.bidi == true
        style.baseWritingDirection = rtl ? .rightToLeft : .natural

        switch properties.alignment {
        case "center": style.alignment = .center
        case "right", "end": style.alignment = rtl ? .left : .right
        case "both", "distribute", "lowKashida", "mediumKashida", "highKashida", "thaiDistribute": style.alignment = .justified
        case "left", "start": style.alignment = rtl ? .right : .left
        default: style.alignment = rtl ? .right : .natural
        }

        let left = properties.left ?? 0
        var first = left
        if let hanging = properties.hanging { first = left - hanging } else if let firstLine = properties.firstLine { first = left + firstLine }
        style.headIndent = max(left, 0)
        style.firstLineHeadIndent = max(first, 0)
        if let right = properties.right, right > 0 { style.tailIndent = -right }

        // Auto spacing is what Word applies to paragraphs that came from HTML:
        // fourteen points, the browser default.
        style.paragraphSpacingBefore = properties.beforeAuto == true ? 14 : max(properties.before ?? 0, 0)
        style.paragraphSpacing = properties.afterAuto == true ? 14 : max(properties.after ?? 0, 0)

        // A drop cap's exact line height is how Word fits the big letter into
        // its frame; without the frame here it would only crush the letter
        // into the line above. It's kept for the writer instead.
        if let line = properties.line, line > 0, properties.frame == nil {
            switch properties.lineRule ?? "auto" {
            case "exact":
                style.minimumLineHeight = line
                style.maximumLineHeight = line
            case "atLeast":
                style.minimumLineHeight = line
            default:
                if abs(line - 1) > 0.01 { style.lineHeightMultiple = line }
            }
        }

        var stops: [NSTextTab] = (properties.tabs ?? []).map { (tab: ParagraphProperties.Tab) -> NSTextTab in
            let alignment: NSTextAlignment = switch tab.kind {
            case "center": .center
            case "right", "end": .right
            case "decimal": .right
            default: .left
            }
            var options: [NSTextTab.OptionKey: Any] = tab.kind == "decimal"
                ? [.columnTerminators: NSTextTab.columnTerminators(for: .current)]
                : [:]
            if let leader = tab.leader { options[.wordLeader] = leader }
            return NSTextTab(textAlignment: alignment, location: tab.position, options: options)
        }

        if let numbering {
            // AppKit's list layout: a tab to the marker, the marker, a tab to
            // the text. The marker sits where Word puts it, at the first-line
            // position, and the text at the indent.
            let marker = style.firstLineHeadIndent
            style.firstLineHeadIndent = 0
            if marker > 0.5 { stops.append(NSTextTab(textAlignment: .left, location: marker)) }
            if numbering.suffix == "tab", style.headIndent > marker {
                stops.append(NSTextTab(textAlignment: .left, location: style.headIndent))
            }
        }
        style.tabStops = stops.sorted { $0.location < $1.location }
        style.defaultTabInterval = context.defaultTabInterval

        let heading = properties.outlineLevel.map { $0 + 1 } ?? context.headingLevel(style: styleID)
        if let heading, (1 ... 6).contains(heading) { style.headerLevel = heading }

        style.textBlocks = blocks
        if let block = borderBlock(for: properties, depth: blocks.count, style: style) {
            style.textBlocks = blocks + [block]
        }
        return style
    }

    // MARK: Borders and shading

    private var lastBorder: (signature: String, depth: Int, end: Int, block: WordParagraphBlock)?

    /// The block that marks a paragraph's borders and shading, shared with the
    /// paragraph before when the two have the same ones — Word draws one box
    /// round the group, not a box per paragraph.
    ///
    /// The block takes no room of its own, so the paragraph keeps the indents
    /// Word gave it; `WordLayoutManager` draws the box around them.
    private func borderBlock(for properties: ParagraphProperties, depth: Int, style: NSMutableParagraphStyle) -> WordParagraphBlock? {
        let drawn = properties.borders.filter { !["nil", "none"].contains($0.value.style) }
        guard !drawn.isEmpty || properties.shading != nil else { return nil }

        // Word groups paragraphs whose borders, shading, and indents all match.
        let leftmost = min(style.headIndent, style.firstLineHeadIndent)
        let right = max(-style.tailIndent, 0)
        let signature = ["top", "left", "bottom", "right", "between"].map { side in
            drawn[side].map { "\($0.style),\($0.width),\($0.space),\($0.color ?? "")" } ?? "-"
        }.joined(separator: ";") + "|\(properties.shading ?? "")|\(leftmost)|\(right)"

        let block: WordParagraphBlock
        if let last = lastBorder, last.signature == signature, last.depth == depth, last.end == output.length {
            block = last.block
        } else {
            block = WordParagraphBlock()
            for (side, border) in drawn {
                block.borders[side] = WordParagraphBlock.Border(
                    style: border.style,
                    width: border.width,
                    space: border.space,
                    color: border.color.flatMap(WordML.color(hex:))
                )
            }
            block.shading = properties.shading.flatMap(WordML.color(hex:))
        }
        lastBorder = (signature, depth, -1, block)
        return block
    }

    // MARK: Lists

    private func appendMarker(
        numID: String,
        level: Int,
        definition: ReadContext.NumberingLevel,
        mark: RunProperties,
        paragraphStyle: NSMutableParagraphStyle
    ) {
        let abstract = context.abstractID(for: numID) ?? numID

        // A restart instance starts its levels over the first time it's used.
        if !startedInstances.contains(numID) {
            startedInstances.insert(numID)
            for (overrideLevel, start) in context.startOverrides[numID] ?? [:] {
                counters[abstract, default: [:]][overrideLevel] = start - 1
                openLists[numID] = Array((openLists[numID] ?? []).prefix(overrideLevel))
            }
        }

        var levels = counters[abstract] ?? [:]
        let start = context.startOverrides[numID]?[level] ?? definition.start
        levels[level] = (levels[level] ?? (start - 1)) + 1
        // Deeper levels start again under a new item, as Word does by default.
        for deeper in (level + 1) ..< 9 {
            let restart = context.level(numID: numID, level: deeper)?.restart
            if restart == nil || restart! > 0 { levels[deeper] = nil }
        }
        counters[abstract] = levels

        // Keep the AppKit list objects in step: the same object for every item
        // of a level, a fresh one whenever a level starts over.
        var lists = Array((openLists[numID] ?? []).prefix(level + 1))
        while lists.count <= level {
            let index = lists.count
            let levelDefinition = context.level(numID: numID, level: index) ?? definition
            let list = Self.textList(levelDefinition, level: index)
            // A list that carries on another's numbering starts where that one
            // left off — said explicitly, so it survives being written back as a
            // list of its own.
            list.startingItemNumber = levels[index] ?? list.startingItemNumber
            lists.append(list)
        }
        openLists[numID] = lists
        paragraphStyle.textLists = Array(lists.prefix(level + 1))

        // The marker's text: lvlText with each %n replaced by that level's
        // counter, in that level's format.
        var marker = definition.text
        for index in 0 ... 8 {
            let placeholder = "%\(index + 1)"
            guard marker.contains(placeholder) else { continue }
            let value = levels[index] ?? (context.level(numID: numID, level: index)?.start ?? 1)
            let format = definition.legal && index != level
                ? "decimal"
                : (context.level(numID: numID, level: index)?.format ?? "decimal")
            marker = marker.replacingOccurrences(of: placeholder, with: Self.format(value, as: format))
        }
        if definition.format == "bullet" { marker = Self.bullet(marker, font: definition.run.font) }
        if definition.format == "none" { marker = "" }

        let suffix: String = switch definition.suffix {
        case "space": " "
        case "nothing": ""
        default: "\t"
        }
        let lead = paragraphStyle.tabStops.first.map { $0.location > 0.5 } == true ? "\t" : ""

        // Word formats a list's number or bullet like the paragraph mark —
        // which is how a number gets a different typeface or size from the
        // text — and then as the level says.
        var markerRun = mark.merged(with: definition.run)
        // Bullets in Symbol or Wingdings have been mapped to real characters;
        // drawing them in the dingbat font would turn them back into letters.
        if definition.format == "bullet", let font = definition.run.font,
           ["symbol", "wingdings", "webdings"].contains(where: { font.lowercased().hasPrefix($0) }) {
            markerRun.font = mark.font
            markerRun.fontTheme = mark.fontTheme
        }
        // A marker in a typeface this Mac doesn't have — Google Docs sets its
        // bullets in Noto Sans Symbols — is drawn like the paragraph's own
        // text, as Word draws it, rather than in a stand-in that would make
        // every item's first line taller than Word's.
        if let font = definition.run.font, markerRun.font == font,
           !NSFontManager.shared.availableFontFamilies.contains(font) {
            markerRun.font = mark.font
            markerRun.fontTheme = mark.fontTheme
        }
        markerRun.underline = nil
        markerRun.highlight = nil
        markerRun.shading = nil

        var markerAttributes = attributes(for: markerRun, paragraph: paragraphStyle)
        let markerText = lead + marker + suffix
        markerAttributes[.wordListMarker] = markerText
        output.append(NSAttributedString(string: markerText, attributes: markerAttributes))
    }

    private static func textList(_ level: ReadContext.NumberingLevel, level index: Int) -> WordTextList {
        let token: String = switch level.format {
        case "bullet": "{disc}"
        case "lowerLetter": "{lower-alpha}"
        case "upperLetter": "{upper-alpha}"
        case "lowerRoman": "{lower-roman}"
        case "upperRoman": "{upper-roman}"
        default: "{decimal}"
        }
        // AppKit's format can only hold this level's counter, so anything
        // around the last placeholder is kept and the rest is dropped: `%1.%2.`
        // becomes `{decimal}.`. The text shows the full marker regardless, and
        // the Word definition is remembered for writing it back.
        var format = token
        if level.format != "bullet", let range = level.text.range(of: "%\(index + 1)") {
            let prefix = level.text[..<range.lowerBound].replacingOccurrences(of: #"%\d[^%]*"#, with: "", options: .regularExpression)
            format = prefix + token + level.text[range.upperBound...]
        }
        let list = WordTextList(markerFormat: NSTextList.MarkerFormat(format), options: 0)
        list.startingItemNumber = level.start
        list.wordFormat = level.format
        // Bullets are kept as the characters they were mapped to, since the
        // dingbat font that made sense of the original isn't written back.
        list.wordLevelText = level.format == "bullet" ? bullet(level.text, font: level.run.font) : level.text
        return list
    }

    static func format(_ value: Int, as format: String) -> String {
        switch format {
        case "lowerLetter": letters(value).lowercased()
        case "upperLetter": letters(value)
        case "lowerRoman": roman(value).lowercased()
        case "upperRoman": roman(value)
        case "decimalZero": value < 10 ? "0\(value)" : "\(value)"
        case "ordinal": "\(value)\(ordinalSuffix(value))"
        case "none": ""
        default: "\(value)"
        }
    }

    /// A, B, … Z, AA, BB — Word repeats the letter rather than counting on.
    private static func letters(_ value: Int) -> String {
        guard value > 0 else { return "" }
        let letter = Character(UnicodeScalar(UInt8(65 + (value - 1) % 26)))
        return String(repeating: letter, count: (value - 1) / 26 + 1)
    }

    private static func roman(_ value: Int) -> String {
        guard value > 0, value < 4000 else { return "\(value)" }
        let table: [(Int, String)] = [(1000, "M"), (900, "CM"), (500, "D"), (400, "CD"), (100, "C"), (90, "XC"),
                                      (50, "L"), (40, "XL"), (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")]
        var remaining = value
        var result = ""
        for (number, numeral) in table {
            while remaining >= number {
                result += numeral
                remaining -= number
            }
        }
        return result
    }

    private static func ordinalSuffix(_ value: Int) -> String {
        if (11 ... 13).contains(value % 100) { return "th" }
        switch value % 10 {
        case 1: return "st"
        case 2: return "nd"
        case 3: return "rd"
        default: return "th"
        }
    }

    /// Bullets are usually private-use characters in Symbol or Wingdings, which
    /// only mean anything in that font. Map the common ones to the Unicode
    /// characters they draw.
    static func bullet(_ text: String, font: String?) -> String {
        let map: [UInt32: String] = [
            0xF0B7: "•", 0xF0A7: "▪", 0xF0D8: "➢", 0xF076: "❖", 0xF0FC: "✓", 0xF0A8: "◆",
            0xF06E: "■", 0xF0E8: "➔", 0xF0D7: "▸", 0xF071: "❑", 0xF075: "◆", 0xF0AE: "★",
        ]
        var result = ""
        for scalar in text.unicodeScalars {
            if let mapped = map[scalar.value] {
                result += mapped
            } else if (0xF000 ... 0xF0FF).contains(scalar.value) {
                result += "•"
            } else if scalar == "o", font?.lowercased().hasPrefix("courier") == true {
                result += "◦"
            } else if scalar == "§", font?.lowercased().hasPrefix("wingdings") == true {
                result += "▪"
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
        return result.isEmpty ? "•" : result
    }

    // MARK: Inline content

    private struct FieldState {
        var id = 0
        var instruction = ""
        var showingResult = false
        var link: String?
    }

    private var fields: [FieldState] = []
    private var fieldCounter = 0

    /// The innermost field whose result is being shown, as the tag its text
    /// carries. Hyperlink fields become links instead.
    private var fieldTag: String? {
        guard let field = fields.last(where: { $0.showingResult }), field.link == nil else { return nil }
        let instruction = field.instruction.trimmingCharacters(in: .whitespaces)
        return instruction.isEmpty ? nil : "\(field.id)|\(instruction)"
    }

    private func beginField(instruction: String = "", showingResult: Bool = false) {
        fieldCounter += 1
        fields.append(FieldState(id: fieldCounter, instruction: instruction, showingResult: showingResult,
                                 link: showingResult ? Self.hyperlinkTarget(in: instruction) : nil))
    }

    private var fieldHidesContent: Bool {
        fields.contains { !$0.showingResult }
    }

    private var fieldLink: String? {
        fields.last { $0.showingResult && $0.link != nil }?.link
    }

    private func writeInline(
        _ nodes: [XMLTree],
        base: RunProperties,
        paragraph: NSParagraphStyle,
        link: String?,
        relationships: RelationshipTargets
    ) {
        for node in nodes {
            switch node.name {
            case "w:r":
                writeRun(node, base: base, paragraph: paragraph, link: link, relationships: relationships)

            case "w:hyperlink":
                var target = link
                if let id = node["id"], let url = relationships.outside[id] ?? relationships.inside[id] {
                    target = url
                } else if let anchor = node["anchor"] {
                    target = "#" + anchor
                }
                writeInline(node.children, base: base, paragraph: paragraph, link: target, relationships: relationships)

            case "w:fldSimple":
                let instruction = node["instr"] ?? ""
                let target = Self.hyperlinkTarget(in: instruction) ?? link
                beginField(instruction: instruction, showingResult: true)
                writeInline(node.children, base: base, paragraph: paragraph, link: target, relationships: relationships)
                fields.removeLast()

            case "w:ins", "w:moveTo", "w:smartTag", "w:customXml", "w:dir", "w:bdo":
                writeInline(node.children, base: base, paragraph: paragraph, link: link, relationships: relationships)

            case "w:sdt":
                let start = output.length
                writeInline(node.child("w:sdtContent")?.children ?? [], base: base, paragraph: paragraph,
                            link: link, relationships: relationships)
                tagContentControl(node, key: .wordContentControl, from: start)

            case "w:bookmarkStart", "w:bookmarkEnd":
                recordBookmark(node)

            case "mc:AlternateContent":
                writeInline(Self.alternate(node), base: base, paragraph: paragraph, link: link,
                            relationships: relationships)

            case "m:oMath", "m:oMathPara":
                // Equations have no AppKit form. They're shown in their linear
                // form and kept whole, so a save writes the real equation back.
                let text = Self.linearMath(node)
                appendPreserved(node, kind: "Equation", displayText: text, size: PreservedObjectCell.equationSize(text),
                                preview: nil, run: base, paragraph: paragraph, link: link, relationships: relationships)

            default:
                // Deletions, bookmarks, proofing marks, comment ranges, and
                // permission markers have nothing to show.
                break
            }
        }
    }

    private static func hyperlinkTarget(in instruction: String) -> String? {
        let trimmed = instruction.trimmingCharacters(in: .whitespaces)
        guard trimmed.uppercased().hasPrefix("HYPERLINK") else { return nil }
        let rest = trimmed.dropFirst("HYPERLINK".count).trimmingCharacters(in: .whitespaces)
        if rest.hasPrefix("\\l") {
            let anchor = rest.dropFirst(2).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            return "#" + anchor
        }
        if rest.hasPrefix("\"") {
            let body = rest.dropFirst()
            return body.firstIndex(of: "\"").map { String(body[..<$0]) } ?? String(body)
        }
        return rest.split(separator: " ").first.map(String.init)
    }

    private func writeRun(
        _ node: XMLTree,
        base: RunProperties,
        paragraph: NSParagraphStyle,
        link: String?,
        relationships: RelationshipTargets
    ) {
        let direct = node.child("w:rPr")
        var run = base
        if let style = direct?.value("w:rStyle") { run = run.merged(with: context.resolvedRun(style: style)) }
        run = run.merged(with: RunProperties(direct))
        let target = fieldLink ?? link
        characterStyle = direct?.value("w:rStyle")
        defer { characterStyle = nil }

        for child in node.children {
            switch child.name {
            case "w:fldChar":
                switch child["fldCharType"] {
                case "begin": beginField()
                case "separate":
                    if !fields.isEmpty {
                        fields[fields.count - 1].showingResult = true
                        fields[fields.count - 1].link = Self.hyperlinkTarget(in: fields[fields.count - 1].instruction)
                    }
                case "end": if !fields.isEmpty { fields.removeLast() }
                default: break
                }
                continue
            case "w:instrText":
                if !fields.isEmpty, !fields[fields.count - 1].showingResult {
                    fields[fields.count - 1].instruction += child.text
                }
                continue
            default:
                break
            }

            guard !fieldHidesContent else { continue }
            let target = fieldLink ?? target

            switch child.name {
            case "w:t":
                append(child.text, run: run, paragraph: paragraph, link: target)
            case "w:tab", "w:ptab":
                append("\t", run: run, paragraph: paragraph, link: target)
            case "w:br":
                append(child["type"] == "page" ? "\u{C}" : "\u{2028}", run: run, paragraph: paragraph, link: target)
            case "w:cr":
                append("\u{2028}", run: run, paragraph: paragraph, link: target)
            case "w:noBreakHyphen":
                append("\u{2011}", run: run, paragraph: paragraph, link: target)
            case "w:softHyphen":
                append("\u{AD}", run: run, paragraph: paragraph, link: target)
            case "w:sym":
                guard let raw = child["char"].flatMap({ UInt32($0, radix: 16) }) else { continue }
                // Some writers leave off the private-use offset.
                let code = raw < 0x100 ? raw + 0xF000 : raw
                let font = child["font"]
                if font?.lowercased() == "symbol", let mapped = SymbolFonts.unicode(forSymbol: code) {
                    // Apple's Symbol is a Unicode font: say what the character is.
                    append(mapped, run: run, paragraph: paragraph, link: target)
                } else if let font, let scalar = UnicodeScalar(code), NSFont(name: font, size: 12) != nil {
                    // Wingdings and Webdings draw Word's private-use characters
                    // as they are, so keep them, in their own font.
                    var symbol = run
                    symbol.font = font
                    symbol.fontTheme = nil
                    append(String(Character(scalar)), run: symbol, paragraph: paragraph, link: target)
                } else if let scalar = UnicodeScalar(code) {
                    let text = (0xF000 ... 0xF0FF).contains(code) ? Self.bullet(String(Character(scalar)), font: font) : String(Character(scalar))
                    append(text, run: run, paragraph: paragraph, link: target)
                }
            case "w:drawing", "w:pict", "w:object", "mc:AlternateContent":
                writeGraphic(child, run: run, paragraph: paragraph, link: target, relationships: relationships)
            case "w:footnoteReference", "w:endnoteReference":
                guard let id = child["id"] else { continue }
                let isFootnote = child.name == "w:footnoteReference"
                if isFootnote { footnoteCounter += 1 } else { endnoteCounter += 1 }
                let number = isFootnote ? footnoteCounter : endnoteCounter
                noteReferences.append((isFootnote ? "footnote" : "endnote", number, id))
                var reference = run
                reference.verticalAlign = "superscript"
                append(isFootnote ? "\(number)" : Self.format(number, as: "lowerRoman"), run: reference, paragraph: paragraph,
                       link: nil, extra: [.wordNoteReference: "\(isFootnote ? "footnote" : "endnote"):\(number)"])
            default:
                break
            }
        }
    }

    // MARK: Pictures

    private func writePictures(in node: XMLTree, run: RunProperties, paragraph: NSParagraphStyle, link: String?, relationships: RelationshipTargets) {
        // DrawingML: each inline or anchored drawing has an extent and a blip.
        let containers = node.descendants("wp:inline") + node.descendants("wp:anchor")
        for container in containers {
            guard let blip = container.descendants("a:blip").first, let id = blip["embed"] else { continue }
            var size: CGSize?
            if let extent = container.child("wp:extent"), let width = Measure.emu(extent["cx"]), let height = Measure.emu(extent["cy"]) {
                size = CGSize(width: width, height: height)
            }
            appendImage(relationship: id, size: size, run: run, paragraph: paragraph, link: link, relationships: relationships)
        }
        guard containers.isEmpty else { return }

        // VML, which older documents and OLE previews still use.
        for image in node.descendants("v:imagedata") {
            guard let id = image["id"] ?? image["pict"] else { continue }
            let shape = node.descendants("v:shape").first
            appendImage(relationship: id, size: Self.vmlSize(shape?["style"]), run: run, paragraph: paragraph,
                        link: link, relationships: relationships)
        }
    }

    private static func vmlSize(_ style: String?) -> CGSize? {
        guard let style else { return nil }
        var width: CGFloat?
        var height: CGFloat?
        for declaration in style.split(separator: ";") {
            let parts = declaration.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            let value = Measure.points(parts[1], unit: 1)
            if parts[0] == "width" { width = value }
            if parts[0] == "height" { height = value }
        }
        guard let width, let height else { return nil }
        return CGSize(width: width, height: height)
    }

    private func appendImage(relationship id: String, size: CGSize?, run: RunProperties, paragraph: NSParagraphStyle,
                             link: String?, relationships: RelationshipTargets) {
        guard let target = relationships.inside[id] else { return }
        let directory = (context.mainPath as NSString).deletingLastPathComponent
        let path = PackagePath.resolve(target, from: directory)
        guard let data = context.archive.contents(named: path) else { return }

        let wrapper = FileWrapper(regularFileWithContents: data)
        wrapper.preferredFilename = (path as NSString).lastPathComponent
        let attachment = NSTextAttachment(fileWrapper: wrapper)

        let image = NSImage(data: data)
        var display = size ?? image?.size ?? CGSize(width: 96, height: 96)
        // Never wider than the column the picture sits in.
        let maxWidth = 1_000.0
        if display.width > maxWidth {
            display = CGSize(width: maxWidth, height: display.height * maxWidth / display.width)
        }
        if display.width > 0, display.height > 0 {
            attachment.bounds = CGRect(origin: .zero, size: display)
            if let cell = attachment.attachmentCell as? NSTextAttachmentCell, let cellImage = cell.image {
                cellImage.size = display
            } else if let image {
                image.size = display
                attachment.image = image
            }
        }

        imageCount += 1
        var attributes = attributes(for: run, paragraph: paragraph)
        attributes[.attachment] = attachment
        if let link { attributes[.link] = Self.url(link) }
        output.append(NSAttributedString(string: "\u{FFFC}", attributes: attributes))
    }

    // MARK: Graphics

    /// Sorts a drawing into what it is: a horizontal line, a picture the editor
    /// can hold as a picture, or something to keep whole — a chart, SmartArt,
    /// a shape, a text box, an embedded object.
    private func writeGraphic(_ node: XMLTree, run: RunProperties, paragraph: NSParagraphStyle, link: String?, relationships: RelationshipTargets) {
        let content = node.name == "mc:AlternateContent" ? Self.alternate(node) : [node]
        let isEmbeddedObject = !node.descendants("o:OLEObject").isEmpty

        // A VML shape type on its own only defines a kind of shape for others
        // to use — Google Docs puts one at the top of every document it saves
        // — and draws nothing, so it gets nothing here either.
        if node.name == "w:pict" {
            let drawable = ["v:shape", "v:rect", "v:roundrect", "v:oval", "v:line", "v:polyline", "v:arc", "v:curve",
                            "v:group", "v:image", "o:OLEObject", "w:control"]
            if !drawable.contains(where: { !node.descendants($0).isEmpty }) { return }
        }

        if let rule = horizontalRule(in: content) {
            rule.originalXML = node.originalXML ?? node.xml
            rule.namespaces = context.namespaces
            var attributes = attributes(for: run, paragraph: paragraph)
            attributes[.attachment] = rule
            output.append(NSAttributedString(string: "\u{FFFC}", attributes: attributes))
            return
        }

        let graphicKinds = content.flatMap { $0.descendants("a:graphicData") }.compactMap { $0["uri"] }
        let plainDrawingPicture = !graphicKinds.isEmpty && graphicKinds.allSatisfy { $0.hasSuffix("/picture") }
        let plainVMLPicture = graphicKinds.isEmpty && !content.flatMap { $0.descendants("v:imagedata") }.isEmpty
            && content.flatMap { $0.descendants("v:textbox") }.isEmpty
        if !isEmbeddedObject, plainDrawingPicture || plainVMLPicture {
            for item in content {
                writePictures(in: item, run: run, paragraph: paragraph, link: link, relationships: relationships)
            }
            return
        }

        // Kept whole. Work out what to call it, how big it is, and what can be
        // shown in its place.
        let uri = graphicKinds.first ?? ""
        let boxText = content.flatMap { $0.descendants("w:txbxContent") }.first.map(Self.plainText) ?? ""
        let kind: String
        if isEmbeddedObject {
            let program = node.descendants("o:OLEObject").first?.rawAttributes["ProgID"] ?? ""
            kind = program.hasPrefix("Excel") ? "Excel worksheet" : program.hasPrefix("Word") ? "Word document"
                : program.hasPrefix("PowerPoint") ? "PowerPoint slide" : "Embedded object"
        } else if uri.hasSuffix("/chart") || uri.contains("chartex") {
            kind = "Chart"
        } else if uri.hasSuffix("/diagram") {
            kind = "SmartArt"
        } else if !boxText.isEmpty {
            kind = "Text box"
        } else if uri.hasSuffix("wordprocessingGroup") {
            kind = "Group"
        } else if uri.hasSuffix("wordprocessingCanvas") {
            kind = "Drawing"
        } else {
            kind = "Shape"
        }

        var size = CGSize(width: 160, height: 40)
        if let extent = content.lazy.flatMap({ $0.descendants("wp:extent") }).first,
           let width = Measure.emu(extent["cx"]), let height = Measure.emu(extent["cy"]), width > 0, height > 0 {
            size = CGSize(width: width, height: height)
        } else if let shape = content.lazy.flatMap({ $0.descendants("v:shape") + $0.descendants("v:rect") + $0.descendants("v:roundrect") }).first,
                  let vml = Self.vmlSize(shape.rawAttributes["style"]), vml.width > 0, vml.height > 0 {
            size = vml
        }
        size = CGSize(width: min(size.width, textWidth), height: min(max(size.height, 14), 900))

        // A picture inside the object — an embedded object's preview, or the
        // pictures of a group — stands in for it on screen.
        var preview: NSImage?
        let directory = (context.mainPath as NSString).deletingLastPathComponent
        let previewID = content.lazy.flatMap { $0.descendants("v:imagedata") }.compactMap { $0["id"] }.first
            ?? content.lazy.flatMap { $0.descendants("a:blip") }.compactMap { $0["embed"] }.first
        if let previewID, let target = relationships.inside[previewID],
           let data = context.archive.contents(named: PackagePath.resolve(target, from: directory)) {
            preview = NSImage(data: data)
        }

        appendPreserved(node, kind: kind, displayText: boxText, size: size, preview: preview,
                        run: run, paragraph: paragraph, link: link, relationships: relationships)
    }

    /// A line, in any of the shapes Word stores one in: VML's horizontal line
    /// (what *Insert ▸ Horizontal Line* and HTML's `<hr>` make), a VML line, or
    /// a DrawingML line shape.
    ///
    /// Word itself rewrites the first kind when it saves: newer versions drop
    /// the `o:hr` marker and keep the line as a thin rectangle named
    /// "Horizontal Line", so that — and a rectangle no thicker than a rule —
    /// counts too.
    private func horizontalRule(in content: [XMLTree]) -> HorizontalRuleAttachment? {
        for item in content {
            for rect in item.descendants("v:rect") + (item.name == "v:rect" ? [item] : [])
                where rect.descendants("v:textbox").isEmpty && rect.descendants("v:imagedata").isEmpty {
                let raw = rect.rawAttributes
                let size = Self.vmlSize(raw["style"]) ?? CGSize(width: 0, height: 1.5)
                let isRule = raw["o:hr"] == "t" || (raw["id"] ?? "").hasPrefix("Horizontal Line")
                    || (size.height > 0 && size.height <= 4 && size.width >= 72)
                guard isRule else { continue }
                var fraction = size.width > 0 ? size.width / textWidth : 1
                if let percent = raw["o:hrpct"].flatMap(Double.init), percent > 0 { fraction = CGFloat(percent) / 1000 }
                let filled = raw["filled"].map { $0 != "f" && $0 != "false" } ?? true
                let color = filled ? raw["fillcolor"].flatMap(Self.vmlColor) : nil
                return HorizontalRuleAttachment(widthFraction: fraction, thickness: max(size.height, 0.75), color: color,
                                                alignment: Self.ruleAlignment(raw["o:hralign"]))
            }
            for line in item.descendants("v:line") + (item.name == "v:line" ? [item] : []) {
                let raw = line.rawAttributes
                let from = Self.vmlPoint(raw["from"]), to = Self.vmlPoint(raw["to"])
                guard abs(from.y - to.y) < 0.5, abs(to.x - from.x) > 10 else { continue }
                let weight = raw["strokeweight"].flatMap { Measure.points($0, unit: 1) } ?? 0.75
                return HorizontalRuleAttachment(widthFraction: abs(to.x - from.x) / textWidth, thickness: weight,
                                                color: raw["strokecolor"].flatMap(Self.vmlColor) ?? .black, alignment: .left)
            }
            for shape in item.descendants("wps:wsp") {
                let geometry = shape.descendants("a:prstGeom").first?["prst"] ?? ""
                let extent = item.descendants("wp:extent").first
                let width = Measure.emu(extent?["cx"]) ?? 0
                let height = Measure.emu(extent?["cy"]) ?? 0
                guard ["line", "straightConnector1"].contains(geometry) || (height < 0.5 && width > 10),
                      shape.descendants("w:txbxContent").isEmpty
                else { continue }
                let line = shape.descendants("a:ln").first
                let weight = Measure.emu(line?["w"]) ?? 0.75
                let color = line?.descendants("a:srgbClr").first?["val"].flatMap(WordML.color(hex:)) ?? .black
                let alignment: NSTextAlignment = item.descendants("wp:inline").isEmpty
                    ? Self.ruleAlignment(item.descendants("wp:positionH").first?.child("wp:align")?.text)
                    : .left
                return HorizontalRuleAttachment(widthFraction: width > 0 ? width / textWidth : 1, thickness: weight,
                                                color: color, alignment: alignment)
            }
        }
        return nil
    }

    private static func ruleAlignment(_ value: String?) -> NSTextAlignment {
        switch value {
        case "left": .left
        case "right": .right
        default: .center
        }
    }

    private static func vmlColor(_ value: String) -> NSColor? {
        let hex = value.split(separator: " ").first.map(String.init) ?? value
        guard hex.hasPrefix("#") else { return nil }
        var digits = String(hex.dropFirst())
        if digits.count == 3 { digits = digits.map { "\($0)\($0)" }.joined() }
        return WordML.color(hex: digits.uppercased())
    }

    private static func vmlPoint(_ value: String?) -> CGPoint {
        let parts = (value ?? "0,0").split(separator: ",").map {
            Measure.points(String($0).trimmingCharacters(in: .whitespaces), unit: 1) ?? 0
        }
        return CGPoint(x: parts.first ?? 0, y: parts.count > 1 ? parts[1] : 0)
    }

    /// Keeps an element whole as an object in the text, with every package
    /// part it refers to — and every part those refer to.
    private func appendPreserved(
        _ node: XMLTree,
        kind: String,
        displayText: String,
        size: CGSize,
        preview: NSImage?,
        run: RunProperties,
        paragraph: NSParagraphStyle,
        link: String?,
        relationships: RelationshipTargets
    ) {
        let object = PreservedObjectAttachment(data: nil, ofType: nil)
        object.kind = kind
        object.xml = node.originalXML ?? node.xml
        object.displayText = displayText
        object.preview = preview
        object.size = size
        object.namespaces = context.namespaces

        let relationshipPrefixes = Set(context.namespaces.filter { XMLTree.prefixes[$0.value] == "r" }.map(\.key) + ["r"])
        let directory = (context.mainPath as NSString).deletingLastPathComponent
        var seen: Set<String> = []
        for element in [node] + Self.allDescendants(node) {
            for (key, value) in element.rawAttributes {
                guard let colon = key.firstIndex(of: ":"), relationshipPrefixes.contains(String(key[..<colon])),
                      !seen.contains(value)
                else { continue }
                seen.insert(value)
                let type = relationships.types[value] ?? ""
                if let url = relationships.outside[value] {
                    object.relationships.append(.init(id: value, type: type, target: url, external: true))
                } else if let target = relationships.inside[value] {
                    let path = PackagePath.resolve(target, from: directory)
                    object.relationships.append(.init(id: value, type: type, target: path, external: false))
                    collectPart(path, into: object)
                }
            }
        }
        object.configure()

        var attributes = attributes(for: run, paragraph: paragraph)
        attributes[.attachment] = object
        if let link { attributes[.link] = Self.url(link) }
        output.append(NSAttributedString(string: "\u{FFFC}", attributes: attributes))
    }

    private func collectPart(_ path: String, into object: PreservedObjectAttachment) {
        guard object.parts[path] == nil, let data = context.archive.contents(named: path) else { return }
        object.parts[path] = data
        object.contentTypes[path] = context.contentType(for: path)
        let relsPath = PackagePath.relationships(for: path)
        guard let rels = context.archive.contents(named: relsPath) else { return }
        object.parts[relsPath] = rels
        let directory = (path as NSString).deletingLastPathComponent
        for target in RelationshipTargets(rels).inside.values {
            collectPart(PackagePath.resolve(target, from: directory), into: object)
        }
    }

    private static func allDescendants(_ node: XMLTree) -> [XMLTree] {
        var result: [XMLTree] = []
        var stack = node.children
        while let next = stack.popLast() {
            result.append(next)
            stack.append(contentsOf: next.children)
        }
        return result
    }

    private static func plainText(_ node: XMLTree) -> String {
        node.descendants("w:p").map { paragraph in
            paragraph.descendants("w:t").map(\.text).joined()
        }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// An equation in the linear form people type: `x^2`, `(a)/(b)`, `√(x)`.
    static func linearMath(_ node: XMLTree) -> String {
        switch node.name {
        case "m:t": return node.text
        case "m:sSup":
            return linear(node.child("m:e")) + "^" + group(linear(node.child("m:sup")))
        case "m:sSub":
            return linear(node.child("m:e")) + "_" + group(linear(node.child("m:sub")))
        case "m:sSubSup":
            return linear(node.child("m:e")) + "_" + group(linear(node.child("m:sub"))) + "^" + group(linear(node.child("m:sup")))
        case "m:f":
            return group(linear(node.child("m:num"))) + "/" + group(linear(node.child("m:den")))
        case "m:rad":
            return "√" + group(linear(node.child("m:e")))
        case "m:d":
            let begin = node.child("m:dPr")?.child("m:begChr")?["val"] ?? "("
            let end = node.child("m:dPr")?.child("m:endChr")?["val"] ?? ")"
            return begin + node.children("m:e").map { linear($0) }.joined(separator: ",") + end
        case "m:nary":
            let symbol = node.child("m:naryPr")?.child("m:chr")?["val"] ?? "∫"
            return symbol + "_" + group(linear(node.child("m:sub"))) + "^" + group(linear(node.child("m:sup"))) + " " + linear(node.child("m:e"))
        default:
            return node.children.filter { !$0.name.hasSuffix("Pr") }.map { linearMath($0) }.joined()
        }
    }

    private static func linear(_ node: XMLTree?) -> String {
        node.map { linearMath($0) } ?? ""
    }

    private static func group(_ text: String) -> String {
        text.count <= 1 ? text : "(" + text + ")"
    }

    // MARK: Bookmarks and content controls

    private var openBookmarks: [String: (name: String, start: Int)] = [:]
    private var bookmarks: [(name: String, start: Int, end: Int)] = []
    private var controlCounter = 0

    private func recordBookmark(_ node: XMLTree) {
        guard let id = node["id"] else { return }
        if node.name == "w:bookmarkStart" {
            if let name = node["name"] { openBookmarks[id] = (name, output.length) }
        } else if let open = openBookmarks.removeValue(forKey: id) {
            bookmarks.append((open.name, open.start, output.length))
        }
    }

    /// Bookmarks become a label on the text they cover — or, for one that
    /// marks a point, on the character after it — so links and
    /// cross-references to them still land after a save.
    private func applyBookmarks() {
        guard output.length > 0 else { return }
        for bookmark in bookmarks {
            let point = bookmark.end <= bookmark.start
            let start = min(bookmark.start, output.length - 1)
            let range = point ? NSRange(location: start, length: 1)
                : NSRange(location: start, length: min(bookmark.end, output.length) - start)
            let name = point ? "·" + bookmark.name : bookmark.name
            output.enumerateAttribute(.wordBookmarks, in: range, options: []) { value, subrange, _ in
                var names = value as? [String] ?? []
                names.append(name)
                output.addAttribute(.wordBookmarks, value: names, range: subrange)
            }
        }
    }

    private func tagContentControl(_ node: XMLTree, key: NSAttributedString.Key, from start: Int) {
        guard output.length > start, let properties = node.child("w:sdtPr") else { return }
        controlCounter += 1
        let tag = "\(controlCounter)|\(properties.xml)"
        let range = NSRange(location: start, length: output.length - start)
        // An inner control keeps its own label.
        output.enumerateAttribute(key, in: range, options: []) { value, subrange, _ in
            if value == nil { output.addAttribute(key, value: tag, range: subrange) }
        }
    }


    // MARK: Tables

    private func writeTable(_ node: XMLTree, blocks: [NSTextBlock], relationships: RelationshipTargets) {
        // Spacing rules between neighbours don't reach across a table edge.
        previous = nil
        defer { previous = nil }
        let properties = node.child("w:tblPr")
        let styleProperties = context.tableStyleProperties(properties?.value("w:tblStyle"))
        let layers = [properties].compactMap { $0 } + styleProperties

        func tableProperty(_ name: String) -> XMLTree? {
            layers.lazy.compactMap { $0.child(name) }.first
        }

        let grid = node.child("w:tblGrid")?.children("w:gridCol").map { Measure.twips($0["w"]) ?? 0 } ?? []
        let rows = node.children("w:tr") + node.children("w:sdt").flatMap { $0.child("w:sdtContent")?.children("w:tr") ?? [] }

        // Lay the grid out first: which cells start where, how far they span,
        // and how far down a vertical merge runs.
        struct Cell {
            let node: XMLTree
            let row: Int
            let column: Int
            let span: Int
            var rowSpan = 1
            let merge: String?
        }
        var cells: [Cell] = []
        var origins: [Int: Int] = [:] // column → index into `cells` of the open vertical merge
        var columnCount = grid.count

        for (rowIndex, row) in rows.enumerated() {
            var column = row.child("w:trPr")?.value("w:gridBefore").flatMap(Int.init) ?? 0
            for cell in row.children("w:tc") + row.children("w:sdt").flatMap({ $0.child("w:sdtContent")?.children("w:tc") ?? [] }) {
                let tcPr = cell.child("w:tcPr")
                let span = max(tcPr?.value("w:gridSpan").flatMap(Int.init) ?? 1, 1)
                let mergeNode = tcPr?.child("w:vMerge")
                let merge = mergeNode.map { $0["val"] ?? "continue" }

                if merge == "continue", let origin = origins[column] {
                    cells[origin].rowSpan += 1
                } else {
                    cells.append(Cell(node: cell, row: rowIndex, column: column, span: span, merge: merge))
                    if merge == "restart" { origins[column] = cells.count - 1 } else { origins[column] = nil }
                }
                column += span
            }
            columnCount = max(columnCount, column)
        }
        guard !cells.isEmpty else { return }

        let table = NSTextTable()
        table.numberOfColumns = max(columnCount, 1)
        table.collapsesBorders = true
        table.hidesEmptyCells = false
        // Automatic, with the grid's widths given to the cells: AppKit's fixed
        // algorithm reads widths from the first row only, which goes wrong as
        // soon as that row has a merged cell.
        table.layoutAlgorithm = .automaticLayoutAlgorithm

        let borders = tableProperty("w:tblBorders")
        let defaultMargins = tableProperty("w:tblCellMar")
        if let width = properties?.child("w:tblW"), let value = width["w"].flatMap(Double.init), value > 0 {
            if width["type"] == "pct" {
                table.setValue(CGFloat(value) / 50, type: .percentageValueType, for: .width)
            } else if width["type"] == "dxa", let points = Measure.twips(width["w"]) {
                table.setValue(points, type: .absoluteValueType, for: .width)
            }
        } else if !grid.isEmpty {
            table.setValue(grid.reduce(0, +), type: .absoluteValueType, for: .width)
        }

        let rowCount = rows.count
        // Word draws the line between two cells once, and gives it room once.
        // A text table gives each cell its own four borders, so a shared edge
        // already drawn by the cell above or to the left is left off the cell
        // below or to the right — otherwise every inside line would be twice
        // as thick, and every row a border's width taller than Word's.
        var drawnBelow: Set<[Int]> = []
        var drawnRight: Set<[Int]> = []
        for cell in cells {
            let block = NSTextTableBlock(table: table, startingRow: cell.row, rowSpan: cell.rowSpan,
                                         startingColumn: cell.column, columnSpan: cell.span)
            let tcPr = cell.node.child("w:tcPr")

            let gridWidth = grid.count >= cell.column + cell.span
                ? grid[cell.column ..< cell.column + cell.span].reduce(0, +)
                : nil
            let cellWidth = tcPr?.child("w:tcW").flatMap { $0["type"] == "dxa" ? Measure.twips($0["w"]) : nil }
            let margins = tcPr?.child("w:tcMar")

            func margin(_ names: [String], fallback: CGFloat) -> CGFloat {
                for container in [margins, defaultMargins].compactMap({ $0 }) {
                    for name in names {
                        if let node = container.child(name), let value = Measure.twips(node["w"]) { return value }
                    }
                }
                return fallback
            }
            let padding: [(NSRectEdge, CGFloat)] = [
                (.minY, margin(["w:top"], fallback: 0)),
                (.minX, margin(["w:left", "w:start"], fallback: 5.4)),
                (.maxY, margin(["w:bottom"], fallback: 0)),
                (.maxX, margin(["w:right", "w:end"], fallback: 5.4)),
            ]
            for (edge, value) in padding {
                block.setWidth(value, type: .absoluteValueType, for: .padding, edge: edge)
            }

            if let width = gridWidth ?? cellWidth, width > 0 {
                let horizontal = padding.filter { $0.0 == .minX || $0.0 == .maxX }.map(\.1).reduce(0, +)
                block.setValue(max(width - horizontal, 1), type: .absoluteValueType, for: .width)
            }

            // Borders: the cell's own, else the table's — outer edges for the
            // cells on the outside, inside lines for the rest.
            let cellBorders = tcPr?.child("w:tcBorders")
            let isTop = cell.row == 0, isBottom = cell.row + cell.rowSpan >= rowCount
            let isLeft = cell.column == 0, isRight = cell.column + cell.span >= table.numberOfColumns
            let edges: [(NSRectEdge, [String], [String])] = [
                (.minY, ["w:top"], [isTop ? "w:top" : "w:insideH"]),
                (.minX, ["w:left", "w:start"], [isLeft ? (borders?.child("w:left") != nil ? "w:left" : "w:start") : "w:insideV"]),
                (.maxY, ["w:bottom"], [isBottom ? "w:bottom" : "w:insideH"]),
                (.maxX, ["w:right", "w:end"], [isRight ? (borders?.child("w:right") != nil ? "w:right" : "w:end") : "w:insideV"]),
            ]
            let columns = cell.column ..< cell.column + cell.span
            let rowsSpanned = cell.row ..< cell.row + cell.rowSpan
            for (edge, own, inherited) in edges {
                if edge == .minY, !isTop, columns.allSatisfy({ drawnBelow.contains([cell.row - 1, $0]) }) { continue }
                if edge == .minX, !isLeft, rowsSpanned.allSatisfy({ drawnRight.contains([$0, cell.column - 1]) }) { continue }
                let border = own.lazy.compactMap { cellBorders?.child($0) }.first
                    ?? inherited.lazy.compactMap { borders?.child($0) }.first
                guard let border, let kind = border["val"], !["nil", "none"].contains(kind) else { continue }
                let width = max(Measure.eighths(border["sz"]) ?? 0.5, 0.25)
                block.setWidth(width, type: .absoluteValueType, for: .border, edge: edge)
                let color = border["color"].flatMap { $0 == "auto" ? nil : WordML.color(hex: $0) } ?? .black
                block.setBorderColor(color, for: edge)
                if edge == .maxY { for column in columns { drawnBelow.insert([cell.row + cell.rowSpan - 1, column]) } }
                if edge == .maxX { for row in rowsSpanned { drawnRight.insert([row, cell.column + cell.span - 1]) } }
            }

            if let fill = tcPr?.child("w:shd")?["fill"], fill.lowercased() != "auto", let color = WordML.color(hex: fill) {
                block.backgroundColor = color
            }
            switch tcPr?.value("w:vAlign") {
            case "center": block.verticalAlignment = .middleAlignment
            case "bottom": block.verticalAlignment = .bottomAlignment
            default: block.verticalAlignment = .topAlignment
            }

            let start = output.length
            previous = nil
            writeBlocks(cell.node.children, blocks: blocks + [block], relationships: relationships)
            if output.length == start {
                // A cell always holds at least one paragraph in AppKit too.
                let style = NSMutableParagraphStyle()
                style.textBlocks = blocks + [block]
                output.append(NSAttributedString(string: "\n", attributes: attributes(for: context.defaultRun, paragraph: style)))
            }
        }
    }

    // MARK: Notes

    private func appendNotes() {
        guard !noteReferences.isEmpty else { return }
        let base = context.defaultRun
        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = 12

        var rule = base
        rule.size = (base.size ?? 10) * 0.9
        var ruleAttributes = attributes(for: rule, paragraph: style)
        ruleAttributes[.wordNoteBody] = "separator"
        output.append(NSAttributedString(string: "\u{2014}\u{2014}\u{2014}\u{2014}\n", attributes: ruleAttributes))

        // Notes are shown where a reader of a flowing document can get at them
        // — after the text — and tagged so that saving puts each one back in
        // `footnotes.xml` or `endnotes.xml` behind its reference.
        previous = nil
        for reference in noteReferences {
            let isFootnote = reference.kind == "footnote"
            guard let note = (isFootnote ? context.footnotes : context.endnotes)[reference.id] else { continue }
            let label = isFootnote ? "\(reference.number)" : Self.format(reference.number, as: "lowerRoman")
            let start = output.length
            writeBlocks(note.children, blocks: [], relationships: isFootnote ? context.footnoteRelationships : context.endnoteRelationships)
            guard output.length > start else { continue }

            // The note's own reference mark was rendered as nothing; label the
            // note with its number instead.
            var labelRun = base
            labelRun.verticalAlign = "superscript"
            let noteStyle = output.attribute(.paragraphStyle, at: start, effectiveRange: nil) as? NSParagraphStyle ?? style
            var labelAttributes = attributes(for: labelRun, paragraph: noteStyle)
            labelAttributes[.wordNoteLabel] = true
            output.insert(NSAttributedString(string: label, attributes: labelAttributes), at: start)
            output.addAttribute(.wordNoteBody, value: "\(reference.kind):\(reference.number)",
                                range: NSRange(location: start, length: output.length - start))
        }
    }

    // MARK: Attributes

    private func append(
        _ text: String,
        run: RunProperties,
        paragraph: NSParagraphStyle,
        link: String?,
        extra: [NSAttributedString.Key: Any] = [:]
    ) {
        guard !text.isEmpty else { return }
        var attributes = attributes(for: run, paragraph: paragraph)
        if let link { attributes[.link] = Self.url(link) }
        if let fieldTag { attributes[.wordField] = fieldTag }
        if let characterStyle { attributes[.wordCharacterStyle] = characterStyle }
        attributes.merge(extra) { $1 }

        // Small capitals: the letters typed in lowercase are drawn as capitals
        // at about four fifths of the size, the way Word synthesises them.
        if attributes[.wordCaps] as? String == "smallCaps", let font = attributes[.font] as? NSFont {
            var small = attributes
            small[.font] = NSFont(descriptor: font.fontDescriptor, size: (font.pointSize * 0.8).rounded()) ?? font
            small[.wordCapsSize] = font.pointSize
            var buffer = ""
            var bufferIsLower = false
            func flush() {
                guard !buffer.isEmpty else { return }
                output.append(NSAttributedString(string: buffer, attributes: bufferIsLower ? small : attributes))
                buffer = ""
            }
            for character in text {
                let isLower = character.isLowercase
                if isLower != bufferIsLower { flush(); bufferIsLower = isLower }
                buffer.append(character)
            }
            flush()
            return
        }
        output.append(NSAttributedString(string: text, attributes: attributes))
    }

    private static func url(_ link: String) -> Any {
        URL(string: link) ?? link
    }

    private var fontCache: [String: (NSFont, String?)] = [:]

    private func attributes(for run: RunProperties, paragraph: NSParagraphStyle) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [.paragraphStyle: paragraph]

        // Word's own default when a document specifies nothing at all.
        let family = run.font ?? run.fontTheme.map(context.themeFont) ?? "Times New Roman"
        var size = run.size ?? 10
        if run.verticalAlign == "superscript" || run.verticalAlign == "subscript" {
            // Word shrinks super- and subscript to about two thirds.
            size = (size * 2 / 3).rounded()
        }
        let (font, original) = font(family: family, size: size, bold: run.bold == true, italic: run.italic == true)
        attributes[.font] = font
        if let original { attributes[.wordFontName] = original }

        if let color = run.color, color.lowercased() != "auto", let value = WordML.color(hex: color) {
            attributes[.foregroundColor] = value
        } else {
            attributes[.foregroundColor] = NSColor.black
        }

        if let highlight = run.highlight, highlight != "none", let hex = WordML.highlightColors[highlight] {
            attributes[.backgroundColor] = WordML.color(hex: hex)
        } else if let shading = run.shading, let color = WordML.color(hex: shading) {
            attributes[.backgroundColor] = color
        }

        if let underline = run.underline, underline != "none" {
            let style: NSUnderlineStyle = switch underline {
            case "double": .double
            case "thick": .thick
            case "dotted", "dottedHeavy": [.single, .patternDot]
            case "dash", "dashedHeavy", "dashLong", "dashLongHeavy": [.single, .patternDash]
            case "dotDash", "dashDotHeavy": [.single, .patternDashDot]
            case "dotDotDash", "dashDotDotHeavy": [.single, .patternDashDotDot]
            case "words": [.single, .byWord]
            default: .single
            }
            attributes[.underlineStyle] = style.rawValue
            if let color = run.underlineColor, color != "auto", let value = WordML.color(hex: color) {
                attributes[.underlineColor] = value
            }
        }
        if run.doubleStrike == true {
            attributes[.strikethroughStyle] = NSUnderlineStyle.double.rawValue
        } else if run.strike == true {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }

        switch run.verticalAlign {
        case "superscript": attributes[.superscript] = 1
        case "subscript": attributes[.superscript] = -1
        default:
            if let position = run.position, position != 0 { attributes[.baselineOffset] = position }
        }
        if let spacing = run.spacing, spacing != 0 {
            attributes[.kern] = spacing
        } else if let from = run.kernFrom, from > 0, (run.size ?? 10) >= from {
            // Kerned the way the font's own pairs say, as Word does at this size.
        } else {
            // Word doesn't kern unless asked to, and AppKit kerns everything —
            // which sets each line a little tighter than Word does, enough to
            // move where lines break. Zero turns AppKit's kerning off.
            attributes[.kern] = 0
        }
        // Nor does Word join letters into ligatures unless asked to; Calibri's
        // `ti` and `ft` would otherwise be drawn as one shape here and two there.
        attributes[.ligature] = switch run.ligatures {
        case "all": 2
        case let value? where value.lowercased().contains("standard"): 1
        default: 0
        }
        // What Word has and the text system doesn't — carried as labels the
        // layout manager draws and the writer writes back.
        if run.hidden == true { attributes[.wordHidden] = true }
        if run.caps == true {
            attributes[.wordCaps] = "caps"
        } else if run.smallCaps == true {
            attributes[.wordCaps] = "smallCaps"
        }
        if let border = run.border, border != "none" { attributes[.wordRunBorder] = border }
        if let scale = run.scale, scale > 0, abs(scale - 100) > 0.5 {
            // AppKit's expansion is the log of the stretch factor.
            attributes[.expansion] = log(scale / 100)
        }
        if run.outline == true {
            // A positive stroke width draws the outline alone, unfilled.
            attributes[.strokeWidth] = 3.0
        }
        if run.shadow == true {
            let shadow = NSShadow()
            shadow.shadowOffset = NSSize(width: 1, height: -1)
            shadow.shadowBlurRadius = 1
            attributes[.shadow] = shadow
        }
        return attributes
    }

    /// The font for a run, and the name it asked for when that had to be
    /// substituted.
    private func font(family: String, size: CGFloat, bold: Bool, italic: Bool) -> (NSFont, String?) {
        let key = "\(family)|\(size)|\(bold)|\(italic)"
        if let cached = fontCache[key] { return cached }

        var traits: NSFontTraitMask = []
        if bold { traits.insert(.boldFontMask) }
        if italic { traits.insert(.italicFontMask) }

        let manager = NSFontManager.shared
        var substituted: String?
        var font = manager.font(withFamily: family, traits: traits, weight: bold ? 9 : 5, size: size)
        if font == nil, let plain = manager.font(withFamily: family, traits: [], weight: 5, size: size) {
            // The family exists but has no face with these traits; let the
            // font manager synthesise them as well as it can.
            font = manager.convert(plain, toHaveTrait: traits)
        }
        if font == nil {
            substituted = family
            let stand = WordML.standIn(for: family)
            font = manager.font(withFamily: stand, traits: traits, weight: bold ? 9 : 5, size: size)
                ?? manager.convert(NSFont.systemFont(ofSize: size), toHaveTrait: traits)
        }
        let result = (font ?? NSFont.systemFont(ofSize: size), substituted)
        fontCache[key] = result
        return result
    }
}
