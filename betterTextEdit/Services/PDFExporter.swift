import AppKit

/// Writes formatted text out as a PDF.
///
/// This goes through `NSPrintOperation` rather than drawing pages by hand with
/// Core Text. The print machinery already knows how to paginate an
/// `NSTextView`, and — unlike a Core Text framesetter — it draws text
/// attachments, so a document's pictures survive into the PDF.
private var storageKey = 0

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
        info.leftMargin = layout.leftMargin
        info.rightMargin = layout.rightMargin
        info.topMargin = layout.topMargin
        info.bottomMargin = layout.bottomMargin
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
        let size = NSSize(width: layout.textWidth, height: layout.paperHeight)
        // The same layout the editor uses, so what prints is what's on screen —
        // including the Word formatting `WordLayoutManager` draws.
        let storage = NSTextStorage(attributedString: attributed)
        let layoutManager = WordLayoutManager()
        let container = NSTextContainer(size: NSSize(width: size.width, height: .greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        let textView = NSTextView(frame: NSRect(origin: .zero, size: size), textContainer: container)
        textView.textContainerInset = .zero
        textView.isVerticallyResizable = true
        textView.minSize = NSSize(width: size.width, height: 0)
        textView.maxSize = NSSize(width: size.width, height: .greatestFiniteMagnitude)
        // As tall as the laid-out text, so pagination neither stops short nor
        // runs on to blank pages.
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container).height
        textView.setFrameSize(NSSize(width: size.width, height: max(ceil(used), 1)))
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
