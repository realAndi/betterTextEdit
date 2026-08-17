import AppKit
import Foundation
import PDFKit

@MainActor
final class EditorDocument: ObservableObject, Identifiable {
    /// What kind of thing this document holds, which decides which editor it
    /// gets and how it is saved.
    enum Kind {
        /// Text or source code, edited as characters.
        case plain
        /// A word-processor document, edited with its formatting intact.
        case rich
        /// A PDF, shown as a PDF.
        case pdf
        /// A picture, shown as a picture.
        case image
    }

    enum PreviewMode: String, CaseIterable, Identifiable {
        case source
        case split
        case preview

        var id: String { rawValue }

        var label: String {
            switch self {
            case .source: "Source"
            case .split: "Split"
            case .preview: "Preview"
            }
        }

        var symbol: String {
            switch self {
            case .source: "chevron.left.forwardslash.chevron.right"
            case .split: "rectangle.split.2x1"
            case .preview: "doc.richtext"
            }
        }
    }

    let id = UUID()
    @Published private(set) var kind: Kind = .plain
    @Published var text: String { didSet { scheduleDetection() } }
    @Published var previewMode: PreviewMode = .split
    @Published var cursorLine = 1
    @Published var cursorColumn = 1
    @Published var isLoading = false
    @Published var errorMessage: String?

    /// The live storage behind a formatted document. The text view edits this
    /// object directly, which is what keeps fonts, colours, spacing, lists, and
    /// tables intact through an edit-and-save round trip.
    let storage = NSTextStorage()

    /// Tracks edits to `storage`, which — unlike a `String` — can't be compared
    /// against a saved copy cheaply.
    @Published private(set) var richIsEdited = false

    /// Formatting state for the toolbar and the Format menu.
    let formatting = RichTextController()

    /// Set once the user has been told what a lossy save format will drop and
    /// has chosen to keep going.
    var suppressesFormatWarning = false

    /// The file this came from has embedded images macOS can't write back out.
    private(set) var hasUnreadableImages = false

    /// How many of those images betterTextEdit recovered from the package to show.
    private(set) var displayedImageCount = 0

    /// What to tell the user about this document's pictures, if anything.
    var imageNote: String? {
        guard hasUnreadableImages else { return nil }
        return displayedImageCount > 0 ? "Images won’t be saved" : "Images not shown"
    }

    private(set) var pdf: PDFDocument?
    private(set) var image: ImageDocument?
    private(set) var pageLayout = PageLayout()
    private(set) var documentAttributes: [NSAttributedString.DocumentAttributeKey: Any] = [:]

    /// Where Save writes. `nil` until the document has a home on disk it can
    /// actually be written to.
    var url: URL?

    /// The file this document was read from, whatever its format.
    private(set) var sourceURL: URL?

    private(set) var importedFormat: DocumentImporter.Format?
    private var languageOverride: FileLanguage?
    private(set) var persistedText: String
    private(set) var untitledName: String

    /// A language the user picked by hand, which beats both the file name and
    /// anything detection makes of the contents.
    @Published private(set) var chosenLanguage: FileLanguage?

    /// What the contents look like, for text with no filename to go on. Kept
    /// up to date a beat behind the typing rather than on the keystroke, so
    /// reading a document costs nothing while it's being written.
    @Published private(set) var detectedLanguage: FileLanguage = .plainText
    private var detectionTask: Task<Void, Never>?

    init(text: String = "", url: URL? = nil, untitledName: String = "Untitled") {
        self.text = text
        persistedText = text
        self.url = url
        sourceURL = url
        self.untitledName = untitledName
        // A document nobody has opened yet starts as source. Detection can turn
        // an untitled buffer into Markdown mid-sentence, and splitting the
        // window out from under the cursor would be rude — the preview is a
        // click away in the toolbar once it's available.
        previewMode = .source
    }

    /// Creates a formatted document that hasn't been saved anywhere yet — the
    /// result of extracting a PDF's text, for example.
    static func formatted(
        _ attributed: NSAttributedString,
        name: String,
        layout: PageLayout = PageLayout()
    ) -> EditorDocument {
        let document = EditorDocument(untitledName: name)
        document.kind = .rich
        document.languageOverride = .richText
        document.pageLayout = layout
        document.storage.setAttributedString(attributed)
        document.richIsEdited = true
        return document
    }

    /// Creates an unsaved Markdown document — what converting a formatted
    /// document or a PDF produces.
    static func markdown(_ text: String, name: String) -> EditorDocument {
        let document = EditorDocument(text: text, untitledName: name)
        document.languageOverride = .markdown
        document.previewMode = .split
        document.persistedText = ""
        return document
    }

    var displayName: String {
        (url ?? sourceURL)?.lastPathComponent ?? untitledName
    }

    /// The name to suggest in the Save panel, without an extension.
    var baseName: String {
        (url ?? sourceURL)?.deletingPathExtension().lastPathComponent ?? untitledName
    }

    var pathLabel: String {
        (url ?? sourceURL)?.deletingLastPathComponent().path(percentEncoded: false) ?? "Unsaved document"
    }

    /// What this document is, in order of how much the answer can be trusted:
    /// what the user said, what kind of file it is, what its name says, and —
    /// for anything still unaccounted for — what's actually written in it.
    var language: FileLanguage {
        if let chosenLanguage { return chosenLanguage }
        if let languageOverride { return languageOverride }
        if let url = url ?? sourceURL, let named = FileLanguage.known(for: url) { return named }
        return kind == .plain ? detectedLanguage : .plainText
    }

    /// True when nothing but the contents decided the language — the case the
    /// status bar labels as automatic.
    var languageWasDetected: Bool {
        guard chosenLanguage == nil, languageOverride == nil, kind == .plain else { return false }
        guard let url = url ?? sourceURL else { return true }
        return FileLanguage.known(for: url) == nil
    }

    /// Re-reads the contents shortly after the typing stops.
    ///
    /// A beat's delay is what keeps this off the keystroke path — and it also
    /// keeps the editor from changing its mind about a file halfway through the
    /// line that decides it.
    private func scheduleDetection() {
        guard languageWasDetected else { return }
        detectionTask?.cancel()
        detectionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.detectNow()
        }
    }

    /// Re-reads the contents straight away — for a file that has just been
    /// opened, where waiting would mean a visible beat of unhighlighted text.
    private func detectNow() {
        detectionTask?.cancel()
        let found = LanguageDetector.detect(in: text) ?? .plainText
        guard found != detectedLanguage else { return }
        detectedLanguage = found
        objectWillChange.send()
    }

    /// Sets the language by hand, or hands it back to detection with `nil`.
    func setLanguage(_ language: FileLanguage?) {
        chosenLanguage = language
        if language == nil {
            // Nothing has been watching the contents while a hand-picked
            // language was in force, so catch up before answering.
            if languageWasDetected { detectNow() }
        } else if supportsPreview, previewMode == .source {
            // Asking for Markdown or HTML by name is as good as asking to see
            // it rendered.
            previewMode = .split
        }
        objectWillChange.send()
    }

    var isModified: Bool {
        switch kind {
        case .plain: text != persistedText
        case .rich: richIsEdited
        case .pdf, .image: false
        }
    }

    /// The kinds of source worth rendering as well as editing, and the renderer
    /// each one gets. `nil` for everything else — plain text, code, JSON — which
    /// is only ever edited, never previewed.
    enum PreviewKind {
        case markdown
        case html
        case svg
    }

    /// Which preview this document supports, if any. Language is checked before
    /// the SVG content sniff, so a Markdown or HTML file that merely *contains*
    /// an `<svg>` tag still previews as Markdown or HTML.
    var previewKind: PreviewKind? {
        guard kind == .plain else { return nil }
        if language == .html { return .html }
        if language == .markdown { return .markdown }
        if isSVG { return .svg }
        return nil
    }

    /// Source that's worth seeing rendered as well as edited.
    var supportsPreview: Bool {
        previewKind != nil
    }

    /// True when this text is an SVG — so it can be rasterised to PNG. Recognised
    /// by name for a file, and by a leading `<svg` for anything untitled or
    /// oddly named.
    var isSVG: Bool {
        guard kind == .plain else { return false }
        if (url ?? sourceURL)?.pathExtension.lowercased() == "svg" { return true }
        return text.prefix(1024).range(of: "<svg", options: .caseInsensitive) != nil
    }

    /// The folder a preview resolves its relative links, images, and scripts
    /// against. `nil` for a document that has never been saved.
    var resourceDirectory: URL? {
        (url ?? sourceURL)?.deletingLastPathComponent()
    }

    /// True when the file this came from can't be written back — either because
    /// macOS has no writer for it, or because it's a PDF.
    var needsSaveAs: Bool {
        url == nil
    }

    var attributedText: NSAttributedString {
        storage
    }

    // MARK: - Loading

    func apply(_ payload: DocumentImporter.Payload, from source: URL) {
        sourceURL = source
        importedFormat = payload.format
        documentAttributes = payload.documentAttributes
        pageLayout = payload.layout

        switch payload.content {
        case let .plain(text):
            kind = .plain
            self.text = text
            persistedText = text
            languageOverride = nil
            url = source
            // A `.conf`, a `.zshrc`, or anything else the name doesn't explain
            // is read now rather than a beat later, so the file arrives already
            // highlighted.
            if languageWasDetected { detectNow() }
            if supportsPreview { previewMode = .split }

        case let .rich(attributed):
            kind = .rich
            languageOverride = .richText
            storage.setAttributedString(attributed)
            richIsEdited = false
            hasUnreadableImages = payload.hasUnreadableImages
            displayedImageCount = payload.displayedImageCount
            // Formats macOS can write are saved straight back where they came
            // from; the read-only ones start unsaved so Save can't clobber them.
            // A file whose images macOS couldn't read is treated as read-only
            // too — saving over it would delete pictures we never even saw.
            url = RichTextWriter.canWrite(source) && !hasUnreadableImages ? source : nil

        case let .pdf(document):
            kind = .pdf
            languageOverride = .pdf
            pdf = document
            url = nil

        case let .image(document):
            kind = .image
            languageOverride = .image
            image = document
            url = nil
        }

        objectWillChange.send()
    }

    // MARK: - Editing

    func markRichEdited() {
        guard !richIsEdited else { return }
        richIsEdited = true
    }

    func markSaved(at url: URL) {
        self.url = url
        sourceURL = sourceURL ?? url
        persistedText = text
        richIsEdited = false
        if kind == .plain {
            // Once the text has a real home, the file on disk defines the language.
            languageOverride = nil
            // A saved-as `.py` is Python whatever the picker last said, and a
            // name that means nothing leaves the hand-picked answer standing.
            if FileLanguage.known(for: url) != nil { chosenLanguage = nil }
            importedFormat = .plainText
        } else if kind == .rich {
            // After a Save As, the document's format is whatever it was just
            // written as — not what it was originally opened from.
            importedFormat = DocumentImporter.format(for: url)
        }
        objectWillChange.send()
    }
}
