import AppKit

/// Writes formatted text out as a PDF.
///
/// This goes through `NSPrintOperation` rather than drawing pages by hand with
/// Core Text. The print machinery already knows how to paginate an
/// `NSTextView`, and — unlike a Core Text framesetter — it draws text
/// attachments, so a document's pictures survive into the PDF.
enum PDFExporter {
    enum ExportError: LocalizedError {
        case failed

        var errorDescription: String? { "The PDF couldn’t be created." }
        var recoverySuggestion: String? { "Try saving as Rich Text or Word instead." }
    }

    @MainActor
    static func write(_ attributed: NSAttributedString, to url: URL, layout: PageLayout) throws {
        let paperSize = NSSize(width: layout.paperWidth, height: 792)

        let info = NSPrintInfo()
        info.paperSize = paperSize
        info.leftMargin = layout.leftMargin
        info.rightMargin = layout.rightMargin
        info.topMargin = layout.topMargin
        info.bottomMargin = layout.bottomMargin
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url

        // The text view is laid out at the printed measure so line breaks in the
        // PDF match what the page geometry asks for.
        let textView = NSTextView(frame: NSRect(origin: .zero, size: NSSize(width: layout.textWidth, height: paperSize.height)))
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textStorage?.setAttributedString(attributed)

        let operation = NSPrintOperation(view: textView, printInfo: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false

        guard operation.run() else { throw ExportError.failed }
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
