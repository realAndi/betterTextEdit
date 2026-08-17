import AppKit
import SwiftUI

/// A source / plain-text editor built on TextKit 1.
///
/// Two things make this render reliably inside SwiftUI on current macOS:
///
/// 1. **TextKit 1 is pinned explicitly.** `NSTextView.scrollableTextView()`
///    hands back a TextKit 2 view; the moment the code reaches into the legacy
///    `textStorage`/`layoutManager` for highlighting, the text system forks and
///    the view stops painting. Accessing `layoutManager` up front reverts the
///    view to TextKit 1 so storage and display share one stack.
///
/// 2. **No `NSRulerView`.** Turning on the scroll view's ruler
///    (`rulersVisible`) makes the document text view stop compositing inside
///    SwiftUI's layer-backed host — the ruler paints but the text goes blank.
///    Line numbers are instead drawn by a plain sibling gutter view that syncs
///    to the scroll position, which leaves the text view's compositing intact.
struct CodeEditor: NSViewRepresentable {
    @Binding var text: String
    let language: FileLanguage
    let fontSize: Double
    /// The chosen font family, or "" for the system monospaced face.
    var fontName: String = EditorFonts.systemMonospaced
    let wordWrap: Bool
    var translucent: Bool = false
    /// The colours to paint with. Handed in rather than read from the store so
    /// SwiftUI sees it change and `updateNSView` runs.
    let theme: ResolvedTheme
    /// Whether to draw the line-number gutter.
    var showsLineNumbers: Bool = true
    /// Extra leading between lines, in points.
    var lineSpacing: Double = EditorMetrics.defaultLineSpacing
    /// Whether to draw a band behind the line the caret is on.
    var highlightsCurrentLine: Bool = true
    let cursorPosition: (Int, Int) -> Void

    private static let gutterWidth: CGFloat = 52

    /// Whether the editor paints its own background.
    ///
    /// A theme never overrides this. When the window is translucent the editor
    /// stays clear and the theme's canvas is laid over the blur by the window
    /// instead — see `themeWash(tint:blur:theme:)` — so the code sits on tinted
    /// glass rather than on a solid slab punched through the middle of it. The
    /// theme still supplies every other colour: the text, the caret, the
    /// selection, the gutter.
    private var paintsCanvas: Bool {
        !translucent
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()

        let scrollView = NSTextView.scrollableTextView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = !wordWrap
        scrollView.autohidesScrollers = true

        guard let textView = scrollView.documentView as? NSTextView else {
            return container
        }

        // Pin to TextKit 1 before touching content (see type doc).
        _ = textView.layoutManager

        textView.delegate = context.coordinator
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        // Taken before anything overwrites it, while the view is still fresh.
        context.coordinator.systemSelection = textView.selectedTextAttributes
        applyCanvas(to: textView, scrollView: scrollView, systemSelection: context.coordinator.systemSelection)
        // Leave room on the left so glyphs never sit under the gutter.
        textView.textContainerInset = NSSize(width: 6, height: 12)
        textView.font = editorFont

        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = !wordWrap
        textView.autoresizingMask = wordWrap ? [.width] : []
        applyWrap(to: textView, scrollView: scrollView)

        textView.string = text

        // The gutter is a sibling of the scroll view — not a ruler — so it does
        // not disturb the text view's compositing.
        let gutter = LineNumberGutterView(textView: textView, scrollView: scrollView)
        gutter.paintsBackground = paintsCanvas
        gutter.theme = theme
        gutter.editorFontSize = CGFloat(fontSize)
        gutter.translatesAutoresizingMaskIntoConstraints = false
        gutter.isHidden = !showsLineNumbers

        // The editor's canvas and its current-line band, drawn *behind* the
        // scroll view rather than by the text view itself.
        //
        // Two reasons it can't be an attribute on the storage: a background
        // attribute is only as wide as the glyphs on that line, so a short line
        // would get a short stripe, and the highlighter rewrites every
        // attribute on every pass, so the two would fight. Two reasons it can't
        // be the text view's own background: the text view has to stay clear
        // for the window's glass to show through, and anything it did paint
        // would cover the band.
        let background = EditorBackgroundView(textView: textView, scrollView: scrollView)
        background.theme = theme
        background.paintsCanvas = paintsCanvas
        background.highlightsCurrentLine = highlightsCurrentLine
        background.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(background)
        container.addSubview(scrollView)
        container.addSubview(gutter)
        // Collapsing the gutter to nothing is what hides it: the text view is
        // pinned to its trailing edge, so the code reclaims the space rather
        // than leaving a gap where the numbers were.
        let gutterWidth = gutter.widthAnchor.constraint(
            equalToConstant: showsLineNumbers ? Self.gutterWidth : 0
        )
        NSLayoutConstraint.activate([
            gutter.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            gutter.topAnchor.constraint(equalTo: container.topAnchor),
            gutter.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            gutterWidth,

            scrollView.leadingAnchor.constraint(equalTo: gutter.trailingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            // Exactly under the scroll view, not under the gutter: the gutter
            // paints its own background and would cover the band anyway. The
            // active line is marked there by brightening its number instead.
            background.leadingAnchor.constraint(equalTo: gutter.trailingAnchor),
            background.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            background.topAnchor.constraint(equalTo: container.topAnchor),
            background.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        context.coordinator.textView = textView
        context.coordinator.scrollView = scrollView
        context.coordinator.gutter = gutter
        context.coordinator.background = background
        context.coordinator.gutterWidth = gutterWidth
        context.coordinator.paintedTheme = theme
        context.coordinator.paintedLineSpacing = lineSpacing
        context.coordinator.paintedCanvas = paintsCanvas
        context.coordinator.applyHighlight(now: true)

        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.showFindPanel),
            name: .editorShowFind,
            object: nil
        )
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard
            let scrollView = context.coordinator.scrollView,
            let textView = context.coordinator.textView
        else { return }
        context.coordinator.parent = self

        if textView.string != text {
            let selection = textView.selectedRange()
            let wasEmpty = textView.string.isEmpty
            textView.string = text
            let clampedLocation = min(selection.location, textView.string.utf16.count)
            textView.setSelectedRange(NSRange(location: clampedLocation, length: 0))
            context.coordinator.applyHighlight(now: false)
            if wasEmpty, !text.isEmpty {
                DispatchQueue.main.async {
                    textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
                    scrollView.contentView.scroll(to: .zero)
                    scrollView.reflectScrolledClipView(scrollView.contentView)
                }
            }
            context.coordinator.gutter?.needsDisplay = true
        }

        if (textView.textContainer?.widthTracksTextView ?? false) != wordWrap {
            textView.isHorizontallyResizable = !wordWrap
            textView.autoresizingMask = wordWrap ? [.width] : []
            scrollView.hasHorizontalScroller = !wordWrap
            applyWrap(to: textView, scrollView: scrollView)
            textView.needsDisplay = true
        }

        if textView.font != editorFont {
            textView.font = editorFont
            textView.typingAttributes[.font] = editorFont
            context.coordinator.applyHighlight(now: false)
            context.coordinator.gutter?.editorFontSize = CGFloat(fontSize)
        }

        if let background = context.coordinator.background {
            background.theme = theme
            background.paintsCanvas = paintsCanvas
            background.highlightsCurrentLine = highlightsCurrentLine
        }

        if let gutterWidth = context.coordinator.gutterWidth {
            let target = showsLineNumbers ? Self.gutterWidth : 0
            if gutterWidth.constant != target {
                gutterWidth.constant = target
                context.coordinator.gutter?.isHidden = !showsLineNumbers
            }
        }

        // React to a theme change, to the line spacing, or to the translucency
        // toggle — any of them means repainting the storage.
        if context.coordinator.paintedTheme != theme
            || context.coordinator.paintedLineSpacing != lineSpacing
            || context.coordinator.paintedCanvas != paintsCanvas {
            context.coordinator.paintedTheme = theme
            context.coordinator.paintedLineSpacing = lineSpacing
            context.coordinator.paintedCanvas = paintsCanvas
            applyCanvas(to: textView, scrollView: scrollView, systemSelection: context.coordinator.systemSelection)
            context.coordinator.gutter?.paintsBackground = paintsCanvas
            context.coordinator.gutter?.theme = theme
            context.coordinator.applyHighlight(now: true)
            textView.needsDisplay = true
        }
    }

    /// Everything about the editor that the theme decides. Shared by setup and
    /// update so the two can't drift.
    ///
    /// - Parameter systemSelection: what `selectedTextAttributes` held before
    ///   anything here touched it, so the System theme can be handed back
    ///   exactly what AppKit gave us.
    private func applyCanvas(
        to textView: NSTextView,
        scrollView: NSScrollView,
        systemSelection: [NSAttributedString.Key: Any]
    ) {
        // Neither the text view nor its scroll view ever paints. The canvas is
        // `EditorBackgroundView`'s job, because the current-line band has to go
        // *under* the text and anything painted here would cover it. Under
        // glass that view paints nothing either, and the window shows through
        // exactly as before.
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear

        textView.textColor = theme.foreground
        textView.insertionPointColor = theme.caret

        // A theme's own highlight is half of what makes it read as that theme —
        // macOS's blue over a warm canvas never does. The System theme is left
        // with AppKit's own attributes untouched, though, because the system
        // selection knows things a colour doesn't, chiefly that it should go
        // quiet when the view isn't first responder.
        textView.selectedTextAttributes = theme.followsSystem
            ? systemSelection
            : [.backgroundColor: theme.selection]

        textView.typingAttributes = [
            .font: editorFont,
            .foregroundColor: theme.foreground,
            .paragraphStyle: SyntaxHighlighter.paragraphStyle(font: editorFont, lineSpacing: lineSpacing),
        ]
    }

    /// Configure the text container for the current wrap mode.
    private func applyWrap(to textView: NSTextView, scrollView: NSScrollView) {
        guard let container = textView.textContainer else { return }
        container.widthTracksTextView = wordWrap
        if wordWrap {
            let width = max(scrollView.contentSize.width, 1)
            container.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
            textView.frame.size.width = width
        } else {
            container.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        }
    }

    private var editorFont: NSFont {
        EditorFonts.font(named: fontName, size: CGFloat(fontSize))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditor
        weak var textView: NSTextView?
        weak var scrollView: NSScrollView?
        weak var gutter: LineNumberGutterView?
        let highlighter = SyntaxHighlighter()
        /// The theme the storage was last painted with, so a theme change can be
        /// told apart from the many other reasons `updateNSView` runs.
        var paintedTheme: ResolvedTheme?
        /// The leading the storage was last laid out with, for the same reason.
        var paintedLineSpacing: Double?
        /// Whether the canvas was being painted last time round.
        var paintedCanvas: Bool?
        /// Held so hiding the gutter can collapse it.
        var gutterWidth: NSLayoutConstraint?
        weak var background: EditorBackgroundView?
        /// AppKit's own selection attributes, kept so switching back to the
        /// System theme restores them rather than approximating them.
        var systemSelection: [NSAttributedString.Key: Any] = [:]
        private var highlightWorkItem: DispatchWorkItem?

        init(parent: CodeEditor) {
            self.parent = parent
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        func textDidChange(_: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            applyHighlight(now: false)
            reportCursor()
            gutter?.needsDisplay = true
            background?.needsDisplay = true
        }

        func textViewDidChangeSelection(_: Notification) {
            reportCursor()
            // The band and the gutter's active-line number both follow the
            // caret, so both need repainting on every selection change.
            background?.needsDisplay = true
            gutter?.needsDisplay = true
        }

        /// Re-highlight the shared storage. `now` runs synchronously (setup);
        /// otherwise the work is debounced so typing stays responsive.
        func applyHighlight(now: Bool) {
            highlightWorkItem?.cancel()
            let work = { [weak self] in
                guard let self, let storage = textView?.textStorage else { return }
                let font = EditorFonts.font(named: parent.fontName, size: CGFloat(parent.fontSize))
                highlighter.apply(
                    to: storage,
                    language: parent.language,
                    font: font,
                    theme: parent.theme,
                    lineSpacing: parent.lineSpacing
                )
                textView?.needsDisplay = true
                gutter?.needsDisplay = true
                background?.needsDisplay = true
            }
            if now {
                work()
                return
            }
            let item = DispatchWorkItem(block: work)
            highlightWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: item)
        }

        private func reportCursor() {
            guard let textView else { return }
            let location = min(textView.selectedRange().location, textView.string.utf16.count)
            let prefix = (textView.string as NSString).substring(to: location)
            let lines = prefix.split(separator: "\n", omittingEmptySubsequences: false)
            parent.cursorPosition(max(lines.count, 1), (lines.last?.utf16.count ?? 0) + 1)
        }

        @objc func showFindPanel() {
            guard let textView, textView.window?.isKeyWindow == true else { return }
            textView.performFindPanelAction(nil)
        }
    }
}

/// The editor's canvas, and the band behind the line the caret is on.
///
/// A sibling of the scroll view, sitting under it — the same trick the gutter
/// uses, and for the same reason: it reads the text view's TextKit 1 layout
/// without joining its view hierarchy, so the text view's compositing is
/// untouched.
final class EditorBackgroundView: NSView {
    private weak var textView: NSTextView?
    private weak var scrollView: NSScrollView?

    var theme = ResolvedTheme(BuiltInThemes.system) {
        didSet { needsDisplay = true }
    }

    /// Whether the canvas is painted at all. False under glass, where the
    /// window's own surface is the canvas and this only draws the band.
    var paintsCanvas = true {
        didSet { needsDisplay = true }
    }

    var highlightsCurrentLine = true {
        didSet { needsDisplay = true }
    }

    init(textView: NSTextView, scrollView: NSScrollView) {
        self.textView = textView
        self.scrollView = scrollView
        super.init(frame: .zero)
        wantsLayer = true

        let clip = scrollView.contentView
        clip.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(contentMoved),
            name: NSView.boundsDidChangeNotification, object: clip
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(contentMoved),
            name: NSView.frameDidChangeNotification, object: textView
        )
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { NotificationCenter.default.removeObserver(self) }

    override var isFlipped: Bool { true }

    // Purely decorative: every click belongs to the text view above it.
    override func hitTest(_: NSPoint) -> NSView? { nil }

    @objc private func contentMoved() { needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        if paintsCanvas {
            theme.background.setFill()
            bounds.fill()
        }

        guard highlightsCurrentLine, let rect = currentLineRect() else { return }
        theme.currentLine.setFill()
        rect.fill()
    }

    /// The band to paint, in this view's coordinates, or `nil` when there
    /// shouldn't be one.
    private func currentLineRect() -> NSRect? {
        guard let textView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer,
              let clip = scrollView?.contentView
        else { return nil }

        // A selection replaces the highlight rather than joining it: two
        // overlapping bands read as a mistake, and the selection is the more
        // useful of the two to be able to see exactly.
        let selection = textView.selectedRange()
        guard selection.length == 0 else { return nil }

        let source = textView.string as NSString
        let location = min(selection.location, source.length)
        let lineRange = source.lineRange(for: NSRange(location: location, length: 0))
        let glyphRange = layoutManager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)

        // Document space to this view's: shift by the container's inset, then
        // by however far the clip view has scrolled.
        rect.origin.y += textView.textContainerOrigin.y - clip.bounds.origin.y
        // Full width regardless of how long the line is — a band that stopped
        // at the last character would just be a second kind of selection.
        rect.origin.x = 0
        rect.size.width = bounds.width

        guard rect.intersects(bounds) else { return nil }
        return rect
    }
}

/// A line-number gutter drawn as a sibling of the scroll view (not an
/// `NSRulerView`). It reads the text view's TextKit 1 layout and redraws as the
/// content scrolls or changes.
final class LineNumberGutterView: NSView {
    private weak var textView: NSTextView?
    private weak var scrollView: NSScrollView?

    /// Line numbers sit a little smaller than the code they label, and track it
    /// so the gutter still reads at large text sizes.
    var editorFontSize: CGFloat = 13 {
        didSet { needsDisplay = true }
    }

    private var font: NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: max(9, min(editorFontSize - 2, 16)), weight: .regular)
    }

    /// When false the gutter stays transparent so the window background shows
    /// through — which only happens under the System theme.
    var paintsBackground = true {
        didSet { needsDisplay = true }
    }

    /// The colours to draw with. Defaults to the System theme so the view is
    /// valid the instant it's created, before its owner configures it.
    var theme = ResolvedTheme(BuiltInThemes.system) {
        didSet { needsDisplay = true }
    }

    init(textView: NSTextView, scrollView: NSScrollView) {
        self.textView = textView
        self.scrollView = scrollView
        super.init(frame: .zero)
        wantsLayer = true

        let clip = scrollView.contentView
        clip.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrollChanged),
            name: NSView.boundsDidChangeNotification, object: clip
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrollChanged),
            name: NSView.frameDidChangeNotification, object: textView
        )
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { NotificationCenter.default.removeObserver(self) }

    // Flipped so y grows downward, matching the text view's coordinate space.
    override var isFlipped: Bool { true }

    @objc private func scrollChanged() { needsDisplay = true }

    /// The one-based line the caret sits on, or 0 when there's a selection
    /// rather than a caret — matching the band, which also stands down then.
    ///
    /// Counts UTF-16 line feeds directly rather than slicing the string: this
    /// runs on every selection change, and taking a copy of everything above
    /// the caret to count it would mean copying the whole document each time
    /// the caret moved near the end of a long one. CRLF carries a line feed of
    /// its own, so it counts correctly too.
    private func currentLineNumber() -> Int {
        guard let textView else { return 0 }
        let selection = textView.selectedRange()
        guard selection.length == 0 else { return 0 }

        let source = textView.string as NSString
        let location = min(selection.location, source.length)
        var line = 1
        for index in 0 ..< location where source.character(at: index) == 0x0A {
            line += 1
        }
        return line
    }

    override func draw(_ dirtyRect: NSRect) {
        if paintsBackground {
            theme.gutterBackground.setFill()
            bounds.fill()
        }

        guard
            let textView,
            let layoutManager = textView.layoutManager,
            let textContainer = textView.textContainer,
            let clip = scrollView?.contentView
        else { return }

        // Visible portion of the document, in text-view coordinates.
        let visibleRect = clip.bounds
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        let source = textView.string as NSString

        var lineNumber = 1
        if glyphRange.location > 0 {
            let charIndex = layoutManager.characterIndexForGlyph(at: glyphRange.location)
            // `isNewline`, not `== "\n"`: Swift reads CRLF as one Character, so
            // a Windows-authored file would count no line breaks at all and the
            // gutter would restart at 1 every time it scrolled.
            lineNumber += source.substring(to: charIndex).reduce(into: 0) { count, character in
                if character.isNewline { count += 1 }
            }
        }

        // Which line the caret is on, so that number can be brightened. It's
        // how the gutter joins in with the current-line band next to it —
        // painting the band across the gutter instead would fight the gutter's
        // own background and the separator at its edge.
        let caretLine = currentLineNumber()

        let dimmed: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: theme.gutterForeground,
        ]
        let active: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: theme.gutterActiveForeground,
        ]
        let originY = textView.textContainerOrigin.y
        let scrollY = visibleRect.origin.y

        var glyphIndex = glyphRange.location
        while glyphIndex < NSMaxRange(glyphRange) {
            let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
            let lineRange = source.lineRange(for: NSRange(location: charIndex, length: 0))
            let lineGlyphRange = layoutManager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
            let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)

            // Map document y → gutter y (both flipped, top-left origin).
            let y = lineRect.minY + originY - scrollY

            let label = "\(lineNumber)" as NSString
            let attributes = lineNumber == caretLine ? active : dimmed
            let size = label.size(withAttributes: attributes)
            label.draw(
                at: NSPoint(x: bounds.width - size.width - 9, y: y + (lineRect.height - size.height) / 2),
                withAttributes: attributes
            )

            lineNumber += 1
            let next = NSMaxRange(lineGlyphRange)
            glyphIndex = next > glyphIndex ? next : glyphIndex + 1
        }

        theme.separator.setFill()
        NSRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height).fill()
    }
}
