import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published private(set) var documents: [EditorDocument] = []
    @Published var selectedID: UUID?

    /// True from launch until the app has settled its opening documents — either
    /// a file handed over by Finder has started loading, or the blank starter
    /// document has been created. While it's true the window shows an empty
    /// canvas rather than the "Open a file" welcome screen, so that welcome
    /// screen doesn't flash on screen for the split second before the starter
    /// document appears.
    @Published private(set) var isLaunching = true

    /// The folder the sidebar browses. Follows the first file opened, until the
    /// user picks something else.
    @Published var sidebarRoot: URL? {
        didSet { UserDefaults.standard.set(sidebarRoot?.path, forKey: Self.sidebarRootKey) }
    }

    /// Settings rides in the tab strip alongside the documents rather than
    /// opening a window of its own, the way VS Code does it — so it gets an id
    /// of the same shape as a document's.
    ///
    /// A fixed `UUID` rather than a second notion of what's selected: tab
    /// selection, closing, ⌃Tab, and the glass that slides between tabs all
    /// keep working with one `selectedID` and no special cases threaded
    /// through them.
    static let settingsTabID = UUID(uuidString: "5E771465-0000-4000-8000-5E7715650000")!

    /// Whether the Settings tab is open. It's at most one, and it's never a
    /// document, so a flag says it better than a placeholder in `documents`
    /// that every save, close, and language check would have to step around.
    @Published private(set) var isShowingSettings = false

    private static let sidebarRootKey = "sidebar.root"
    private var untitledCounter = 1

    private init() {
        if let path = UserDefaults.standard.string(forKey: Self.sidebarRootKey) {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
                sidebarRoot = URL(fileURLWithPath: path, isDirectory: true)
            }
        }
    }

    var selectedDocument: EditorDocument? {
        documents.first { $0.id == selectedID }
    }

    /// True when Settings is the tab on screen. `selectedDocument` is `nil`
    /// then, since the Settings id matches no document — which is what keeps
    /// the toolbar, the Save commands, and the status bar quiet without any of
    /// them having to know Settings exists.
    var isSettingsSelected: Bool {
        isShowingSettings && selectedID == Self.settingsTabID
    }

    /// Everything the tab strip shows, in the order it shows it.
    var tabIDs: [UUID] {
        documents.map(\.id) + (isShowingSettings ? [Self.settingsTabID] : [])
    }

    /// True when the window has anything to show at all — used to decide
    /// between the workspace and the welcome screen.
    var hasWorkspace: Bool {
        !documents.isEmpty || isShowingSettings
    }

    // MARK: - Settings

    func showSettings() {
        isLaunching = false
        isShowingSettings = true
        selectedID = Self.settingsTabID
    }

    func closeSettings() {
        isShowingSettings = false
        if selectedID == Self.settingsTabID {
            selectedID = documents.last?.id
        }
    }

    var hasUnsavedDocuments: Bool {
        documents.contains(where: \.isModified)
    }

    // MARK: - Opening

    func newDocument() {
        let suffix = untitledCounter == 1 ? "" : " \(untitledCounter)"
        untitledCounter += 1
        let document = EditorDocument(untitledName: "Untitled\(suffix)")
        add(document)
    }

    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.title = "Open"
        panel.message = "Choose a text, Markdown, source code, Word, Rich Text, or PDF file."
        panel.prompt = "Open"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = DocumentImporter.openableContentTypes

        if panel.runModal() == .OK {
            panel.urls.forEach(open)
        }
    }

    func open(_ url: URL) {
        // Opening anything settles the launch: a document is on its way in.
        isLaunching = false
        let target = url.standardizedFileURL
        if let existing = documents.first(where: { ($0.url ?? $0.sourceURL)?.standardizedFileURL == target }) {
            selectedID = existing.id
            return
        }

        guard url.isFileURL else { return }
        // The first file opened decides what the sidebar browses.
        if sidebarRoot == nil {
            sidebarRoot = url.deletingLastPathComponent()
        }

        let placeholder = EditorDocument(text: "", url: url)
        placeholder.isLoading = true
        documents.append(placeholder)
        selectedID = placeholder.id

        Task {
            do {
                let payload = try await DocumentImporter.load(url)
                guard documents.contains(where: { $0.id == placeholder.id }) else { return }
                placeholder.apply(payload, from: url)
                placeholder.isLoading = false
                // Loading is what settles a document's kind and language, and
                // the menu bar and toolbar key off both — so republish.
                objectWillChange.send()
            } catch {
                placeholder.isLoading = false
                placeholder.errorMessage = message(for: error)
            }
        }
    }

    private func add(_ document: EditorDocument) {
        isLaunching = false
        documents.append(document)
        selectedID = document.id
        objectWillChange.send()
    }

    /// Called once the launch has run its course, so the welcome screen is free
    /// to appear from then on — including the moment the last tab is closed.
    func markLaunchSettled() {
        isLaunching = false
    }

    // MARK: - Tabs

    func selectNextDocument() {
        moveSelection(by: 1)
    }

    func selectPreviousDocument() {
        moveSelection(by: -1)
    }

    /// Wraps around, the way tabs do everywhere else on the system. Settings is
    /// in the cycle because it's in the strip.
    private func moveSelection(by offset: Int) {
        let tabs = tabIDs
        guard tabs.count > 1,
              let selected = selectedID,
              let current = tabs.firstIndex(of: selected)
        else { return }
        selectedID = tabs[(current + offset + tabs.count) % tabs.count]
    }

    /// Moves one tab to where another currently sits.
    ///
    /// Phrased as "take this one's place" rather than "insert at index N"
    /// because that's what a drag actually reports: the pointer is over a tab,
    /// not between two of them. Removing before inserting means the target's
    /// index is read *after* the gap closes, which is what makes dragging left
    /// and dragging right both land where the pointer is.
    func moveDocument(_ id: UUID, toPositionOf target: UUID) {
        guard id != target,
              let from = documents.firstIndex(where: { $0.id == id }),
              let to = documents.firstIndex(where: { $0.id == target })
        else { return }

        // Both indices are read before anything moves, and then the target's
        // own index is the insertion point either way. Dragging rightwards, the
        // removal shifts `to` down by one and the tab wants to land *after* the
        // target, so the two cancel; dragging leftwards, `to` is unaffected and
        // the tab wants to land *before* it. Same number, both directions.
        let document = documents.remove(at: from)
        documents.insert(document, at: to)
    }

    func selectDocument(at index: Int) {
        guard documents.indices.contains(index) else { return }
        selectedID = documents[index].id
    }

    /// ⌘W closes the tab, and only closes the window once the last one is gone.
    func closeSelectedOrWindow() {
        if isSettingsSelected {
            closeSettings()
        } else if let document = selectedDocument {
            close(document)
        } else {
            NSApp.keyWindow?.performClose(nil)
        }
    }

    // MARK: - Sidebar

    func chooseSidebarFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose Folder"
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = sidebarRoot
        if panel.runModal() == .OK, let url = panel.url {
            sidebarRoot = url
        }
    }

    private func message(for error: Error) -> String {
        guard let recovery = (error as? LocalizedError)?.recoverySuggestion else {
            return error.localizedDescription
        }
        return error.localizedDescription + "\n\n" + recovery
    }

    // MARK: - Converting

    /// Lifts a PDF's text into an editable formatted document, keeping the
    /// fonts and sizes PDFKit reports. The result can be saved as `.docx`.
    func extractTextFromPDF() {
        guard let source = selectedDocument, let pdf = source.pdf else { return }

        let attributed = DocumentImporter.extractText(from: pdf)
        guard attributed.length > 0 else {
            showError(
                title: "There’s no text to extract.",
                message: "This PDF has no selectable text — its pages may be scanned images."
            )
            return
        }

        add(EditorDocument.formatted(attributed, name: "\(source.baseName) Text"))
    }

    /// Flattens a formatted document to Markdown in a new tab, leaving the
    /// original untouched.
    func convertToMarkdown() {
        guard let source = selectedDocument else { return }

        let attributed: NSAttributedString
        switch source.kind {
        case .rich:
            attributed = source.attributedText
        case .pdf:
            guard let pdf = source.pdf else { return }
            attributed = DocumentImporter.extractText(from: pdf)
        case .plain, .image:
            return
        }

        let markdown = RichTextMarkdown.convert(attributed)
        guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showError(
                title: "There’s nothing to convert.",
                message: "betterTextEdit found no text in this document."
            )
            return
        }

        add(EditorDocument.markdown(markdown, name: "\(source.baseName).md"))
    }

    /// Rasterises the selected SVG to a PNG, at a scale the user picks in the
    /// export panel. The current text is used, so unsaved edits are included.
    func exportSVGAsPNG() {
        guard let document = selectedDocument, document.isSVG else { return }

        let data = Data(document.text.utf8)
        guard let natural = SVGRasterizer.naturalSize(of: data) else {
            showError(
                title: "This SVG couldn’t be rendered.",
                message: "betterTextEdit couldn’t read a picture out of this file. "
                    + "Check that it’s valid SVG — it should contain an <svg> element with a size or viewBox."
            )
            return
        }

        let panel = NSSavePanel()
        panel.title = "Export as PNG"
        panel.prompt = "Export"
        panel.nameFieldStringValue = document.baseName + ".png"
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        if let directory = (document.url ?? document.sourceURL)?.deletingLastPathComponent() {
            panel.directoryURL = directory
        }

        let accessory = PNGScaleAccessory(naturalSize: natural)
        panel.accessoryView = accessory.view

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let png = try SVGRasterizer.png(from: data, pixelSize: accessory.pixelSize)
            try png.write(to: url, options: .atomic)
        } catch {
            showError(title: "The PNG couldn’t be saved.", message: message(for: error))
        }
    }

    // MARK: - Saving

    func saveSelected() {
        guard let document = selectedDocument else { return }
        guard let url = document.url else {
            saveAs(document)
            return
        }
        write(document, to: url)
    }

    func saveSelectedAs() {
        guard let document = selectedDocument else { return }
        saveAs(document)
    }

    private func saveAs(_ document: EditorDocument) {
        let panel = NSSavePanel()
        panel.title = "Save"
        panel.nameFieldStringValue = suggestedName(for: document)
        panel.canCreateDirectories = true

        if document.kind == .rich {
            if document.hasUnreadableImages {
                panel.message = "macOS couldn’t read the pictures in \(document.displayName), so they "
                    + "aren’t in this document and won’t be in the file you save. "
                    + "The original is left alone so it keeps them."
            } else if document.needsSaveAs, let format = document.importedFormat {
                panel.message = "macOS can read \(format.displayName)s but can’t write them. "
                    + "Saving creates a Word (.docx) copy — the original isn’t changed."
            }
        }

        if let directory = document.sourceURL?.deletingLastPathComponent() {
            panel.directoryURL = directory
        }

        // A format popup, so one document can go out as any of several things.
        let items = SaveFormat.items(for: document.kind)
        var accessory: SaveFormatAccessory?
        if !items.isEmpty {
            let controller = SaveFormatAccessory(
                items: items,
                initial: defaultFormat(for: document),
                panel: panel
            )
            panel.accessoryView = controller.view
            accessory = controller
        }

        if panel.runModal() == .OK, let url = panel.url {
            write(document, to: url, format: accessory?.selected ?? .automatic)
        }
    }

    private func defaultFormat(for document: EditorDocument) -> SaveFormat {
        // Plain text goes out under whatever name is typed — the suggested name
        // already carries the extension its language calls for.
        guard document.kind == .rich else { return .automatic }
        // Keep the format it arrived in when macOS can write that; otherwise
        // Word, which everything opens.
        return switch document.sourceURL?.pathExtension.lowercased() {
        case "rtf": .richText
        case "rtfd": .richTextBundle
        case "html", "htm": .webPage
        default: .word
        }
    }

    private func suggestedName(for document: EditorDocument) -> String {
        if let url = document.url {
            return url.lastPathComponent
        }
        if document.kind == .rich {
            // Keep the original extension when macOS can write it; otherwise
            // fall back to the format everything else opens.
            let original = document.sourceURL?.pathExtension.lowercased() ?? ""
            let ext = RichTextWriter.writableExtensions.contains(original) ? original : "docx"
            return document.baseName + "." + ext
        }
        return document.baseName + "." + document.language.fileExtension
    }

    private func write(_ document: EditorDocument, to url: URL, format: SaveFormat = .automatic) {
        guard document.kind == .plain || document.kind == .rich else { return }

        // What actually goes on disk: the characters, or a laid-out document.
        let attributed: NSAttributedString? = if format.needsAttributedText {
            document.kind == .rich
                ? document.attributedText
                : PDFExporter.attributedText(from: document.text, monospaced: document.language != .markdown)
        } else {
            nil
        }

        if let attributed, format != .pdf {
            let losses = RichTextWriter.losses(writing: attributed, to: url)
            if !losses.isEmpty, !document.suppressesFormatWarning {
                guard confirmLossyWrite(document, to: url, losses: losses) else { return }
            }
        }

        do {
            switch (format, attributed) {
            case let (.pdf, .some(text)):
                try PDFExporter.write(text, to: url, layout: document.pageLayout)
            case let (_, .some(text)):
                try RichTextWriter.write(
                    text,
                    to: url,
                    layout: document.pageLayout,
                    documentAttributes: document.documentAttributes
                )
            case (_, .none):
                // Plain formats: write the characters, whatever the extension.
                try characters(of: document, as: format).write(to: url, atomically: true, encoding: .utf8)
            }

            // Saving a copy in another format leaves the document pointing at
            // its original; only a like-for-like save adopts the new file.
            if adoptsFile(document: document, format: format, url: url) {
                document.markSaved(at: url)
            }
            objectWillChange.send()
        } catch {
            showError(title: "The file couldn’t be saved.", message: message(for: error))
        }
    }

    /// The characters to write for a format that carries no formatting.
    ///
    /// Flattening a formatted document to Markdown is worth doing properly —
    /// its headings, bold, lists, and links all have Markdown spellings, and
    /// `attributedText.string` would throw every one of them away.
    private func characters(of document: EditorDocument, as format: SaveFormat) -> String {
        guard document.kind == .rich else { return document.text }
        if case let .text(text) = format, text.language == .markdown {
            return RichTextMarkdown.convert(document.attributedText)
        }
        return document.attributedText.string
    }

    /// True when the file just written is the document itself rather than an
    /// export of it — a PDF or a flattened copy shouldn't steal the tab.
    private func adoptsFile(document: EditorDocument, format: SaveFormat, url: URL) -> Bool {
        switch document.kind {
        // Text stays text whatever extension it goes out under, so the tab
        // follows it — the file just written is the document.
        case .plain: format.isPlainCharacters
        // A formatted document only follows a format that kept its formatting.
        case .rich: !format.isPlainCharacters && format != .pdf
        default: false
        }
    }

    /// Asks before a save simplifies a document, and offers the format that
    /// wouldn't. Returns `true` when the caller should go ahead with the write.
    private func confirmLossyWrite(_ document: EditorDocument, to url: URL, losses: [String]) -> Bool {
        let format = url.pathExtension.uppercased()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Saving as \(format) will simplify “\(url.lastPathComponent)”."
        alert.informativeText = "macOS can’t write \(list(losses)) into a \(format) file. "
            + "Rich Text keeps everything, and Word, Pages, and Google Docs all open Rich Text files."
        alert.addButton(withTitle: "Save as Rich Text…")
        alert.addButton(withTitle: "Save as \(format) Anyway")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don’t ask again for this document"

        let response = alert.runModal()
        if alert.suppressionButton?.state == .on {
            document.suppressesFormatWarning = true
        }

        switch response {
        case .alertFirstButtonReturn:
            saveAsRichText(document)
            return false
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }

    private func saveAsRichText(_ document: EditorDocument) {
        let panel = NSSavePanel()
        panel.title = "Save as Rich Text"
        panel.nameFieldStringValue = document.baseName + ".rtf"
        panel.allowedContentTypes = [.rtf]
        panel.canCreateDirectories = true
        if let directory = (document.url ?? document.sourceURL)?.deletingLastPathComponent() {
            panel.directoryURL = directory
        }
        if panel.runModal() == .OK, let url = panel.url {
            write(document, to: url)
        }
    }

    private func list(_ items: [String]) -> String {
        switch items.count {
        case 0: ""
        case 1: items[0]
        case 2: "\(items[0]) or \(items[1])"
        default: items.dropLast().joined(separator: ", ") + ", or " + (items.last ?? "")
        }
    }

    // MARK: - Closing

    func close(_ document: EditorDocument) {
        if document.isModified {
            let alert = NSAlert()
            alert.messageText = "Do you want to save the changes you made to “\(document.displayName)”?"
            alert.informativeText = "Your changes will be lost if you don’t save them."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Don’t Save")
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                let previousSelection = selectedID
                selectedID = document.id
                saveSelected()
                selectedID = previousSelection
                if document.isModified { return }
            } else if response != .alertThirdButtonReturn {
                return
            }
        }

        guard let index = documents.firstIndex(where: { $0.id == document.id }) else { return }
        documents.remove(at: index)
        if selectedID == document.id {
            selectedID = documents.indices.contains(index) ? documents[index].id : documents.last?.id
            // Closing the last document with Settings open lands there rather
            // than on nothing, since Settings is still a tab in the strip.
            if selectedID == nil, isShowingSettings {
                selectedID = Self.settingsTabID
            }
        }
    }

    // MARK: - Actions

    func formatSelectedJSON() {
        guard let document = selectedDocument else { return }
        do {
            let data = Data(document.text.utf8)
            let value = try JSONSerialization.jsonObject(with: data)
            let formatted = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            document.text = String(decoding: formatted, as: UTF8.self) + "\n"
        } catch {
            showError(title: "The JSON couldn’t be formatted.", message: error.localizedDescription)
        }
    }

    func revealInFinder(_ document: EditorDocument) {
        guard let url = document.url ?? document.sourceURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func showError(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}
