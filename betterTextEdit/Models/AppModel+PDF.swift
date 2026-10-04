import AppKit
import PDFKit
import UniformTypeIdentifiers

/// The PDF side of the app model: saving PDFs, the page commands that need a
/// panel, and reading text off scans and pictures.
extension AppModel {
    /// The PDF tools for the selected document, when it is a PDF.
    var selectedPDFEditor: PDFEditingController? {
        guard let document = selectedDocument, document.kind == .pdf else { return nil }
        return document.pdfEditing
    }

    // MARK: - Saving

    /// Writes the PDF back where it came from, with its annotations, form
    /// entries, and page changes. A file that can't be written goes to Save As.
    func savePDF(_ document: EditorDocument) {
        guard let url = document.url else {
            savePDFAs(document)
            return
        }
        writePDF(document, to: url)
    }

    func savePDFAs(_ document: EditorDocument) {
        let panel = NSSavePanel()
        panel.title = "Save"
        panel.nameFieldStringValue = document.baseName + ".pdf"
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        if let directory = (document.url ?? document.sourceURL)?.deletingLastPathComponent() {
            panel.directoryURL = directory
        }
        if panel.runModal() == .OK, let url = panel.url {
            writePDF(document, to: url)
        }
    }

    private func writePDF(_ document: EditorDocument, to url: URL) {
        guard let pdf = document.pdf else { return }
        do {
            try PDFFileWriter.write(pdf, to: url)
            document.markPDFSaved(at: url)
            objectWillChange.send()
        } catch {
            showError(title: "The PDF couldn’t be saved.", message: message(for: error))
        }
    }

    // MARK: - Pages

    /// Puts pages from other files after the page on screen. PDFs bring all
    /// their pages; a picture becomes a page of its own, fitted to the size of
    /// the page it's going in beside so the document keeps one page size.
    func insertPagesIntoPDF() {
        guard let editor = selectedPDFEditor, let document = editor.document else { return }

        let panel = NSOpenPanel()
        panel.title = "Insert Pages"
        panel.message = "Choose PDFs or pictures to insert after the current page."
        panel.prompt = "Insert"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.pdf, .image]
        guard panel.runModal() == .OK else { return }

        let fit = document.page(at: editor.currentPageIndex)?.bounds(for: .mediaBox)
            ?? NSRect(x: 0, y: 0, width: 612, height: 792)
        var pages: [PDFPage] = []
        for url in panel.urls {
            if UTType(filenameExtension: url.pathExtension)?.conforms(to: .pdf) == true {
                guard let source = PDFDocument(url: url) else {
                    showError(title: "“\(url.lastPathComponent)” couldn’t be read.", message: "It may be damaged, or not really a PDF.")
                    continue
                }
                if source.isLocked, !PDFPasswordPrompt.unlock(source, name: url.lastPathComponent) { continue }
                for index in 0 ..< source.pageCount {
                    if let page = source.page(at: index)?.copy() as? PDFPage { pages.append(page) }
                }
            } else if let image = NSImage(contentsOf: url),
                      let page = PDFPage(image: image, options: [.mediaBox: NSValue(rect: fit), .upscaleIfSmaller: false])
            {
                pages.append(page)
            } else {
                showError(title: "“\(url.lastPathComponent)” couldn’t be read.", message: "betterTextEdit can insert PDFs and pictures macOS can decode.")
            }
        }
        editor.insertPagesAfterCurrent(pages, actionName: pages.count == 1 ? "Insert Page" : "Insert Pages")
    }

    /// Writes the chosen pages — the thumbnails picked in the sidebar, or the
    /// page on screen — to a new PDF, leaving this one as it is.
    func exportPDFPages() {
        guard let source = selectedDocument, source.kind == .pdf,
              let extracted = source.pdfEditing.documentOfTargetPages()
        else { return }

        let panel = NSSavePanel()
        panel.title = "Export Pages"
        panel.prompt = "Export"
        let count = extracted.pageCount
        panel.nameFieldStringValue = "\(source.baseName) (\(count) \(count == 1 ? "page" : "pages")).pdf"
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        if let directory = (source.url ?? source.sourceURL)?.deletingLastPathComponent() {
            panel.directoryURL = directory
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try PDFFileWriter.write(extracted, to: url)
        } catch {
            showError(title: "The pages couldn’t be exported.", message: message(for: error))
        }
    }

    // MARK: - Text

    /// Lifts a PDF's text into an editable formatted document, keeping the
    /// fonts and sizes PDFKit reports — and reading the pages that are only
    /// pictures of text with Vision, so a scan comes out as words too.
    ///
    /// Recognition runs a page at a time with the source tab showing progress
    /// and a Cancel button; the new tab appears once it's done.
    func extractTextFromPDF() {
        guard let source = selectedDocument, let pdf = source.pdf else { return }
        let editor = source.pdfEditing
        guard editor.recognitionTask == nil else { return }

        // Pages, not indexes: the user can keep editing while this runs, and
        // a deleted page shouldn't leave its text attached to its neighbour.
        let scans = (0 ..< pdf.pageCount).compactMap { pdf.page(at: $0) }.filter(TextRecognizer.needsRecognition)
        guard !scans.isEmpty else {
            finishExtraction(from: source, pdf: pdf, recognized: [:])
            return
        }

        editor.recognition = .init(completed: 0, total: scans.count)
        editor.recognitionTask = Task { @MainActor [weak self, weak source] in
            var recognized: [PDFPage: NSAttributedString] = [:]
            for (done, page) in scans.enumerated() {
                guard !Task.isCancelled else { break }
                if let image = TextRecognizer.image(of: page),
                   let paragraphs = try? await TextRecognizer.paragraphs(in: image),
                   !paragraphs.isEmpty
                {
                    recognized[page] = TextRecognizer.attributedText(from: paragraphs)
                }
                editor.recognition?.completed = done + 1
            }

            let cancelled = Task.isCancelled
            editor.recognition = nil
            editor.recognitionTask = nil
            guard !cancelled, let self, let source else { return }

            var byIndex: [Int: NSAttributedString] = [:]
            for (page, text) in recognized {
                let index = pdf.index(for: page)
                if index != NSNotFound { byIndex[index] = text }
            }
            finishExtraction(from: source, pdf: pdf, recognized: byIndex)
        }
    }

    private func finishExtraction(from source: EditorDocument, pdf: PDFDocument, recognized: [Int: NSAttributedString]) {
        let attributed = DocumentImporter.extractText(from: pdf, recognized: recognized)
        guard attributed.string.contains(where: { !$0.isWhitespace && $0 != "\u{FFFC}" }) else {
            showError(
                title: "There’s no text to extract.",
                message: "betterTextEdit couldn’t find any text in this PDF, even by reading its pages as pictures."
            )
            return
        }
        add(EditorDocument.formatted(attributed, name: "\(source.baseName) Text"))
    }

    /// Reads the text in a picture — a screenshot, a photographed page, a sign —
    /// into a new formatted document.
    func recognizeTextInImage() {
        guard let source = selectedDocument, source.kind == .image,
              let picture = source.image?.frames.first?.image,
              let image = picture.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return }
        let editor = source.pdfEditing
        guard editor.recognitionTask == nil else { return }

        editor.recognition = .init(completed: 0, total: 0)
        editor.recognitionTask = Task { @MainActor [weak self] in
            let paragraphs = (try? await TextRecognizer.paragraphs(in: image)) ?? []
            let cancelled = Task.isCancelled
            editor.recognition = nil
            editor.recognitionTask = nil
            guard !cancelled, let self else { return }

            guard !paragraphs.isEmpty else {
                showError(
                    title: "There’s no text in this picture.",
                    message: "betterTextEdit couldn’t find anything to read in “\(source.displayName)”."
                )
                return
            }
            add(EditorDocument.formatted(TextRecognizer.attributedText(from: paragraphs), name: "\(source.baseName) Text"))
        }
    }
}
