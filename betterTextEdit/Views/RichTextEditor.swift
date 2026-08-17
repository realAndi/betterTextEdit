import AppKit
import SwiftUI

// MARK: - Formatting controller

/// The bridge between betterTextEdit's formatting UI — the format bar and the Format
/// menu — and the text view that actually holds the document.
///
/// It reads the attributes under the insertion point so the controls show what
/// is really there, and it writes changes back through `shouldChangeText` /
/// `didChangeText` so every edit lands in the text view's own undo stack.
@MainActor
final class RichTextController: ObservableObject {
    weak var textView: NSTextView?

    @Published var fontFamily = "Helvetica"
    @Published var fontSize: CGFloat = 12
    @Published var isBold = false
    @Published var isItalic = false
    @Published var isUnderlined = false
    @Published var textColor = Color.black
    @Published var alignment: NSTextAlignment = .natural
    @Published private(set) var wordCount = 0

    static let sizeRange: ClosedRange<CGFloat> = 6 ... 288

    /// The installed families, with the document's own family added if it isn't
    /// one of them — legacy PostScript families like Times, and any font the
    /// document names but this Mac doesn't have, would otherwise leave the
    /// typeface control blank.
    var availableFamilies: [String] {
        let installed = NSFontManager.shared.availableFontFamilies
        return installed.contains(fontFamily) ? installed : [fontFamily] + installed
    }

    // MARK: Reading state

    /// Pulls the current attributes out of the text view. Called whenever the
    /// selection, the typing attributes, or the text itself changes.
    func refresh() {
        guard let textView, let storage = textView.textStorage else { return }

        let selection = textView.selectedRange()
        let attributes: [NSAttributedString.Key: Any] = if selection.length > 0, storage.length > 0 {
            storage.attributes(at: min(selection.location, storage.length - 1), effectiveRange: nil)
        } else {
            textView.typingAttributes
        }

        let font = attributes[.font] as? NSFont ?? .systemFont(ofSize: 12)
        let traits = NSFontManager.shared.traits(of: font)

        fontFamily = font.familyName ?? font.fontName
        fontSize = font.pointSize
        isBold = traits.contains(.boldFontMask)
        isItalic = traits.contains(.italicFontMask)
        isUnderlined = (attributes[.underlineStyle] as? Int ?? 0) != 0
        textColor = Color(nsColor: (attributes[.foregroundColor] as? NSColor) ?? .black)
        alignment = (attributes[.paragraphStyle] as? NSParagraphStyle)?.alignment ?? .natural
    }

    func refreshWordCount() {
        guard let string = textView?.string else { return }
        // Counting is linear, so don't do it for documents where it would be
        // felt on every keystroke.
        guard string.count <= 500_000 else {
            wordCount = -1
            return
        }
        wordCount = string.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    // MARK: Applying changes

    func setFamily(_ family: String) {
        guard family != fontFamily else { return }
        applyFont { NSFontManager.shared.convert($0, toFamily: family) }
    }

    func setSize(_ size: CGFloat) {
        let clamped = min(max(size, Self.sizeRange.lowerBound), Self.sizeRange.upperBound)
        guard clamped != fontSize else { return }
        applyFont { NSFontManager.shared.convert($0, toSize: clamped) }
    }

    func nudgeSize(by delta: CGFloat) {
        setSize(fontSize + delta)
    }

    func toggleBold() {
        let turningOn = !isBold
        applyFont { font in
            turningOn
                ? NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
                : NSFontManager.shared.convert(font, toNotHaveTrait: .boldFontMask)
        }
    }

    func toggleItalic() {
        let turningOn = !isItalic
        applyFont { font in
            turningOn
                ? NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
                : NSFontManager.shared.convert(font, toNotHaveTrait: .italicFontMask)
        }
    }

    func toggleUnderline() {
        let value = isUnderlined ? 0 : NSUnderlineStyle.single.rawValue
        apply { storage, range in
            storage.addAttribute(.underlineStyle, value: value, range: range)
        } typing: { attributes in
            attributes[.underlineStyle] = value
        }
    }

    func setColor(_ color: Color) {
        let nsColor = NSColor(color)
        apply { storage, range in
            storage.addAttribute(.foregroundColor, value: nsColor, range: range)
        } typing: { attributes in
            attributes[.foregroundColor] = nsColor
        }
    }

    /// Alignment goes through the text view's own actions, which already know
    /// how to expand the selection to whole paragraphs and register undo.
    func setAlignment(_ alignment: NSTextAlignment) {
        guard let textView else { return }
        switch alignment {
        case .center: textView.alignCenter(nil)
        case .right: textView.alignRight(nil)
        case .justified: textView.alignJustified(nil)
        default: textView.alignLeft(nil)
        }
        refresh()
    }

    func showFontPanel() {
        guard let textView else { return }
        textView.window?.makeFirstResponder(textView)
        NSFontManager.shared.orderFrontFontPanel(nil)
    }

    func showColorPanel() {
        guard let textView else { return }
        textView.window?.makeFirstResponder(textView)
        NSApp.orderFrontColorPanel(nil)
    }

    // MARK: Plumbing

    private func applyFont(_ transform: @escaping (NSFont) -> NSFont) {
        apply { storage, range in
            storage.enumerateAttribute(.font, in: range, options: []) { value, subrange, _ in
                let font = (value as? NSFont) ?? .systemFont(ofSize: 12)
                storage.addAttribute(.font, value: transform(font), range: subrange)
            }
        } typing: { attributes in
            let font = (attributes[.font] as? NSFont) ?? .systemFont(ofSize: 12)
            attributes[.font] = transform(font)
        }
    }

    /// Applies a change to every selected range, or — when nothing is selected —
    /// to the typing attributes, so the next thing typed picks it up.
    private func apply(
        _ change: (NSTextStorage, NSRange) -> Void,
        typing: (inout [NSAttributedString.Key: Any]) -> Void
    ) {
        guard let textView, let storage = textView.textStorage else { return }

        let ranges = textView.selectedRanges.map(\.rangeValue).filter { $0.length > 0 }
        if ranges.isEmpty {
            var attributes = textView.typingAttributes
            typing(&attributes)
            textView.typingAttributes = attributes
            refresh()
            return
        }

        guard textView.shouldChangeText(inRanges: ranges as [NSValue], replacementStrings: nil) else { return }
        storage.beginEditing()
        for range in ranges {
            change(storage, range)
        }
        storage.endEditing()
        textView.didChangeText()

        var attributes = textView.typingAttributes
        typing(&attributes)
        textView.typingAttributes = attributes
        refresh()
    }
}

// MARK: - Editor

/// A word-processor view over the document's own `NSTextStorage`.
///
/// The text view edits that storage in place, so nothing is converted on the way
/// in or out: the fonts, colours, paragraph spacing, alignment, lists, and
/// tables that came out of the `.docx` are the same objects that go back into it
/// when the file is saved.
///
/// The page is laid out at the document's real measure — its paper width minus
/// its margins — so lines break where they break in Word.
struct RichTextEditor: NSViewRepresentable {
    @ObservedObject var document: EditorDocument

    func makeCoordinator() -> Coordinator {
        Coordinator(document: document)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let layout = document.pageLayout

        // Build the TextKit 1 stack by hand so the view attaches to the
        // document's existing storage rather than making its own.
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(
            size: NSSize(width: layout.textWidth, height: .greatestFiniteMagnitude)
        )
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        layoutManager.addTextContainer(container)
        document.storage.addLayoutManager(layoutManager)

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: layout.paperWidth, height: 200), textContainer: container)
        textView.delegate = context.coordinator
        textView.isRichText = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.importsGraphics = true
        textView.usesFontPanel = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.allowsImageEditing = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = []
        textView.minSize = NSSize(width: layout.paperWidth, height: 0)
        textView.maxSize = NSSize(width: layout.paperWidth, height: .greatestFiniteMagnitude)
        // Paper, not canvas: a document keeps its own colours, so it needs a
        // light page behind it in either appearance.
        textView.drawsBackground = true
        textView.backgroundColor = .white
        textView.insertionPointColor = .black
        textView.textContainerInset = NSSize(
            width: max((layout.paperWidth - layout.textWidth) / 2, 0),
            height: layout.topMargin
        )
        textView.postsFrameChangedNotifications = true

        let page = PageHostView(textView: textView, pageWidth: layout.paperWidth)
        page.autoresizingMask = []

        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .underPageBackgroundColor
        scrollView.documentView = page

        context.coordinator.attach(textView: textView, page: page, scrollView: scrollView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.page?.pageWidth = document.pageLayout.paperWidth
        scrollView.needsLayout = true
    }

    static func dismantleNSView(_: NSScrollView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        private let document: EditorDocument
        private(set) weak var textView: NSTextView?
        private(set) weak var page: PageHostView?
        private weak var scrollView: NSScrollView?

        init(document: EditorDocument) {
            self.document = document
        }

        func attach(textView: NSTextView, page: PageHostView, scrollView: NSScrollView) {
            self.textView = textView
            self.page = page
            self.scrollView = scrollView
            document.formatting.textView = textView

            // Start the insertion point at the top and adopt the formatting
            // that's actually there, so the format bar opens showing the
            // document's own typeface rather than the view's default.
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            if document.storage.length > 0 {
                textView.typingAttributes = document.storage.attributes(at: 0, effectiveRange: nil)
            }

            document.formatting.refresh()
            document.formatting.refreshWordCount()

            let center = NotificationCenter.default
            center.addObserver(
                self, selector: #selector(viewFrameChanged),
                name: NSView.frameDidChangeNotification, object: textView
            )
            center.addObserver(
                self, selector: #selector(showFindPanel),
                name: .editorShowFind, object: nil
            )
            scrollView.contentView.postsFrameChangedNotifications = true
            center.addObserver(
                self, selector: #selector(viewFrameChanged),
                name: NSView.frameDidChangeNotification, object: scrollView.contentView
            )

            DispatchQueue.main.async { [weak self] in
                self?.page?.needsLayout = true
                textView.window?.makeFirstResponder(textView)
            }
        }

        func detach() {
            NotificationCenter.default.removeObserver(self)
            if document.formatting.textView === textView {
                document.formatting.textView = nil
            }
            // Leave the storage unattached so the next editor can take it over.
            if let layoutManager = textView?.layoutManager {
                document.storage.removeLayoutManager(layoutManager)
            }
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        @objc private func viewFrameChanged() {
            page?.needsLayout = true
            page?.layoutSubtreeIfNeeded()
        }

        @objc private func showFindPanel() {
            guard let textView, textView.window?.isKeyWindow == true else { return }
            textView.performFindPanelAction(nil)
        }

        func textDidChange(_: Notification) {
            document.markRichEdited()
            document.formatting.refresh()
            document.formatting.refreshWordCount()
            reportCursor()
            // The page grows and shrinks with the text.
            page?.needsLayout = true
        }

        func textViewDidChangeSelection(_: Notification) {
            document.formatting.refresh()
            reportCursor()
        }

        func textViewDidChangeTypingAttributes(_: Notification) {
            document.formatting.refresh()
        }

        private func reportCursor() {
            guard let textView else { return }
            let location = min(textView.selectedRange().location, textView.string.utf16.count)
            let prefix = (textView.string as NSString).substring(to: location)
            let lines = prefix.split(separator: "\n", omittingEmptySubsequences: false)
            document.cursorLine = max(lines.count, 1)
            document.cursorColumn = (lines.last?.utf16.count ?? 0) + 1
        }
    }
}

// MARK: - Page host

/// Holds the text view as a page: centred, at the document's paper width, on a
/// darker surround — the arrangement every word processor uses.
final class PageHostView: NSView {
    private let textView: NSTextView
    private let margin: CGFloat = 24

    var pageWidth: CGFloat {
        didSet {
            guard pageWidth != oldValue else { return }
            needsLayout = true
        }
    }

    init(textView: NSTextView, pageWidth: CGFloat) {
        self.textView = textView
        self.pageWidth = pageWidth
        super.init(frame: NSRect(x: 0, y: 0, width: pageWidth + margin * 2, height: 200))
        addSubview(textView)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()

        let available = enclosingScrollView?.contentView.bounds.width ?? bounds.width
        let width = max(available, pageWidth + margin * 2)
        let pageHeight = measuredTextHeight()

        let x = ((width - pageWidth) / 2).rounded()
        let target = NSRect(x: x, y: margin, width: pageWidth, height: pageHeight)
        if textView.frame != target {
            textView.frame = target
        }

        let size = NSSize(width: width, height: pageHeight + margin * 2)
        if frame.size != size {
            frame.size = size
        }
    }

    /// The page is exactly as tall as the text laid out at this measure. Asking
    /// TextKit directly — rather than trusting the text view to have resized
    /// itself yet — is what keeps the paper under the whole document.
    private func measuredTextHeight() -> CGFloat {
        guard let layoutManager = textView.layoutManager, let container = textView.textContainer else {
            return textView.frame.height
        }
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container).height
        let clipHeight = enclosingScrollView?.contentView.bounds.height ?? 0
        return max(used + textView.textContainerInset.height * 2, clipHeight - margin * 2, 200)
    }

    override func draw(_: NSRect) {
        NSColor.underPageBackgroundColor.setFill()
        bounds.fill()

        // A hairline around the page so it reads as a sheet rather than a panel.
        let page = NSRect(x: textView.frame.minX, y: textView.frame.minY,
                          width: textView.frame.width, height: textView.frame.height)
        NSColor.separatorColor.setStroke()
        NSBezierPath(rect: page.insetBy(dx: -0.5, dy: -0.5)).stroke()
    }
}
