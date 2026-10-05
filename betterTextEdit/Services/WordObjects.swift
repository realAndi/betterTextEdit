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
    /// How a paragraph breaks across pages, as space-separated words:
    /// `keepNext` (on the same page as the next paragraph), `keepLines` (not
    /// split at all), and `noWidowControl` — Word keeps a paragraph's first
    /// or last line from standing alone on a page unless it's told not to.
    static let wordPagination = NSAttributedString.Key("betterTextEdit.wordPagination")
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
/// borders — and its shading.
///
/// Word places a paragraph's box differently from how a text block lays out.
/// Its borders sit outside the text, out into the margin if need be, rather
/// than pushing the text in; the space before a paragraph goes above its top
/// border, not inside it; and the line under the last paragraph takes room of
/// its own. So this block takes no room in AppKit's layout at all — it only
/// marks which paragraphs share a box — and `WordLayoutManager` makes the room
/// and draws the box by Word's rules. It keeps Word's own description of every
/// border, so a save writes back what came in.
final class WordParagraphBlock: NSTextBlock {
    struct Border: Equatable {
        /// Word's line style: `single`, `double`, `dotted`, `thick`, …
        var style: String
        var width: CGFloat
        /// The gap Word leaves between the border and the text.
        var space: CGFloat
        /// `nil` is Word's `auto`: black on a white page.
        var color: NSColor?

        /// The width Word draws: the nearest of its own line widths at or
        /// below the one asked for, so a seven-eighths-point border draws as
        /// three quarters. It still takes the room it asked for.
        var drawnWidth: CGFloat {
            let widths: [CGFloat] = [0.25, 0.5, 0.75, 1, 1.5, 2.25, 3, 4.5, 6]
            return widths.last { $0 <= width + 0.001 } ?? width
        }
    }

    /// Borders by side — `top`, `left`, `bottom`, `right` — and `between`, the
    /// line Word draws between the paragraphs of one box.
    var borders: [String: Border] = [:]
    var shading: NSColor?

    override init() {
        super.init()
        // Without a width a text block shrinks to nothing — one letter a line.
        // A hundred percent with no margins, borders, or padding is the column,
        // exactly as if there were no block.
        setValue(100, type: .percentageValueType, for: .width)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    /// A side's border, if it has one that draws.
    func drawn(_ side: String) -> Border? {
        guard let border = borders[side], border.width > 0, !["nil", "none"].contains(border.style) else { return nil }
        return border
    }
}

/// A line's height the way Word works it out: from the tallest type on the
/// line, measured from the font itself — its ascent, descent, and line gap,
/// unrounded — and then stretched or set by the paragraph's line spacing.
struct WordLineMetrics {
    private(set) var ascent: CGFloat = 0
    private(set) var descent: CGFloat = 0
    private(set) var leading: CGFloat = 0

    /// `nil` when the line has a picture on it, whose height the text system
    /// knows and this doesn't, or nothing visible to measure.
    init?(_ text: NSAttributedString, _ range: NSRange) {
        // Spaces and tabs don't size a line in Word, however large they're
        // set — only what's printed does. Nor does the paragraph mark, unless
        // it's all the line has: it gives an empty paragraph its height, but a
        // mark set larger than the text before it makes no difference.
        let string = text.string as NSString
        var content = range
        var mark: NSRange?
        if content.length > 0, [0x0A, 0x0D, 0x2029, 0x85].contains(string.character(at: NSMaxRange(range) - 1)) {
            content.length -= 1
            mark = NSRange(location: NSMaxRange(content), length: 1)
        }
        guard let measured = Self.measure(text, content, skippingBlanks: true)
            ?? mark.flatMap({ Self.measure(text, $0, skippingBlanks: false) })
            ?? Self.measure(text, content, skippingBlanks: false)
        else { return nil }
        self = measured
    }

    private init() {}

    private static func measure(_ text: NSAttributedString, _ range: NSRange, skippingBlanks: Bool) -> WordLineMetrics? {
        guard range.length > 0 else { return nil }
        let string = text.string as NSString
        var line = WordLineMetrics()
        var measured = false
        var picture = false
        text.enumerateAttributes(in: range, options: []) { attributes, run, stop in
            if attributes[.attachment] != nil {
                picture = true
                stop.pointee = true
                return
            }
            if skippingBlanks, string.substring(with: run).allSatisfy({ $0 == " " || $0 == "\t" }) { return }
            guard attributes[.wordHidden] == nil, let font = attributes[.font] as? NSFont else { return }
            // A stand-in for a font this Mac doesn't have is measured as the
            // font the document asked for, which is what Word measures.
            if let original = attributes[.wordFontName] as? String, font.familyName == WordML.standIn(for: original),
               let office = WordML.officeLineMetrics(original) {
                line.ascent = max(line.ascent, office.ascent * font.pointSize)
                line.descent = max(line.descent, office.descent * font.pointSize)
                line.leading = max(line.leading, office.gap * font.pointSize)
            } else {
                let face = font as CTFont
                line.ascent = max(line.ascent, CTFontGetAscent(face))
                line.descent = max(line.descent, CTFontGetDescent(face))
                line.leading = max(line.leading, CTFontGetLeading(face))
            }
            measured = true
        }
        // A picture's height is the text system's to know, not this.
        return measured && !picture ? line : nil
    }

    /// The line's height and its baseline's distance from the top, under the
    /// paragraph's line spacing as the reader set it: `lineHeightMultiple` for
    /// Word's multiples, a minimum for *at least*, and both for *exactly*.
    func placed(by style: NSParagraphStyle) -> (height: CGFloat, baseline: CGFloat) {
        // Exactly: Word puts the baseline four fifths of the way down the line,
        // whatever the type.
        if style.maximumLineHeight > 0, style.minimumLineHeight == style.maximumLineHeight {
            return (style.maximumLineHeight, style.maximumLineHeight * 0.8)
        }
        let multiple = style.lineHeightMultiple > 0 ? style.lineHeightMultiple : 1
        var height = (ascent + descent + leading) * multiple
        // The line gap sits above the type. The room a multiple adds goes below
        // it; the room one takes away comes out of the whole line evenly.
        var baseline = (leading + ascent) * min(multiple, 1)
        // At least: any extra room goes above the type.
        if style.minimumLineHeight > height {
            baseline += style.minimumLineHeight - height
            height = style.minimumLineHeight
        }
        if style.maximumLineHeight > 0, height > style.maximumLineHeight {
            height = style.maximumLineHeight
            baseline = height * 0.8
        }
        return (height, baseline)
    }
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
/// what gets saved. Tab leaders, boxed runs, and paragraph borders and shading
/// are drawn behind the glyphs.
///
/// For a Word document it also measures lines the way Word does — see
/// `usesWordMetrics`.
final class WordLayoutManager: NSLayoutManager, NSLayoutManagerDelegate {
    /// Lay lines out by Word's measurements rather than AppKit's.
    ///
    /// The two disagree about almost every line. AppKit rounds a line's height
    /// to whole points — 13 for ten-point Calibri, where Word uses the font's
    /// own 12.2 — and over a page of text that's several lines' difference.
    /// Word also adds a paragraph's space before and the previous paragraph's
    /// space after by taking the larger of the two rather than their sum; it
    /// keeps the space before the first paragraph of all; and it puts the room
    /// a line gains from line spacing below the text where AppKit puts it above.
    /// With this on, every line is placed where Word places it, and justified
    /// text is broken and spaced as Word does it — see `WordTypesetter`.
    var usesWordMetrics = false {
        didSet {
            guard usesWordMetrics != oldValue else { return }
            typesetter = usesWordMetrics ? WordTypesetter() : NSTypesetter.sharedSystemTypesetter
            guard let storage = textStorage else { return }
            invalidateLayout(forCharacterRange: NSRange(location: 0, length: storage.length), actualCharacterRange: nil)
        }
    }

    override init() {
        super.init()
        delegate = self
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Word's lines

    func layoutManager(
        _: NSLayoutManager,
        shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
        lineFragmentUsedRect: UnsafeMutablePointer<NSRect>,
        baselineOffset: UnsafeMutablePointer<CGFloat>,
        in _: NSTextContainer,
        forGlyphRange glyphRange: NSRange
    ) -> Bool {
        guard usesWordMetrics, let storage = textStorage, storage.length > 0 else { return false }
        let characters = characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        guard characters.length > 0, NSMaxRange(characters) <= storage.length else { return false }
        let string = storage.string as NSString
        let style = paragraphStyle(at: characters.location, in: storage)

        let rect = lineFragmentRect.pointee
        let used = lineFragmentUsedRect.pointee
        // A line with a picture on it keeps AppKit's own measure of the line,
        // which is the one that knows how tall the picture is.
        let line: (height: CGFloat, baseline: CGFloat) = if let metrics = WordLineMetrics(storage, characters) {
            metrics.placed(by: style)
        } else {
            (used.height, baselineOffset.pointee - (used.minY - rect.minY))
        }

        let startsParagraph = characters.location == 0
            || Self.isParagraphBreak(string.character(at: characters.location - 1))
        let endsParagraph = NSMaxRange(characters) == storage.length
            || Self.isParagraphBreak(string.character(at: NSMaxRange(characters) - 1))
        let box = style.textBlocks.last as? WordParagraphBlock

        var above: CGFloat = 0
        if startsParagraph {
            let previous = characters.location > 0 ? paragraphStyle(at: characters.location - 1, in: storage) : nil
            above = style.paragraphSpacingBefore
            // Word keeps the larger of this paragraph's space before and the
            // last one's space after, rather than both — unless the two are in
            // different cells, which don't share space.
            if let previous, Self.sameContainer(previous, style) {
                above = max(above - previous.paragraphSpacing, 0)
            }
            if let box {
                let previousBox = previous?.textBlocks.last as? WordParagraphBlock
                if previousBox !== box, let top = box.drawn("top") {
                    above += top.width + top.space
                } else if previousBox === box, let between = box.drawn("between") {
                    above += between.width + between.space
                }
            }
        }

        var below: CGFloat = 0
        if endsParagraph {
            below = style.paragraphSpacing
            if let box, let bottom = box.drawn("bottom") {
                let next = NSMaxRange(characters) < storage.length ? paragraphStyle(at: NSMaxRange(characters), in: storage) : nil
                // The bottom border closes the box, under its last paragraph.
                if next?.textBlocks.last as? WordParagraphBlock !== box {
                    below = bottom.space + bottom.width + below
                }
            }
        }

        lineFragmentRect.pointee.size.height = above + line.height + below
        lineFragmentUsedRect.pointee.origin.y = rect.minY + above
        lineFragmentUsedRect.pointee.size.height = line.height
        baselineOffset.pointee = above + line.baseline
        return true
    }

    private func paragraphStyle(at index: Int, in storage: NSTextStorage) -> NSParagraphStyle {
        storage.attribute(.paragraphStyle, at: index, effectiveRange: nil) as? NSParagraphStyle ?? .default
    }

    private static func isParagraphBreak(_ unit: unichar) -> Bool {
        unit == 0x0A || unit == 0x0D || unit == 0x2029 || unit == 0x85
    }

    /// Whether two paragraphs sit in the same cell — or both outside any
    /// table — so that space between them is shared.
    private static func sameContainer(_ first: NSParagraphStyle, _ second: NSParagraphStyle) -> Bool {
        let a = first.textBlocks.filter { !($0 is WordParagraphBlock) }
        let b = second.textBlocks.filter { !($0 is WordParagraphBlock) }
        return a.count == b.count && zip(a, b).allSatisfy { $0 === $1 }
    }

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

        drawParagraphBoxes(in: characters, storage: storage, container: container, origin: origin)

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

    // MARK: Paragraph boxes

    /// Draws the borders and shading of every paragraph box with a line in
    /// `characters`, where Word draws them: around the text at each border's
    /// own distance, in the margin if that's where it falls, with the lines
    /// running a point and a half past the text at the ends.
    private func drawParagraphBoxes(in characters: NSRange, storage: NSTextStorage, container: NSTextContainer, origin: NSPoint) {
        var drawn: Set<Int> = []
        storage.enumerateAttribute(.paragraphStyle, in: characters, options: []) { value, range, _ in
            guard let box = (value as? NSParagraphStyle)?.textBlocks.last as? WordParagraphBlock else { return }
            let group = boxRange(box, around: range.location, storage: storage)
            guard drawn.insert(group.location).inserted else { return }
            drawBox(box, around: group, storage: storage, container: container, origin: origin)
        }
    }

    /// The paragraphs that share `box` with the one at `index`.
    private func boxRange(_ box: WordParagraphBlock, around index: Int, storage: NSTextStorage) -> NSRange {
        let string = storage.string as NSString
        let paragraph = string.paragraphRange(for: NSRange(location: index, length: 0))
        var start = paragraph.location
        while start > 0, paragraphStyle(at: start - 1, in: storage).textBlocks.last === box {
            start = string.paragraphRange(for: NSRange(location: start - 1, length: 0)).location
        }
        var end = NSMaxRange(paragraph)
        while end < string.length, paragraphStyle(at: end, in: storage).textBlocks.last === box {
            end = NSMaxRange(string.paragraphRange(for: NSRange(location: end, length: 0)))
        }
        return NSRange(location: start, length: end - start)
    }

    private func drawBox(_ box: WordParagraphBlock, around characters: NSRange, storage: NSTextStorage,
                         container: NSTextContainer, origin: NSPoint) {
        let glyphs = glyphRange(forCharacterRange: characters, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return }
        let fragment = lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
        let textTop = lineFragmentUsedRect(forGlyphAt: glyphs.location, effectiveRange: nil).minY
        let textBottom = lineFragmentUsedRect(forGlyphAt: NSMaxRange(glyphs) - 1, effectiveRange: nil).maxY

        // Across: from the paragraph's indents, which is where Word measures
        // the box from — not from where the text happens to reach.
        let style = paragraphStyle(at: characters.location, in: storage)
        let padding = container.lineFragmentPadding
        let measure = fragment.width - padding * 2
        var leftIndent = min(style.headIndent, style.firstLineHeadIndent)
        if !style.textLists.isEmpty, let marker = style.tabStops.first(where: { $0.location < style.headIndent }) {
            // A list's marker sits at a tab stop, its first line at zero.
            leftIndent = min(style.headIndent, marker.location)
        }
        let rightIndent = style.tailIndent < 0 ? -style.tailIndent : (style.tailIndent > 0 ? max(measure - style.tailIndent, 0) : 0)
        let textLeft = fragment.minX + padding + leftIndent
        let textRight = fragment.minX + padding + measure - rightIndent

        let top = box.drawn("top")
        let bottom = box.drawn("bottom")
        let left = box.drawn("left")
        let right = box.drawn("right")
        // Word draws a side's line a point and a quarter beyond its spacing,
        // and with no line there, runs the top and bottom on a point and a half.
        let leftInner = textLeft - (left.map { $0.space + 1.25 } ?? 1.5)
        let rightInner = textRight + (right.map { $0.space + 1.25 } ?? 1.5)
        let outerLeft = leftInner - (left?.width ?? 0)
        let outerRight = rightInner + (right?.width ?? 0)
        let innerTop = textTop - (top?.space ?? 0)
        let innerBottom = textBottom + (bottom?.space ?? 0)
        let outerTop = innerTop - (top?.width ?? 0)
        let outerBottom = innerBottom + (bottom?.width ?? 0)

        func place(_ rect: NSRect) -> NSRect {
            rect.offsetBy(dx: origin.x, dy: origin.y)
        }

        // A text view clips what it draws to its text container, and a box
        // reaches out into the margin. Open the clip out sideways to the whole
        // view, keeping its top and bottom — on paper those are the page's.
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        if let context = NSGraphicsContext.current?.cgContext, let view = container.textView {
            let clip = context.boundingBoxOfClipPath
            NSBezierPath(rect: NSRect(x: view.bounds.minX, y: clip.minY, width: view.bounds.width, height: clip.height)).setClip()
        }

        if let shading = box.shading {
            shading.setFill()
            place(NSRect(x: leftInner, y: innerTop, width: rightInner - leftInner, height: innerBottom - innerTop)).fill()
        }
        if let top {
            drawBorder(top, in: place(NSRect(x: outerLeft, y: outerTop, width: outerRight - outerLeft, height: top.drawnWidth)), horizontal: true)
        }
        if let bottom {
            drawBorder(bottom, in: place(NSRect(x: outerLeft, y: innerBottom, width: outerRight - outerLeft, height: bottom.drawnWidth)), horizontal: true)
        }
        if let left {
            drawBorder(left, in: place(NSRect(x: outerLeft, y: outerTop, width: left.drawnWidth, height: outerBottom - outerTop)), horizontal: false)
        }
        if let right {
            drawBorder(right, in: place(NSRect(x: rightInner, y: outerTop, width: right.drawnWidth, height: outerBottom - outerTop)), horizontal: false)
        }

        // Between the paragraphs of the box, above each one after the first.
        guard let between = box.drawn("between") else { return }
        let string = storage.string as NSString
        var paragraph = string.paragraphRange(for: NSRange(location: characters.location, length: 0))
        while NSMaxRange(paragraph) < NSMaxRange(characters) {
            paragraph = string.paragraphRange(for: NSRange(location: NSMaxRange(paragraph), length: 0))
            let glyph = glyphIndexForCharacter(at: paragraph.location)
            guard glyph < numberOfGlyphs else { break }
            let lineTop = lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil).minY
            let y = lineTop - between.space - between.width
            drawBorder(between, in: place(NSRect(x: outerLeft, y: y, width: outerRight - outerLeft, height: between.drawnWidth)), horizontal: true)
        }
    }

    /// One border line, filling `rect`, in Word's line style as near as it goes.
    private func drawBorder(_ border: WordParagraphBlock.Border, in rect: NSRect, horizontal: Bool) {
        (border.color ?? .black).set()
        switch border.style {
        case "double":
            // Two thin lines with a gap between, in the room of one.
            let third = (horizontal ? rect.height : rect.width) / 3
            if horizontal {
                NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: third).fill()
                NSRect(x: rect.minX, y: rect.maxY - third, width: rect.width, height: third).fill()
            } else {
                NSRect(x: rect.minX, y: rect.minY, width: third, height: rect.height).fill()
                NSRect(x: rect.maxX - third, y: rect.minY, width: third, height: rect.height).fill()
            }
        case "dotted", "dashed", "dashSmallGap", "dotDash", "dotDotDash", "dashDotStroked":
            let thickness = horizontal ? rect.height : rect.width
            let path = NSBezierPath()
            path.lineWidth = thickness
            if horizontal {
                path.move(to: NSPoint(x: rect.minX, y: rect.midY))
                path.line(to: NSPoint(x: rect.maxX, y: rect.midY))
            } else {
                path.move(to: NSPoint(x: rect.midX, y: rect.minY))
                path.line(to: NSPoint(x: rect.midX, y: rect.maxY))
            }
            let dash: [CGFloat] = border.style == "dotted"
                ? [thickness, thickness]
                : [thickness * 4, thickness * 2]
            path.setLineDash(dash, count: dash.count, phase: 0)
            path.stroke()
        default:
            rect.fill()
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
