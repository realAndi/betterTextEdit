import AppKit

/// Breaks and justifies justified paragraphs of Word documents the way Word
/// does.
///
/// Word and AppKit disagree about justified text in two ways that show.
///
/// - AppKit spreads a justified line's spare room across every letter as well
///   as every space. Word puts all of it in the spaces, so its words keep
///   their natural widths and sit somewhere else along the line.
/// - Word will keep a word that runs past the margin on its line, squeezing the
///   spaces to make room, as long as less than about two fifths of the word
///   overflows and no space has to lose more than a quarter of its width.
///   AppKit moves such a word down to the next line, and every line of the
///   paragraph after it breaks somewhere else.
///
/// For a justified paragraph, this typesetter gives each line just enough room
/// to keep the word Word would keep, then sets every word at its natural width
/// with the line's spare room — or its shortfall — shared equally among its
/// spaces. Everything else is AppKit's own layout.
final class WordTypesetter: NSATSTypesetter {
    /// Word keeps an overflowing word on a justified line when less than this
    /// share of it runs past the margin. Measured from Word 16 for Mac across
    /// Calibri, Times New Roman, and Arial: words up to 0.391 over were kept,
    /// and none from 0.395.
    static let keepableOverflow: CGFloat = 0.393

    /// The most of its width Word lets a space lose to keep a word on a line:
    /// lines needing 24.6% were squeezed, and none needing 26.2%.
    static let maximumSqueeze: CGFloat = 0.25

    /// How a justified line's glyphs are placed: each at its natural distance
    /// from the first, plus an equal share of the spare room for every space
    /// before it.
    private struct Plan {
        let lineRange: NSRange
        /// The first glyph the plan places — the one after the line's last tab;
        /// anything before that is where AppKit put it.
        let start: Int
        /// Where the line has to end, in line fragment coordinates.
        let right: CGFloat
        /// Each glyph's own advance, from `start` to the end of the line.
        let advances: [CGFloat]
        /// Whether each of those glyphs is a space that takes a share.
        let stretches: [Bool]
        /// The natural width from `start` to the end of the last visible glyph.
        let natural: CGFloat
        let spaces: Int
        /// Where `start` landed, once AppKit has placed it.
        var origin: CGFloat?
    }

    private var plan: Plan?
    /// How much wider the current line was made, to be taken back before the
    /// line is set.
    private var widened: CGFloat = 0

    private var usesWordJustification: Bool {
        (layoutManager as? WordLayoutManager)?.usesWordMetrics == true
            && currentParagraphStyle?.alignment == .justified
            && currentParagraphStyle?.baseWritingDirection != .rightToLeft
    }

    override func beginParagraph() {
        super.beginParagraph()
        plan = nil
        widened = 0
    }

    /// A tab whose next stop is past the right margin goes as far as the
    /// margin in Word, and what follows it is set flush against the margin.
    /// AppKit can't reach such a stop and wraps the tab onto a line of its own
    /// — a line Word doesn't have.
    override func textTab(forGlyphLocation glyphLocation: CGFloat, writingDirection direction: NSWritingDirection,
                          maxLocation: CGFloat) -> NSTextTab? {
        if let tab = super.textTab(forGlyphLocation: glyphLocation, writingDirection: direction, maxLocation: maxLocation) {
            return tab
        }
        guard (layoutManager as? WordLayoutManager)?.usesWordMetrics == true, let style = currentParagraphStyle,
              style.tabStops.contains(where: { $0.location > maxLocation }), glyphLocation < maxLocation
        else { return nil }
        // Just short of the limit: a tab that ends on it counts as overflowing.
        return NSTextTab(textAlignment: .right, location: maxLocation - 0.01)
    }

    // MARK: Breaking

    override func getLineFragmentRect(
        _ lineFragmentRect: NSRectPointer!,
        usedRect lineFragmentUsedRect: NSRectPointer!,
        remaining remainingRect: NSRectPointer!,
        forStartingGlyphAt startingGlyphIndex: Int,
        proposedRect: NSRect,
        lineSpacing: CGFloat,
        paragraphSpacingBefore: CGFloat,
        paragraphSpacingAfter: CGFloat
    ) {
        super.getLineFragmentRect(
            lineFragmentRect, usedRect: lineFragmentUsedRect, remaining: remainingRect,
            forStartingGlyphAt: startingGlyphIndex, proposedRect: proposedRect, lineSpacing: lineSpacing,
            paragraphSpacingBefore: paragraphSpacingBefore, paragraphSpacingAfter: paragraphSpacingAfter
        )
        widened = 0
        plan = nil
        guard usesWordJustification, let lineFragmentRect, lineFragmentRect.pointee.width > 0,
              let room = extraRoomForKeptWord(from: startingGlyphIndex, width: lineFragmentRect.pointee.width)
        else { return }
        widened = room
        lineFragmentRect.pointee.size.width += room
    }

    /// The room the line starting at `first` needs beyond its width to keep
    /// the word Word would keep there — `nil` when Word keeps nothing extra.
    private func extraRoomForKeptWord(from first: Int, width: CGFloat) -> CGFloat? {
        guard let measure = GlyphMeasure(self), let style = currentParagraphStyle else { return nil }
        let end = NSMaxRange(paragraphGlyphRange)
        let right = measure.right(of: width, style: style, padding: lineFragmentPadding)
        var x = lineFragmentPadding + (first == paragraphGlyphRange.location ? style.firstLineHeadIndent : style.headIndent)

        var glyph = first
        var wordStart = first
        var wordX = x
        var spaceWidth: CGFloat = 0
        while glyph < end {
            switch measure.kind(of: glyph) {
            case .unmeasurable:
                return nil
            case .tab:
                // Word, like AppKit, justifies only after a line's last tab.
                guard let stop = measure.tabStop(after: x - lineFragmentPadding, style: style),
                      stop.alignment == .left || stop.alignment == .natural
                else { return nil }
                x = stop.location + lineFragmentPadding
                spaceWidth = 0
                glyph += 1
                wordStart = glyph
                wordX = x
            case .lineBreak:
                return nil
            case .space:
                let advance = measure.advance(of: glyph)
                x += advance
                spaceWidth += advance
                glyph += 1
                wordStart = glyph
                wordX = x
            case .breakAfter, .other:
                let advance = measure.advance(of: glyph)
                guard x + advance > right + 0.001 else {
                    x += advance
                    glyph += 1
                    if measure.kind(of: glyph - 1) == .breakAfter {
                        wordStart = glyph
                        wordX = x
                    }
                    continue
                }
                // This word runs past the margin. A word alone on its line
                // has nowhere else to go; otherwise see whether Word keeps it.
                guard wordStart > first else { return nil }
                var wordEnd = wordStart
                var endX = wordX
                while wordEnd < end {
                    let kind = measure.kind(of: wordEnd)
                    guard kind == .other || kind == .breakAfter else {
                        if kind == .unmeasurable { return nil }
                        break
                    }
                    endX += measure.advance(of: wordEnd)
                    wordEnd += 1
                    if kind == .breakAfter { break }
                }
                let overflow = endX - right
                let word = endX - wordX
                guard word > 0, overflow / word < Self.keepableOverflow,
                      overflow <= spaceWidth * Self.maximumSqueeze
                else { return nil }
                return overflow + 0.01
            }
        }
        return nil
    }

    // MARK: Justifying

    override func willSetLineFragmentRect(
        _ lineRect: NSRectPointer!,
        forGlyphRange glyphRange: NSRange,
        usedRect: NSRectPointer!,
        baselineOffset _: UnsafeMutablePointer<CGFloat>!
    ) {
        plan = nil
        guard let lineRect, let usedRect else { return }
        if widened > 0 {
            lineRect.pointee.size.width -= widened
            usedRect.pointee.size.width = min(usedRect.pointee.size.width, lineRect.pointee.width)
        }
        // Word justifies every line but a paragraph's last — unless that one
        // kept a word it has to squeeze in.
        let isLast = NSMaxRange(glyphRange) >= NSMaxRange(paragraphGlyphRange)
        guard usesWordJustification, !isLast || widened > 0 else { return }
        plan = makePlan(for: glyphRange, width: lineRect.pointee.width)
    }

    private func makePlan(for line: NSRange, width: CGFloat) -> Plan? {
        guard let measure = GlyphMeasure(self), let style = currentParagraphStyle, line.length > 0 else { return nil }
        var start = line.location
        for glyph in line.location ..< NSMaxRange(line) {
            switch measure.kind(of: glyph) {
            case .tab: start = glyph + 1
            case .unmeasurable: return nil
            default: break
            }
        }

        // The spaces that stretch are the ones between words: not those
        // trailing at the end of the line.
        var lastVisible = start - 1
        for glyph in stride(from: NSMaxRange(line) - 1, through: start, by: -1) {
            let kind = measure.kind(of: glyph)
            if kind == .other || kind == .breakAfter {
                lastVisible = glyph
                break
            }
        }
        guard lastVisible >= start else { return nil }

        var advances: [CGFloat] = []
        var stretches: [Bool] = []
        var natural: CGFloat = 0
        var spaces = 0
        for glyph in start ..< NSMaxRange(line) {
            let kind = measure.kind(of: glyph)
            let advance = kind == .lineBreak ? 0 : measure.advance(of: glyph)
            let stretch = kind == .space && glyph < lastVisible
            advances.append(advance)
            stretches.append(stretch)
            if glyph <= lastVisible { natural += advance }
            if stretch { spaces += 1 }
        }
        guard spaces > 0 else { return nil }
        return Plan(lineRange: line, start: start, right: measure.right(of: width, style: style, padding: lineFragmentPadding),
                    advances: advances, stretches: stretches, natural: natural, spaces: spaces)
    }

    override func setLocation(
        _ location: NSPoint,
        withAdvancements advancements: UnsafePointer<CGFloat>!,
        forStartOfGlyphRange glyphRange: NSRange
    ) {
        guard var plan, glyphRange.length > 0,
              NSIntersectionRange(glyphRange, plan.lineRange) == glyphRange,
              NSMaxRange(glyphRange) > plan.start
        else {
            super.setLocation(location, withAdvancements: advancements, forStartOfGlyphRange: glyphRange)
            return
        }

        // Whatever comes before the plan's first glyph — a list's marker and
        // its tabs — stays where AppKit put it, and says where that first
        // glyph starts.
        var first = glyphRange.location
        if plan.origin == nil {
            var x = location.x
            if first < plan.start {
                guard let advancements else {
                    super.setLocation(location, withAdvancements: advancements, forStartOfGlyphRange: glyphRange)
                    return
                }
                for index in 0 ..< plan.start - first {
                    x += advancements[index]
                }
            } else if first > plan.start {
                // The first planned glyph went by unplaced; leave the line be.
                self.plan = nil
                super.setLocation(location, withAdvancements: advancements, forStartOfGlyphRange: glyphRange)
                return
            }
            plan.origin = x
            self.plan = plan
        }
        if first < plan.start {
            super.setLocation(location, withAdvancements: advancements,
                              forStartOfGlyphRange: NSRange(location: first, length: plan.start - first))
            first = plan.start
        }
        guard let origin = plan.origin else { return }

        let share = (plan.right - origin - plan.natural) / CGFloat(plan.spaces)
        var position = origin
        for index in 0 ..< (first - plan.start) {
            position += plan.advances[index] + (plan.stretches[index] ? share : 0)
        }
        // Each glyph is placed on its own, as AppKit places a justified line's:
        // a run's advancements are ignored on a line AppKit doesn't justify
        // itself, such as a paragraph's last.
        for glyph in first ..< NSMaxRange(glyphRange) {
            super.setLocation(NSPoint(x: position, y: location.y), withAdvancements: nil,
                              forStartOfGlyphRange: NSRange(location: glyph, length: 1))
            let index = glyph - plan.start
            position += plan.advances[index] + (plan.stretches[index] ? share : 0)
        }
    }
}

// MARK: - Measuring glyphs

/// A glyph's natural width as the text system sets it — its own advance in
/// its run's font, plus any character spacing — and what it is for breaking.
private struct GlyphMeasure {
    enum Kind {
        case other
        /// A hyphen or dash, after which a line may break.
        case breakAfter
        case space
        case tab
        case lineBreak
        /// A picture or anything else whose width isn't the font's to say.
        case unmeasurable
    }

    let manager: NSLayoutManager
    let storage: NSTextStorage
    let string: NSString

    init?(_ typesetter: NSTypesetter) {
        guard let manager = typesetter.layoutManager, let storage = manager.textStorage else { return nil }
        self.manager = manager
        self.storage = storage
        string = storage.string as NSString
    }

    func kind(of glyph: Int) -> Kind {
        guard glyph < manager.numberOfGlyphs else { return .lineBreak }
        let character = manager.characterIndexForGlyph(at: glyph)
        guard character < string.length else { return .lineBreak }
        switch string.character(at: character) {
        case 0x20: return .space
        case 0x09: return .tab
        case 0x0A, 0x0D, 0x2028, 0x2029, 0x0C, 0x85: return .lineBreak
        case 0x2D, 0x2010, 0x2013, 0x2014: return .breakAfter
        case 0xFFFC: return .unmeasurable
        default:
            if storage.attribute(.attachment, at: character, effectiveRange: nil) != nil { return .unmeasurable }
            if let expansion = storage.attribute(.expansion, at: character, effectiveRange: nil) as? CGFloat, expansion != 0 {
                return .unmeasurable
            }
            return .other
        }
    }

    func advance(of glyph: Int) -> CGFloat {
        if manager.propertyForGlyph(at: glyph) == .null { return 0 }
        let character = manager.characterIndexForGlyph(at: glyph)
        guard let font = storage.attribute(.font, at: character, effectiveRange: nil) as? NSFont else { return 0 }
        var cgGlyph = manager.cgGlyph(at: glyph)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(font as CTFont, .horizontal, &cgGlyph, &advance, 1)
        let kern = storage.attribute(.kern, at: character, effectiveRange: nil) as? CGFloat ?? 0
        return advance.width + kern
    }

    /// Where text has to end on a line `width` wide.
    func right(of width: CGFloat, style: NSParagraphStyle, padding: CGFloat) -> CGFloat {
        let tail = style.tailIndent
        if tail > 0 { return padding + tail }
        return width - padding + tail
    }

    /// The tab stop a tab at `x` goes to.
    func tabStop(after x: CGFloat, style: NSParagraphStyle) -> NSTextTab? {
        if let stop = style.tabStops.first(where: { $0.location > x + 0.001 }) { return stop }
        let interval = style.defaultTabInterval > 0 ? style.defaultTabInterval : 36
        return NSTextTab(textAlignment: .left, location: (floor(x / interval) + 1) * interval)
    }
}
