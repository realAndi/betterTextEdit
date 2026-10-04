import AppKit
import Foundation

// MARK: - Labels for Word-only formatting

/// Formatting Word has and the text system doesn't. Each is carried as an
/// attribute so it survives editing and comes back out on save, and the ones
/// with a look are drawn by `WordLayoutManager`.
extension NSAttributedString.Key {
    /// Text Word keeps but doesn't show (`w:vanish`). It stays in the text so
    /// it isn't lost on save, and takes up no space on screen.
    static let wordHidden = NSAttributedString.Key("betterTextEdit.wordHidden")
    /// `caps` or `smallCaps`: shown in capitals without changing the letters
    /// themselves, which is what Word does.
    static let wordCaps = NSAttributedString.Key("betterTextEdit.wordCaps")
    /// The size a small-capitals run really is. Its lowercase letters are set
    /// smaller so they draw as small capitals, and this is the size to save.
    static let wordCapsSize = NSAttributedString.Key("betterTextEdit.wordCapsSize")
    /// A box around a run of text (`w:bdr`), as `width|RRGGBB`.
    static let wordRunBorder = NSAttributedString.Key("betterTextEdit.wordRunBorder")
    /// The bookmarks this text belongs to, as an array of names. A name that
    /// starts with `·` marks a point rather than a span.
    static let wordBookmarks = NSAttributedString.Key("betterTextEdit.wordBookmarks")
    /// The Word paragraph style a paragraph had, by style id.
    static let wordParagraphStyle = NSAttributedString.Key("betterTextEdit.wordParagraphStyle")
    /// The Word character style a run had, by style id.
    static let wordCharacterStyle = NSAttributedString.Key("betterTextEdit.wordCharacterStyle")
    /// A content control around this text, as `kind:id|<w:sdtPr>…</w:sdtPr>`,
    /// where kind is `r` for one inside a paragraph and `b` for one around
    /// whole paragraphs.
    static let wordContentControl = NSAttributedString.Key("betterTextEdit.wordContentControl")
    /// A content control round whole paragraphs, as `id|<w:sdtPr>…</w:sdtPr>`.
    static let wordBlockContentControl = NSAttributedString.Key("betterTextEdit.wordBlockContentControl")
    /// A paragraph's spacing as Word wrote it, kept where the editor shows it
    /// differently — a drop cap's.
    static let wordParagraphSpacing = NSAttributedString.Key("betterTextEdit.wordParagraphSpacing")
    /// Paragraph properties kept verbatim — a drop cap's frame, say — as raw
    /// `w:pPr` children.
    static let wordParagraphExtras = NSAttributedString.Key("betterTextEdit.wordParagraphExtras")
}

extension NSAttributedString.DocumentAttributeKey {
    /// Section settings with no equivalent here — columns, page borders, line
    /// numbering — as raw `w:sectPr` children, so a save keeps them.
    static let wordSectionExtras = NSAttributedString.DocumentAttributeKey(rawValue: "betterTextEdit.wordSectionExtras")
}

extension NSTextTab.OptionKey {
    /// The leader a tab is filled with: `dot`, `hyphen`, `underscore`,
    /// `middleDot`, or `heavy`.
    static let wordLeader = NSTextTab.OptionKey(rawValue: "betterTextEdit.wordLeader")
}

// MARK: - Paragraph borders

/// The box Word draws round a paragraph — or a run of paragraphs with the same
/// borders — and its shading, as a text block the text system lays out and
/// draws. It remembers the Word line styles AppKit can't draw (double, dotted)
/// so a save writes back what came in.
final class WordParagraphBlock: NSTextBlock {
    /// Word's `w:val` for each side that has a border: `top`, `left`,
    /// `bottom`, `right`.
    var borderStyles: [String: String] = [:]
    /// The border Word draws between paragraphs of one group, verbatim.
    var betweenBorder: String?
}

// MARK: - Horizontal rules

/// A horizontal line: Word's *Insert ▸ Horizontal Line*, HTML's `<hr>`, or a
/// drawn line shape. It spans its share of the line it sits on, at its own
/// thickness and colour, and is written back as a Word horizontal line.
final class HorizontalRuleAttachment: NSTextAttachment {
    /// A fraction of the available width, from 0 to 1.
    var widthFraction: CGFloat = 1
    var thickness: CGFloat = 1
    var color: NSColor = .init(white: 0.63, alpha: 1)
    var alignment: NSTextAlignment = .center
    /// The line as Word wrote it, when it came from a Word document — written
    /// back as it was, so a drawn line stays a drawn line.
    var originalXML: String?
    var namespaces: [String: String] = [:]

    convenience init(widthFraction: CGFloat, thickness: CGFloat, color: NSColor?, alignment: NSTextAlignment) {
        self.init(data: nil, ofType: nil)
        self.widthFraction = min(max(widthFraction, 0.02), 1)
        self.thickness = min(max(thickness, 0.5), 24)
        if let color { self.color = color }
        self.alignment = alignment
        attachmentCell = HorizontalRuleCell(rule: self)
    }
}

final class HorizontalRuleCell: NSTextAttachmentCell {
    private weak var rule: HorizontalRuleAttachment?
    /// Air above and below the line, so it reads as a divider rather than an
    /// underline on the line above.
    private let margin: CGFloat = 5

    init(rule: HorizontalRuleAttachment) {
        self.rule = rule
        super.init()
    }

    @available(*, unavailable)
    required init(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func cellFrame(
        for _: NSTextContainer,
        proposedLineFragment lineFrag: NSRect,
        glyphPosition position: NSPoint,
        characterIndex _: Int
    ) -> NSRect {
        let thickness = rule?.thickness ?? 1
        // As wide as the line has room for — a rule is the whole line, whatever
        // the window's width — less a hair so it never forces a wrap.
        let available = max(lineFrag.width - position.x - 1, 1)
        return NSRect(x: 0, y: 0, width: available, height: thickness + margin * 2)
    }

    override func cellSize() -> NSSize {
        NSSize(width: 100, height: (rule?.thickness ?? 1) + margin * 2)
    }

    override func draw(withFrame cellFrame: NSRect, in _: NSView?) {
        guard let rule else { return }
        let width = cellFrame.width * rule.widthFraction
        let x: CGFloat = switch rule.alignment {
        case .left, .natural: cellFrame.minX
        case .right: cellFrame.maxX - width
        default: cellFrame.midX - width / 2
        }
        let line = NSRect(x: x, y: cellFrame.midY - rule.thickness / 2, width: width, height: rule.thickness)
        rule.color.setFill()
        line.fill()
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?, characterIndex _: Int) {
        draw(withFrame: cellFrame, in: controlView)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?, characterIndex _: Int, layoutManager _: NSLayoutManager) {
        draw(withFrame: cellFrame, in: controlView)
    }
}

// MARK: - Preserved objects

/// Something in a Word document the editor can show but not edit — an
/// equation, a text box, a shape, a chart, SmartArt, an embedded object.
///
/// It's carried as one object in the text, holding the exact XML it came from
/// and every part of the package that XML points at, so saving writes it back
/// as it was: a chart stays a live chart, an equation stays an equation. It
/// can be moved or deleted like a picture; what's inside it is Word's to edit.
final class PreservedObjectAttachment: NSTextAttachment {
    struct Relationship {
        let id: String
        let type: String
        let target: String
        let external: Bool
    }

    /// What it is, for the placeholder: "Equation", "Chart", "Text box"…
    var kind = "Object"
    /// The run content to write back — a `w:drawing`, `w:pict`, `w:object`,
    /// `mc:AlternateContent`, or `m:oMath` element, verbatim.
    var xml = ""
    /// The relationships that XML uses, by their original ids.
    var relationships: [Relationship] = []
    /// Package parts the relationships lead to, by path, with whatever those
    /// parts point at in turn.
    var parts: [String: Data] = [:]
    var contentTypes: [String: String] = [:]
    /// Text to show in place of the object: an equation's linear form, or a
    /// text box's contents.
    var displayText = ""
    var preview: NSImage?
    var size = CGSize(width: 120, height: 24)
    /// The namespace prefixes the XML uses, so it can be written into a
    /// document that wouldn't otherwise declare them.
    var namespaces: [String: String] = [:]

    func configure() {
        attachmentCell = PreservedObjectCell(object: self)
        bounds = CGRect(origin: .zero, size: size)
    }
}

final class PreservedObjectCell: NSTextAttachmentCell {
    private weak var object: PreservedObjectAttachment?

    init(object: PreservedObjectAttachment) {
        self.object = object
        super.init()
    }

    @available(*, unavailable)
    required init(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func cellSize() -> NSSize {
        object?.size ?? NSSize(width: 120, height: 24)
    }

    override func cellBaselineOffset() -> NSPoint {
        // Equations sit on the baseline like text; boxes hang a little below.
        object?.kind == "Equation" ? NSPoint(x: 0, y: -4) : .zero
    }

    override func draw(withFrame cellFrame: NSRect, in _: NSView?) {
        guard let object else { return }

        if let preview = object.preview {
            preview.draw(in: cellFrame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            return
        }

        if object.kind == "Equation" {
            let text = NSAttributedString(string: object.displayText, attributes: Self.equationAttributes)
            text.draw(at: NSPoint(x: cellFrame.minX + 1, y: cellFrame.minY + 2))
            return
        }

        // A frame the size Word gives the object, with what it is and any text
        // it holds — so the layout reads true and nothing pretends to be
        // editable when it isn't.
        let frame = cellFrame.insetBy(dx: 0.5, dy: 0.5)
        NSColor(white: 0.97, alpha: 1).setFill()
        NSBezierPath(roundedRect: frame, xRadius: 3, yRadius: 3).fill()
        NSColor(white: 0.7, alpha: 1).setStroke()
        let border = NSBezierPath(roundedRect: frame, xRadius: 3, yRadius: 3)
        border.setLineDash([3, 2], count: 2, phase: 0)
        border.stroke()

        let label = object.displayText.isEmpty ? object.kind : object.displayText
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: object.displayText.isEmpty ? 10 : 11),
            .foregroundColor: NSColor(white: object.displayText.isEmpty ? 0.45 : 0.15, alpha: 1),
            .paragraphStyle: style,
        ]
        NSAttributedString(string: label, attributes: attributes)
            .draw(with: frame.insetBy(dx: 6, dy: 4), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?, characterIndex _: Int) {
        draw(withFrame: cellFrame, in: controlView)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?, characterIndex _: Int, layoutManager _: NSLayoutManager) {
        draw(withFrame: cellFrame, in: controlView)
    }

    static let equationAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFontManager.shared.convert(NSFont(name: "Times New Roman", size: 13) ?? .systemFont(ofSize: 13), toHaveTrait: .italicFontMask),
        .foregroundColor: NSColor.black,
    ]

    /// How big an equation's linear text draws, for sizing its attachment.
    static func equationSize(_ text: String) -> CGSize {
        let size = NSAttributedString(string: text, attributes: equationAttributes).size()
        return CGSize(width: ceil(size.width) + 2, height: ceil(size.height) + 2)
    }
}

// MARK: - Layout

/// TextKit 1 layout with the Word formatting AppKit doesn't have.
///
/// Capitals and hidden text change what's drawn without changing the text:
/// glyph generation swaps in capital glyphs — smaller ones for small caps —
/// and generates nothing visible for hidden runs, so the letters as typed are
/// what gets saved. Tab leaders and boxed runs are drawn behind the glyphs.
final class WordLayoutManager: NSLayoutManager, NSLayoutManagerDelegate {
    override init() {
        super.init()
        delegate = self
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
        properties: UnsafePointer<NSLayoutManager.GlyphProperty>,
        characterIndexes: UnsafePointer<Int>,
        font: NSFont,
        forGlyphRange glyphRange: NSRange
    ) -> Int {
        guard let storage = layoutManager.textStorage, glyphRange.length > 0 else { return 0 }
        let first = characterIndexes[0]
        let last = characterIndexes[glyphRange.length - 1]
        let span = NSRange(location: first, length: last - first + 1)

        var hidden = false
        var caps: String?
        storage.enumerateAttributes(in: span, options: []) { attributes, _, stop in
            if attributes[.wordHidden] != nil { hidden = true }
            if let value = attributes[.wordCaps] as? String { caps = value }
            if hidden || caps != nil { stop.pointee = true }
        }
        guard hidden || caps != nil else { return 0 }

        let count = glyphRange.length
        var newGlyphs = Array(UnsafeBufferPointer(start: glyphs, count: count))
        var newProperties = Array(UnsafeBufferPointer(start: properties, count: count))
        let string = storage.string as NSString
        let ctFont = font as CTFont

        for index in 0 ..< count {
            let character = characterIndexes[index]
            let attributes = storage.attributes(at: character, effectiveRange: nil)

            if attributes[.wordHidden] != nil {
                newProperties[index] = .null
                continue
            }
            guard attributes[.wordCaps] != nil else { continue }

            // Swap the glyph for its capital, from the same font.
            let unit = string.character(at: character)
            guard let scalar = UnicodeScalar(unit) else { continue }
            let upper = String(Character(scalar)).uppercased()
            guard upper.utf16.count == 1, let upperUnit = upper.utf16.first, upperUnit != unit else { continue }
            var source = [upperUnit]
            var glyph: CGGlyph = 0
            // Small capitals get their smaller size from the font attribute — the
            // reader sets lowercase letters smaller — since TextKit lays glyphs
            // out with the run's own font whatever font is passed here.
            if CTFontGetGlyphsForCharacters(ctFont, &source, &glyph, 1) {
                newGlyphs[index] = glyph
            }
        }

        newGlyphs.withUnsafeBufferPointer { glyphBuffer in
            newProperties.withUnsafeBufferPointer { propertyBuffer in
                layoutManager.setGlyphs(
                    glyphBuffer.baseAddress!,
                    properties: propertyBuffer.baseAddress!,
                    characterIndexes: characterIndexes,
                    font: font,
                    forGlyphRange: glyphRange
                )
            }
        }
        return count
    }

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, let container = textContainers.first else { return }
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)

        // Boxed runs.
        storage.enumerateAttribute(.wordRunBorder, in: characters, options: []) { value, range, _ in
            guard let value = value as? String else { return }
            let parts = value.split(separator: "|")
            let width = parts.first.flatMap { Double($0) }.map { CGFloat($0) } ?? 0.5
            let color = parts.count > 1 ? WordML.color(hex: String(parts[1])) ?? .black : .black
            let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            color.setStroke()
            enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                    in: container) { rect, _ in
                let box = rect.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -1, dy: 0)
                let path = NSBezierPath(rect: box)
                path.lineWidth = max(width, 0.5)
                path.stroke()
            }
        }

        // Tab leaders: a tab whose stop asks for one is filled with it.
        let string = storage.string as NSString
        var index = characters.location
        while index < NSMaxRange(characters) {
            let found = string.range(of: "\t", options: [], range: NSRange(location: index, length: NSMaxRange(characters) - index))
            guard found.location != NSNotFound else { break }
            index = NSMaxRange(found)
            drawLeader(forTabAt: found.location, in: storage, origin: origin)
        }
    }

    private func drawLeader(forTabAt location: Int, in storage: NSTextStorage, origin: NSPoint) {
        guard let style = storage.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle,
              style.tabStops.contains(where: { $0.options[.wordLeader] != nil })
        else { return }

        let glyph = glyphIndexForCharacter(at: location)
        // Not `notShownAttribute`: a tab's own glyph is never shown, which is
        // exactly the space a leader fills.
        guard glyph < numberOfGlyphs, storage.attribute(.wordHidden, at: location, effectiveRange: nil) == nil else { return }
        let fragment = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let start = self.location(forGlyphAt: glyph)
        let next = glyph + 1
        let end: CGFloat = next < numberOfGlyphs && lineFragmentRect(forGlyphAt: next, effectiveRange: nil).minY == fragment.minY
            ? self.location(forGlyphAt: next).x
            : fragment.width

        // The stop a tab lands on is the first one past where it starts.
        let padding = textContainers.first?.lineFragmentPadding ?? 0
        guard let stop = style.tabStops.first(where: { $0.location > start.x - padding + 0.5 }),
              let leader = stop.options[.wordLeader] as? String
        else { return }

        let font = storage.attribute(.font, at: location, effectiveRange: nil) as? NSFont ?? .systemFont(ofSize: 12)
        let color = storage.attribute(.foregroundColor, at: location, effectiveRange: nil) as? NSColor ?? .black
        let mark: String = switch leader {
        case "hyphen": "-"
        case "underscore", "heavy": "_"
        case "middleDot": "·"
        default: "."
        }
        let markAttributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let markWidth = (mark as NSString).size(withAttributes: markAttributes).width
        guard markWidth > 0, end - start.x > markWidth * 2 else { return }

        // Marks sit on a fixed grid, so the leaders of neighbouring lines line
        // up the way Word's do.
        var x = ceil((start.x + markWidth / 2) / markWidth) * markWidth
        let top = origin.y + fragment.minY + start.y - font.ascender
        while x + markWidth <= end - markWidth / 2 {
            (mark as NSString).draw(at: NSPoint(x: origin.x + fragment.minX + x, y: top), withAttributes: markAttributes)
            x += markWidth
        }
    }
}

// MARK: - Symbol fonts

/// Word stores symbols from dingbat fonts as private-use characters, U+F020 to
/// U+F0FF, which only mean something in that font.
enum SymbolFonts {
    /// Fonts macOS ships with the same private-use layout Word expects, so the
    /// characters can simply be drawn in them.
    static let drawable: Set<String> = ["wingdings", "webdings"]

    static func isSymbolFont(_ name: String?) -> Bool {
        guard let name = name?.lowercased() else { return false }
        return name.hasPrefix("wingdings") || name.hasPrefix("webdings") || name == "symbol"
    }

    /// Apple's Symbol is a Unicode font, so Word's Symbol characters are mapped
    /// through the Symbol encoding to the Unicode characters they draw.
    static func unicode(forSymbol code: UInt32) -> String? {
        let byte = code & 0xFF
        if let mapped = symbolEncoding[UInt8(byte)] { return mapped }
        if (0x20 ... 0x7E).contains(byte), let scalar = UnicodeScalar(byte) { return String(Character(scalar)) }
        return nil
    }

    private static let symbolEncoding: [UInt8: String] = [
        0x22: "∀", 0x24: "∃", 0x27: "∋", 0x2A: "∗", 0x2D: "−", 0x40: "≅",
        0x41: "Α", 0x42: "Β", 0x43: "Χ", 0x44: "Δ", 0x45: "Ε", 0x46: "Φ", 0x47: "Γ", 0x48: "Η", 0x49: "Ι",
        0x4A: "ϑ", 0x4B: "Κ", 0x4C: "Λ", 0x4D: "Μ", 0x4E: "Ν", 0x4F: "Ο", 0x50: "Π", 0x51: "Θ", 0x52: "Ρ",
        0x53: "Σ", 0x54: "Τ", 0x55: "Υ", 0x56: "ς", 0x57: "Ω", 0x58: "Ξ", 0x59: "Ψ", 0x5A: "Ζ", 0x5C: "∴",
        0x5E: "⊥", 0x61: "α", 0x62: "β", 0x63: "χ", 0x64: "δ", 0x65: "ε", 0x66: "φ", 0x67: "γ", 0x68: "η",
        0x69: "ι", 0x6A: "ϕ", 0x6B: "κ", 0x6C: "λ", 0x6D: "μ", 0x6E: "ν", 0x6F: "ο", 0x70: "π", 0x71: "θ",
        0x72: "ρ", 0x73: "σ", 0x74: "τ", 0x75: "υ", 0x76: "ϖ", 0x77: "ω", 0x78: "ξ", 0x79: "ψ", 0x7A: "ζ",
        0x7E: "∼", 0xA1: "ϒ", 0xA2: "′", 0xA3: "≤", 0xA4: "⁄", 0xA5: "∞", 0xA6: "ƒ", 0xA7: "♣", 0xA8: "♦",
        0xA9: "♥", 0xAA: "♠", 0xAB: "↔", 0xAC: "←", 0xAD: "↑", 0xAE: "→", 0xAF: "↓", 0xB0: "°", 0xB1: "±",
        0xB2: "″", 0xB3: "≥", 0xB4: "×", 0xB5: "∝", 0xB6: "∂", 0xB7: "•", 0xB8: "÷", 0xB9: "≠", 0xBA: "≡",
        0xBB: "≈", 0xBC: "…", 0xBF: "↵", 0xC0: "ℵ", 0xC1: "ℑ", 0xC2: "ℜ", 0xC3: "℘", 0xC4: "⊗", 0xC5: "⊕",
        0xC6: "∅", 0xC7: "∩", 0xC8: "∪", 0xC9: "⊃", 0xCA: "⊇", 0xCB: "⊄", 0xCC: "⊂", 0xCD: "⊆", 0xCE: "∈",
        0xCF: "∉", 0xD0: "∠", 0xD1: "∇", 0xD2: "®", 0xD3: "©", 0xD4: "™", 0xD5: "∏", 0xD6: "√", 0xD7: "⋅",
        0xD8: "¬", 0xD9: "∧", 0xDA: "∨", 0xDB: "⇔", 0xDC: "⇐", 0xDD: "⇑", 0xDE: "⇒", 0xDF: "⇓", 0xE0: "◊",
        0xE1: "〈", 0xE2: "®", 0xE3: "©", 0xE4: "™", 0xE5: "∑", 0xF1: "〉", 0xF2: "∫",
    ]
}

extension NSAttributedString {
    /// True when some run carries `key` with this exact value.
    func containsAttribute(_ key: NSAttributedString.Key, value: String) -> Bool {
        var found = false
        enumerateAttribute(key, in: NSRange(location: 0, length: length), options: []) { current, _, stop in
            if current as? String == value {
                found = true
                stop.pointee = true
            }
        }
        return found
    }
}

extension String {
    /// Each match of `pattern` replaced by what `transform` makes of its
    /// capture groups — group 0 is the whole match.
    func replacingMatches(of pattern: String, with transform: ([String]) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return self }
        let source = self as NSString
        var result = ""
        var last = 0
        for match in regex.matches(in: self, range: NSRange(location: 0, length: source.length)) {
            result += source.substring(with: NSRange(location: last, length: match.range.location - last))
            let groups = (0 ..< match.numberOfRanges).map { index -> String in
                let range = match.range(at: index)
                return range.location == NSNotFound ? "" : source.substring(with: range)
            }
            result += transform(groups)
            last = NSMaxRange(match.range)
        }
        return result + source.substring(from: last)
    }

    /// The capture groups of every match of `pattern`.
    func captures(of pattern: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
        let source = self as NSString
        return regex.matches(in: self, range: NSRange(location: 0, length: source.length)).map { match in
            (0 ..< match.numberOfRanges).map { index in
                let range = match.range(at: index)
                return range.location == NSNotFound ? "" : source.substring(with: range)
            }
        }
    }
}
