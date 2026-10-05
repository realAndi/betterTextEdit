import AppKit

/// Writes formatted text out as a PDF.
///
/// This goes through `NSPrintOperation` rather than drawing pages by hand with
/// Core Text. The print machinery already knows how to paginate an
/// `NSTextView`, and — unlike a Core Text framesetter — it draws text
/// attachments, so a document's pictures survive into the PDF.
private var storageKey = 0

/// A text view a little wider than its text, so that what Word draws in the
/// margin — the ends of a paragraph's borders — prints too.
///
/// The origin is fixed rather than left to the text view, which centres its
/// text when the first line sits below the top — as it does when a document
/// opens with space before its first paragraph — and would shift every page
/// down by half that space.
private final class PrintTextView: NSTextView {
    var origin = NSPoint.zero
    override var textContainerOrigin: NSPoint { origin }

    private lazy var wordPages: WordPageBreaks? = {
        guard let manager = layoutManager as? WordLayoutManager, manager.usesWordMetrics else { return nil }
        return WordPageBreaks(manager)
    }()

    /// Ends a Word document's pages where Word would, rather than simply at
    /// the last line that fits — see `WordPageBreaks`.
    override func adjustPageHeightNew(_ newBottom: UnsafeMutablePointer<CGFloat>, top oldTop: CGFloat,
                                      bottom oldBottom: CGFloat, limit bottomLimit: CGFloat) {
        guard let wordPages, let bottom = wordPages.pageBottom(top: oldTop - origin.y, proposed: oldBottom - origin.y) else {
            super.adjustPageHeightNew(newBottom, top: oldTop, bottom: oldBottom, limit: bottomLimit)
            return
        }
        newBottom.pointee = bottom + origin.y
    }
}

/// Where Word ends a page.
///
/// A line goes on a page if its text fits — the space after it doesn't have
/// to. Then Word's keeping rules move the break up: a paragraph that keeps its
/// lines together isn't split; with widow and orphan control — on unless a
/// paragraph turns it off — neither a paragraph's first line nor its last is
/// left alone on a page; and a paragraph that keeps with the next one, as a
/// heading does, goes over to the next page with it. And a page break in the
/// text ends the page whatever else fits.
private struct WordPageBreaks {
    private struct Line {
        let top: CGFloat
        let textBottom: CGFloat
        let paragraph: Int
        /// The line holds a page break, so the page ends after it.
        let breaksPage: Bool
    }

    private struct Paragraph {
        var first: Int
        var last: Int
        let keepNext: Bool
        let keepLines: Bool
        let widowControl: Bool
    }

    private let lines: [Line]
    private let paragraphs: [Paragraph]

    init(_ manager: NSLayoutManager) {
        var lines: [Line] = []
        var paragraphs: [Paragraph] = []
        if let storage = manager.textStorage, manager.numberOfGlyphs > 0 {
            let string = storage.string as NSString
            manager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: manager.numberOfGlyphs)) { rect, used, _, glyphs, _ in
                let characters = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
                let start = characters.location
                let startsParagraph = start == 0 || [0x0A, 0x0D, 0x2029].contains(string.character(at: start - 1))
                if startsParagraph || paragraphs.isEmpty {
                    let words = Set(((storage.attribute(.wordPagination, at: min(start, string.length - 1), effectiveRange: nil) as? String) ?? "")
                        .split(separator: " ").map(String.init))
                    paragraphs.append(Paragraph(first: lines.count, last: lines.count, keepNext: words.contains("keepNext"),
                                                keepLines: words.contains("keepLines"), widowControl: !words.contains("noWidowControl")))
                }
                paragraphs[paragraphs.count - 1].last = lines.count
                let breaksPage = string.range(of: "\u{C}", options: .literal, range: characters).location != NSNotFound
                lines.append(Line(top: rect.minY, textBottom: used.maxY, paragraph: paragraphs.count - 1, breaksPage: breaksPage))
            }
        }
        self.lines = lines
        self.paragraphs = paragraphs
    }

    /// The bottom of the page that starts at `top` and could run to
    /// `proposed`, or `nil` to leave the break to AppKit.
    func pageBottom(top: CGFloat, proposed: CGFloat) -> CGFloat? {
        let first = lines.firstIndex { $0.top >= top - 0.01 } ?? lines.count
        let overflow = lines[first...].firstIndex { $0.textBottom > proposed + 0.01 }
        // A page break before the page fills ends it there.
        if let forced = lines[first...].firstIndex(where: \.breaksPage), forced + 1 < lines.count,
           overflow.map({ forced < $0 }) ?? true {
            return lines[forced + 1].top
        }
        guard let overflow else { return nil }
        var line = overflow
        let paragraph = paragraphs[lines[line].paragraph]
        let before = line - paragraph.first
        let count = paragraph.last - paragraph.first + 1
        if before > 0, paragraph.keepLines {
            line = paragraph.first
        } else if before > 0, paragraph.widowControl {
            if before < 2 {
                line = paragraph.first
            } else if count - before < 2 {
                line = before - 1 >= 2 ? line - 1 : paragraph.first
            }
        }
        // A paragraph that keeps with the next goes over with it.
        while lines[line].paragraph > 0, paragraphs[lines[line].paragraph].first == line {
            let previous = paragraphs[lines[line].paragraph - 1]
            guard previous.keepNext else { break }
            line = previous.first
        }
        // Rather than leave a page empty, break where the text first overflowed.
        if lines[line].top <= top + 0.5 { line = overflow }
        let bottom = lines[line].top
        return bottom > top + 0.5 ? bottom : nil
    }
}

enum PDFExporter {
    enum ExportError: LocalizedError {
        case failed

        var errorDescription: String? { "The PDF couldn’t be created." }
        var recoverySuggestion: String? { "Try saving as Rich Text or Word instead." }
    }

    @MainActor
    static func write(_ attributed: NSAttributedString, to url: URL, layout: PageLayout) throws {
        let info = printInfo(for: layout)
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url

        let operation = operation(for: attributed, layout: layout, printInfo: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false

        guard operation.run() else { throw ExportError.failed }
    }

    /// The page geometry a document asks for, as print settings.
    @MainActor
    static func printInfo(for layout: PageLayout) -> NSPrintInfo {
        let info = NSPrintInfo()
        info.paperSize = NSSize(width: layout.paperWidth, height: layout.paperHeight)
        // Part of each side margin goes to the printed view, for what Word
        // draws there — as much as the printer can reach, up to a third of an
        // inch. Any more and AppKit shrinks the page to fit.
        let printable = info.imageablePageBounds
        let reachLeft = max(min(layout.leftMargin - printable.minX, 24), 0)
        let reachRight = max(min(layout.rightMargin - (layout.paperWidth - printable.maxX), 24), 0)
        info.leftMargin = layout.leftMargin - reachLeft
        info.rightMargin = layout.rightMargin - reachRight
        // A text view counts down from the top, and AppKit sets each page of
        // one the bottom margin's distance from the top of the paper — so the
        // two are handed over swapped, or a page with a deeper top margin than
        // bottom prints its text too high.
        info.topMargin = layout.bottomMargin
        info.bottomMargin = layout.topMargin
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        return info
    }

    /// A print operation for formatted text — shared by PDF export, which
    /// saves it, and Print, which shows the panel.
    ///
    /// The text view is laid out at the printed measure so line breaks match
    /// what the page geometry asks for.
    @MainActor
    static func operation(for attributed: NSAttributedString, layout: PageLayout, printInfo: NSPrintInfo) -> NSPrintOperation {
        // The text sits in the view where the document's margins put it; the
        // print settings may have handed the view some of each margin.
        let reachLeft = max(layout.leftMargin - printInfo.leftMargin, 0)
        let reachRight = max(layout.rightMargin - printInfo.rightMargin, 0)
        let size = NSSize(width: layout.textWidth + reachLeft + reachRight, height: layout.paperHeight)
        // The same layout the editor uses, so what prints is what's on screen —
        // including the Word formatting `WordLayoutManager` draws.
        let storage = NSTextStorage(attributedString: attributed)
        let layoutManager = WordLayoutManager()
        layoutManager.usesWordMetrics = layout.usesWordMetrics
        let container = NSTextContainer(size: NSSize(width: layout.textWidth, height: .greatestFiniteMagnitude))
        container.widthTracksTextView = false
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        let textView = PrintTextView(frame: NSRect(origin: .zero, size: size), textContainer: container)
        textView.textContainerInset = .zero
        textView.origin = NSPoint(x: reachLeft, y: 0)
        textView.isVerticallyResizable = true
        textView.minSize = NSSize(width: size.width, height: 0)
        textView.maxSize = NSSize(width: size.width, height: .greatestFiniteMagnitude)
        // As tall as the laid-out text, so pagination neither stops short nor
        // runs on to blank pages: to the foot of the last line, not counting
        // the empty line AppKit keeps after a final paragraph mark, or the
        // space after the last paragraph — Word puts neither on a page.
        layoutManager.ensureLayout(for: container)
        var bottom = layoutManager.usedRect(for: container).maxY
        if layoutManager.numberOfGlyphs > 0 {
            let last = layoutManager.numberOfGlyphs - 1
            let line = layoutManager.lineFragmentRect(forGlyphAt: last, effectiveRange: nil)
            let style = storage.attribute(.paragraphStyle, at: layoutManager.characterIndexForGlyph(at: last), effectiveRange: nil)
            bottom = line.maxY - ((style as? NSParagraphStyle)?.paragraphSpacing ?? 0)
        }
        textView.setFrameSize(NSSize(width: size.width, height: max(ceil(bottom), 1)))
        // The view holds its storage only weakly, through the layout manager.
        objc_setAssociatedObject(textView, &storageKey, storage, .OBJC_ASSOCIATION_RETAIN)
        return NSPrintOperation(view: textView, printInfo: printInfo)
    }

    /// Wraps plain text so it can go out through a format that expects
    /// attributes. Code keeps its monospaced font; anything else would reflow
    /// into nonsense.
    static func attributedText(from text: String, monospaced: Bool) -> NSAttributedString {
        let font: NSFont = monospaced
            ? .monospacedSystemFont(ofSize: 10, weight: .regular)
            : .systemFont(ofSize: 12)
        return NSAttributedString(
            string: text,
            attributes: [.font: font, .foregroundColor: NSColor.black]
        )
    }
}
