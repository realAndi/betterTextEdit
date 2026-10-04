import AppKit
import PDFKit

// MARK: - The editing controller

/// Everything that can happen to an open PDF: its pages rotated, deleted,
/// reordered, or brought in from another file; its text highlighted, underlined,
/// struck through, or annotated with a note; its form filled in; and its text
/// searched.
///
/// The controller makes the `PDFView`s that show the document and keeps track
/// of them. Usually there's one; but a window restored at launch beside the one
/// opened for a file shows the same tabs, so there can be two at once, and a
/// single shared view could only ever be in one of them. Commands act on the
/// view in the key window.
///
/// It also remembers where the reader was. A tab switch tears the SwiftUI view
/// down and builds a new one, and a PDFKit view built afresh opens at page one
/// — so a forty-page document read to page thirty would be back at the start
/// every time the user glanced at another tab.
///
/// Every change is made through here, which is what lets each one register its
/// own undo and mark the document edited in the same breath.
@MainActor
final class PDFEditingController: NSObject, ObservableObject {
    enum Markup {
        case highlight
        case underline
        case strikeOut

        var title: String {
            switch self {
            case .highlight: "Highlight"
            case .underline: "Underline"
            case .strikeOut: "Strikethrough"
            }
        }

        fileprivate var subtype: PDFAnnotationSubtype {
            switch self {
            case .highlight: .highlight
            case .underline: .underline
            case .strikeOut: .strikeOut
            }
        }

        /// The colours Preview uses, so markup made here looks like markup made
        /// anywhere else on the Mac.
        fileprivate var color: NSColor {
            switch self {
            case .highlight: NSColor(srgbRed: 1, green: 0.86, blue: 0.2, alpha: 1)
            case .underline, .strikeOut: NSColor(srgbRed: 0.9, green: 0.1, blue: 0.1, alpha: 1)
            }
        }
    }

    /// Progress through a text-recognition pass. `total` of zero means there's
    /// no meaningful count — a single image — so the bar spins instead.
    struct Recognition: Equatable {
        var completed: Int
        var total: Int
    }

    @Published private(set) var pageCount = 0
    @Published private(set) var currentPageIndex = 0
    @Published private(set) var hasTextSelection = false
    @Published private(set) var findMatches: [PDFSelection] = []
    @Published private(set) var findIndex: Int?

    /// Bumped whenever what the pages look like changes — rotated, added,
    /// removed, moved, or marked up — so the thumbnails redraw.
    @Published private(set) var pageLayoutRevision = 0

    /// Pages picked in the thumbnail strip, which the page commands act on in
    /// place of the page on screen. Pages rather than indexes, so a selection
    /// means the same pages after others are added or removed around it.
    @Published var selectedPages: Set<PDFPage> = []

    /// The last thumbnail clicked without ⇧, which a ⇧-click extends from.
    var selectionAnchor: PDFPage?

    private let thumbnails: NSCache<PDFPage, NSImage> = {
        let cache = NSCache<PDFPage, NSImage>()
        cache.countLimit = 150
        return cache
    }()

    /// Set while text recognition is running for this document — a scanned
    /// PDF's pages, or an image's pixels — so the viewer can say so.
    @Published var recognition: Recognition?
    var recognitionTask: Task<Void, Never>?

    /// One history per document. The window's own undo manager is shared by
    /// every tab, so undoing there after switching from a PDF to a text file
    /// would reach back into the wrong document.
    let undoManager = UndoManager()

    private(set) var document: PDFDocument?
    private var onEdit: () -> Void = {}

    /// Every view showing this document, held weakly: a view belongs to the
    /// SwiftUI viewer that asked for it, and goes when that does.
    private let views = NSHashTable<EditablePDFView>.weakObjects()
    private weak var lastShownView: EditablePDFView?
    private var isWatchingText = false

    /// Where the reader was, so a view made for this document after a tab
    /// switch opens there rather than at page one.
    private var readingPosition: PDFDestination?

    var isAttached: Bool { document != nil }

    /// The view commands act on: the one in the key window, or else whichever
    /// was shown most recently.
    var activeView: EditablePDFView? {
        let all = views.allObjects
        let onScreen = all.filter { $0.window != nil }
        if let key = onScreen.first(where: { $0.window?.isKeyWindow == true }) { return key }
        if let last = lastShownView, last.window != nil { return last }
        return onScreen.last ?? lastShownView ?? all.last
    }

    /// Connects the controller to the document it edits, and to whatever should
    /// hear about a change — the `EditorDocument`'s unsaved state.
    func attach(_ document: PDFDocument, onEdit: @escaping () -> Void) {
        self.document = document
        self.onEdit = onEdit
        pageCount = document.pageCount
        currentPageIndex = 0
        readingPosition = nil
        for view in views.allObjects {
            view.document = document
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Views

    /// A new view onto the document, for one viewer to show.
    func makeView() -> EditablePDFView {
        let view = EditablePDFView()
        view.editor = self
        view.document = document
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
        view.autoScales = true
        view.backgroundColor = .underPageBackgroundColor
        return view
    }

    /// A view has gone on screen: listen to it, let commands reach it, and
    /// open it where the reader last was.
    func register(_ view: EditablePDFView) {
        lastShownView = view
        guard !views.contains(view) else { return }

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(pageChanged), name: .PDFViewPageChanged, object: view)
        center.addObserver(self, selector: #selector(selectionChanged), name: .PDFViewSelectionChanged, object: view)
        center.addObserver(self, selector: #selector(annotationHit), name: .PDFViewAnnotationHit, object: view)

        if !isWatchingText {
            // Typing into a form field happens in an editor PDFKit puts inside
            // the view, which tells nobody but the text system. Those
            // notifications come from every text field in the app, so each one
            // is checked for whether it's actually inside one of these views.
            center.addObserver(self, selector: #selector(textChanged), name: NSControl.textDidChangeNotification, object: nil)
            center.addObserver(self, selector: #selector(textChanged), name: NSText.didChangeNotification, object: nil)
            isWatchingText = true
        }

        views.add(view)
        if let position = readingPosition {
            // After the first layout, or PDFKit has nowhere to scroll to yet.
            DispatchQueue.main.async { [weak view] in view?.go(to: position) }
        }
    }

    /// The view is coming off screen: remember where it was, and stop
    /// listening to it.
    func retire(_ view: EditablePDFView) {
        if let position = view.currentDestination, view.document === document {
            readingPosition = position
        }
        let center = NotificationCenter.default
        center.removeObserver(self, name: .PDFViewPageChanged, object: view)
        center.removeObserver(self, name: .PDFViewSelectionChanged, object: view)
        center.removeObserver(self, name: .PDFViewAnnotationHit, object: view)
        views.remove(view)
    }

    @objc private func pageChanged(_ note: Notification? = nil) {
        guard let document, let view = activeView else { return }
        if let source = note?.object as? EditablePDFView, source !== view { return }
        guard let page = view.currentPage else { return }
        let index = document.index(for: page)
        if index != NSNotFound, index != currentPageIndex { currentPageIndex = index }
        readingPosition = view.currentDestination
    }

    @objc private func selectionChanged(_ note: Notification) {
        guard let view = note.object as? EditablePDFView, view === activeView else { return }
        let selected = !(view.currentSelection?.string ?? "").isEmpty
        if selected != hasTextSelection { hasTextSelection = selected }
    }

    @objc private func textChanged(_ note: Notification) {
        guard let editor = note.object as? NSView else { return }
        // A field editor isn't inside the view itself — it's lent to whichever
        // control is being edited, and that control is.
        let owner = (editor as? NSTextView)?.delegate as? NSView
        let isInside = views.allObjects.contains { view in
            editor.isDescendant(of: view) || owner?.isDescendant(of: view) == true
        }
        if isInside { changed() }
    }

    /// A click on a form field. Check boxes and radio buttons change on the
    /// click itself, and choosing from a pop-up list never types anything, so
    /// those count as edits here; a text field waits until something is typed.
    @objc private func annotationHit(_ note: Notification) {
        guard let annotation = note.userInfo?["PDFAnnotationHit"] as? PDFAnnotation,
              annotation.type == "Widget"
        else { return }
        switch annotation.widgetFieldType {
        case .button where annotation.widgetControlType != .pushButtonControl:
            changed()
        case .choice:
            changed()
        default:
            break
        }
    }

    /// The one place a change is announced, so the page count, the find
    /// results, and the unsaved dot can't fall out of step with the document.
    private func changed() {
        let count = document?.pageCount ?? 0
        if count != pageCount { pageCount = count }
        pageChanged()
        onEdit()
    }

    // MARK: - Pages

    /// What a page command applies to: the thumbnails picked in the sidebar,
    /// or else the page on screen.
    var targetPages: [PDFPage] {
        guard let document else { return [] }
        let selected = selectedPages.filter { document.index(for: $0) != NSNotFound }
        if !selected.isEmpty {
            return selected.sorted { document.index(for: $0) < document.index(for: $1) }
        }
        return activeView?.currentPage.map { [$0] } ?? document.page(at: 0).map { [$0] } ?? []
    }

    /// A click on a thumbnail: on its own it picks that page and goes there;
    /// ⌘ adds or removes it; ⇧ takes in every page back to the last one
    /// clicked.
    func selectThumbnail(_ page: PDFPage, extending: Bool, toggling: Bool) {
        guard let document else { return }
        if toggling {
            if selectedPages.contains(page) { selectedPages.remove(page) } else { selectedPages.insert(page) }
            selectionAnchor = page
        } else if extending, let anchor = selectionAnchor, document.index(for: anchor) != NSNotFound {
            let ends = [document.index(for: anchor), document.index(for: page)].sorted()
            selectedPages = Set((ends[0] ... ends[1]).compactMap { document.page(at: $0) })
        } else {
            selectedPages = [page]
            selectionAnchor = page
        }
        activeView?.go(to: page)
    }

    func clearPageSelection() {
        if !selectedPages.isEmpty { selectedPages = [] }
        selectionAnchor = nil
    }

    /// A page as a small picture, with its rotation and markup. Drawn by
    /// `PDFPage` itself — `PDFThumbnailView` would be the obvious choice, but
    /// measured on macOS 26 it ignores a page's rotation entirely, even one set
    /// before the strip was made, so a page turned sideways would stay upright
    /// in the sidebar forever.
    func thumbnail(for page: PDFPage, size: CGSize) -> NSImage {
        if let cached = thumbnails.object(forKey: page), cached.size == size { return cached }
        let image = page.thumbnail(of: size, for: .cropBox)
        thumbnails.setObject(image, forKey: page)
        return image
    }

    /// Drags a page to where another one is, from the thumbnail strip.
    func movePage(_ page: PDFPage, toPositionOf target: PDFPage) {
        guard let document else { return }
        let from = document.index(for: page)
        let to = document.index(for: target)
        guard from != NSNotFound, to != NSNotFound, from != to else { return }
        movePage(from: from, to: to)
    }

    var canDeleteTargetPages: Bool {
        let count = targetPages.count
        return count > 0 && count < pageCount
    }

    func rotateTargetPages(by degrees: Int) {
        rotate(targetPages, by: degrees)
    }

    private func rotate(_ pages: [PDFPage], by degrees: Int) {
        guard !pages.isEmpty else { return }
        for page in pages {
            page.rotation = ((page.rotation + degrees) % 360 + 360) % 360
        }
        undoManager.registerUndo(withTarget: self) { $0.rotate(pages, by: -degrees) }
        undoManager.setActionName(degrees < 0 ? "Rotate Left" : "Rotate Right")
        refreshLayout()
        changed()
    }

    /// Deletes the target pages — never all of them, since a PDF with no pages
    /// isn't one any reader will open.
    func deleteTargetPages() {
        guard let document, canDeleteTargetPages else {
            NSSound.beep()
            return
        }
        let indexed = targetPages.map { (document.index(for: $0), $0) }
        removePages(indexed, actionName: indexed.count == 1 ? "Delete Page" : "Delete Pages")
    }

    /// Puts pages in, each at the index it's paired with. Ascending order is
    /// what makes this the exact inverse of `removePages`.
    func insertPages(_ indexed: [(Int, PDFPage)], actionName: String) {
        guard let document, !indexed.isEmpty else { return }
        let ordered = indexed.sorted { $0.0 < $1.0 }
        for (index, page) in ordered {
            document.insert(page, at: min(max(index, 0), document.pageCount))
        }
        undoManager.registerUndo(withTarget: self) { $0.removePages(ordered, actionName: actionName) }
        undoManager.setActionName(actionName)
        clearFind()
        refreshLayout()
        if let first = ordered.first?.1 { activeView?.go(to: first) }
        changed()
    }

    /// Pages from elsewhere, placed after the page on screen.
    func insertPagesAfterCurrent(_ pages: [PDFPage], actionName: String = "Insert Pages") {
        guard isAttached, !pages.isEmpty else { return }
        let start = pageCount == 0 ? 0 : currentPageIndex + 1
        insertPages(pages.enumerated().map { (start + $0.offset, $0.element) }, actionName: actionName)
    }

    private func removePages(_ indexed: [(Int, PDFPage)], actionName: String) {
        guard let document else { return }
        let ordered = indexed.sorted { $0.0 < $1.0 }
        // From the back, so each index still means what it did.
        for (index, _) in ordered.reversed() where index < document.pageCount {
            document.removePage(at: index)
        }
        undoManager.registerUndo(withTarget: self) { $0.insertPages(ordered, actionName: actionName) }
        undoManager.setActionName(actionName)
        clearFind()
        refreshLayout()
        changed()
    }

    var canMoveCurrentPageUp: Bool { isAttached && currentPageIndex > 0 }
    var canMoveCurrentPageDown: Bool { isAttached && currentPageIndex < pageCount - 1 }

    func moveCurrentPage(by offset: Int) {
        let from = currentPageIndex
        let to = from + offset
        guard isAttached, (0 ..< pageCount).contains(to) else { return }
        movePage(from: from, to: to)
    }

    /// Takes a page out and puts it back elsewhere.
    ///
    /// Not `exchangePage(at:withPageAt:)`: measured on macOS 26, PDFKit's
    /// exchange throws an Objective-C exception — taking the app with it — once
    /// pages from another document have been inserted. Removing a page and
    /// inserting the same object again is the path undoing a delete already
    /// relies on, and it holds.
    private func movePage(from: Int, to: Int) {
        guard let document, let page = document.page(at: from) else { return }
        document.removePage(at: from)
        document.insert(page, at: min(to, document.pageCount))
        undoManager.registerUndo(withTarget: self) { $0.movePage(from: to, to: from) }
        undoManager.setActionName("Move Page")
        clearFind()
        refreshLayout()
        activeView?.go(to: page)
        changed()
    }

    /// The target pages as a document of their own, for Export Pages.
    func documentOfTargetPages() -> PDFDocument? {
        let pages = targetPages
        guard !pages.isEmpty else { return nil }
        let extracted = PDFDocument()
        for (index, page) in pages.enumerated() {
            guard let copy = page.copy() as? PDFPage else { continue }
            extracted.insert(copy, at: index)
        }
        return extracted.pageCount > 0 ? extracted : nil
    }

    func go(toPage index: Int) {
        guard let document, let page = document.page(at: min(max(index, 0), document.pageCount - 1)) else { return }
        activeView?.go(to: page)
    }

    /// Follows a table-of-contents entry — unless the page it names has since
    /// been deleted.
    func go(to destination: PDFDestination) {
        guard let document, let page = destination.page, document.index(for: page) != NSNotFound else {
            NSSound.beep()
            return
        }
        activeView?.go(to: destination)
    }

    /// Rotating, adding, or removing pages changes the geometry PDFKit has
    /// already laid out, and neither the view nor the thumbnails notice on
    /// their own.
    private func refreshLayout() {
        for view in views.allObjects {
            view.layoutDocumentView()
            view.needsDisplay = true
        }
        redrawThumbnails()
    }

    private func redrawThumbnails() {
        thumbnails.removeAllObjects()
        if let document {
            let remaining = selectedPages.filter { document.index(for: $0) != NSNotFound }
            if remaining != selectedPages { selectedPages = remaining }
        }
        pageLayoutRevision += 1
    }

    // MARK: - Markup

    func addMarkup(_ kind: Markup) {
        guard let selection = activeView?.currentSelection else { return }

        var added: [(PDFPage, PDFAnnotation)] = []
        for line in selection.selectionsByLine() {
            for page in line.pages {
                let bounds = line.bounds(for: page)
                guard bounds.width > 0.5, bounds.height > 0.5 else { continue }

                let annotation = PDFAnnotation(bounds: bounds, forType: kind.subtype, withProperties: nil)
                annotation.color = kind.color
                // QuadPoints are what the spec says a reader should draw from —
                // Acrobat ignores a highlight without them — and PDFKit wants
                // them relative to the annotation's own origin. The order is
                // top-left, top-right, bottom-left, bottom-right, which is
                // what every shipping reader expects despite the spec's prose.
                annotation.quadrilateralPoints = [
                    NSValue(point: NSPoint(x: 0, y: bounds.height)),
                    NSValue(point: NSPoint(x: bounds.width, y: bounds.height)),
                    NSValue(point: NSPoint(x: 0, y: 0)),
                    NSValue(point: NSPoint(x: bounds.width, y: 0)),
                ]
                stamp(annotation)
                added.append((page, annotation))
            }
        }
        guard !added.isEmpty else { return }
        addAnnotations(added, actionName: kind.title)
        activeView?.clearSelection()
    }

    /// Markup and notes that touch the selection. Links and form fields are
    /// part of the document's structure, not something the reader added, so
    /// they're left alone.
    func removeMarkupInSelection() {
        guard let selection = activeView?.currentSelection else { return }

        var removed: [(PDFPage, PDFAnnotation)] = []
        for page in selection.pages {
            let area = selection.bounds(for: page)
            for annotation in page.annotations
                where Self.removableTypes.contains(annotation.type ?? "") && annotation.bounds.intersects(area)
            {
                removed.append((page, annotation))
                if let popup = annotation.popup, popup.page === page { removed.append((page, popup)) }
            }
        }
        guard !removed.isEmpty else {
            NSSound.beep()
            return
        }
        removeAnnotations(removed, actionName: "Remove Markup")
    }

    private static let removableTypes: Set<String> = [
        "Highlight", "Underline", "StrikeOut", "Squiggly", "Text", "FreeText", "Ink",
    ]

    /// Adds a note beside the selection, or in the middle of what's on screen.
    func addNote() {
        guard let view = activeView, let target = notePlacement(in: view) else { return }
        guard case let .save(text) = NotePrompt.run(title: "Add Note", text: "", canDelete: false),
              !text.isEmpty
        else { return }

        let size: CGFloat = 22
        let pageBounds = target.page.bounds(for: .cropBox)
        let origin = NSPoint(
            x: min(max(target.point.x, pageBounds.minX), pageBounds.maxX - size),
            y: min(max(target.point.y - size, pageBounds.minY), pageBounds.maxY - size)
        )
        let note = PDFAnnotation(bounds: NSRect(origin: origin, size: NSSize(width: size, height: size)), forType: .text, withProperties: nil)
        note.contents = text
        note.iconType = .note
        note.color = Markup.highlight.color
        stamp(note)
        addAnnotations([(target.page, note)], actionName: "Add Note")
    }

    private func notePlacement(in view: PDFView) -> (page: PDFPage, point: NSPoint)? {
        if let selection = view.currentSelection, let page = selection.pages.first, !(selection.string ?? "").isEmpty {
            let bounds = selection.bounds(for: page)
            return (page, NSPoint(x: bounds.maxX + 4, y: bounds.maxY))
        }
        let centre = NSPoint(x: view.bounds.midX, y: view.bounds.midY)
        guard let page = view.page(for: centre, nearest: true) else { return nil }
        return (page, view.convert(centre, to: page))
    }

    /// A click on a note opens it: read, change, or delete.
    func openNote(_ note: PDFAnnotation) {
        guard let page = note.page else { return }
        switch NotePrompt.run(title: "Note", text: note.contents ?? "", canDelete: true) {
        case let .save(text):
            setContents(of: note, to: text)
        case .delete:
            var removed = [(page, note)]
            if let popup = note.popup, popup.page === page { removed.append((page, popup)) }
            removeAnnotations(removed, actionName: "Delete Note")
        case .cancel:
            break
        }
    }

    private func setContents(of note: PDFAnnotation, to text: String) {
        let previous = note.contents ?? ""
        guard previous != text else { return }
        note.contents = text
        note.modificationDate = Date()
        undoManager.registerUndo(withTarget: self) { $0.setContents(of: note, to: previous) }
        undoManager.setActionName("Edit Note")
        changed()
    }

    private func addAnnotations(_ items: [(PDFPage, PDFAnnotation)], actionName: String) {
        for (page, annotation) in items {
            page.addAnnotation(annotation)
        }
        undoManager.registerUndo(withTarget: self) { $0.removeAnnotations(items, actionName: actionName) }
        undoManager.setActionName(actionName)
        redrawThumbnails()
        changed()
    }

    private func removeAnnotations(_ items: [(PDFPage, PDFAnnotation)], actionName: String) {
        for (page, annotation) in items {
            page.removeAnnotation(annotation)
        }
        undoManager.registerUndo(withTarget: self) { $0.addAnnotations(items, actionName: actionName) }
        undoManager.setActionName(actionName)
        redrawThumbnails()
        changed()
    }

    /// Who made it and when — what Acrobat and Preview show in a comment list.
    private func stamp(_ annotation: PDFAnnotation) {
        annotation.userName = NSFullUserName()
        annotation.modificationDate = Date()
    }

    // MARK: - Find

    /// Finds every match at once, so all of them can be lit up and counted.
    func find(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let document, !trimmed.isEmpty else {
            clearFind()
            return
        }

        let matches = document.findString(trimmed, withOptions: [.caseInsensitive, .diacriticInsensitive])
        for match in matches {
            match.color = .findHighlightColor
        }
        findMatches = matches
        findIndex = nil
        for view in views.allObjects {
            view.highlightedSelections = matches.isEmpty ? nil : matches
        }
        if !matches.isEmpty { stepFind(forward: true) }
    }

    /// Moves to the next or previous match. The first step goes to the first
    /// match on or after the page being read rather than back to page one.
    func stepFind(forward: Bool) {
        guard !findMatches.isEmpty else {
            NSSound.beep()
            return
        }

        let next: Int
        if let current = findIndex {
            next = (current + (forward ? 1 : -1) + findMatches.count) % findMatches.count
        } else {
            next = findMatches.firstIndex { match in
                guard let page = match.pages.first, let document else { return false }
                return document.index(for: page) >= currentPageIndex
            } ?? 0
        }
        findIndex = next

        let match = findMatches[next]
        activeView?.setCurrentSelection(match, animate: true)
        activeView?.go(to: match)
    }

    func clearFind() {
        if !findMatches.isEmpty { findMatches = [] }
        if findIndex != nil { findIndex = nil }
        for view in views.allObjects {
            view.highlightedSelections = nil
        }
    }

    // MARK: - Recognition

    func cancelRecognition() {
        recognitionTask?.cancel()
    }
}

// MARK: - The view

/// A `PDFView` that keeps its own undo history and hands it to the Edit menu.
///
/// Nothing else in the window answers `undo:` — measured, not assumed: with no
/// document architecture behind it the window has no target for the action at
/// all — so the view implements it. Overriding `undoManager` alone wouldn't
/// help; something still has to receive the menu's action.
final class EditablePDFView: PDFView, NSMenuItemValidation {
    weak var editor: PDFEditingController?

    override var undoManager: UndoManager? {
        editor?.undoManager ?? super.undoManager
    }

    /// A note is an icon with text behind it, and PDFKit gives a click on one
    /// nowhere to go — so the click is caught here and the note opened.
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 1,
           let editor,
           let note = note(atViewPoint: convert(event.locationInWindow, from: nil))
        {
            editor.openNote(note)
            return
        }
        super.mouseDown(with: event)
    }

    /// The note under a point in the view's coordinates, if there is one.
    func note(atViewPoint point: NSPoint) -> PDFAnnotation? {
        guard let page = page(for: point, nearest: false),
              let annotation = page.annotation(at: convert(point, to: page)),
              annotation.type == "Text"
        else { return nil }
        return annotation
    }

    @objc func undo(_: Any?) {
        editor?.undoManager.undo()
    }

    @objc func redo(_: Any?) {
        editor?.undoManager.redo()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let history = editor?.undoManager else { return inheritedValidation(item) }
        switch item.action {
        case #selector(undo(_:)):
            item.title = history.undoMenuItemTitle
            return history.canUndo
        case #selector(redo(_:)):
            item.title = history.redoMenuItemTitle
            return history.canRedo
        default:
            return inheritedValidation(item)
        }
    }

    /// PDFView validates its own items — Copy, Select All — in an
    /// implementation it doesn't declare, so Swift can't reach it as `super`.
    /// The runtime can.
    private func inheritedValidation(_ item: NSMenuItem) -> Bool {
        let selector = #selector(NSMenuItemValidation.validateMenuItem(_:))
        guard PDFView.instancesRespond(to: selector),
              let implementation = class_getMethodImplementation(PDFView.self, selector)
        else { return true }
        typealias Validate = @convention(c) (AnyObject, Selector, NSMenuItem) -> Bool
        return unsafeBitCast(implementation, to: Validate.self)(self, selector, item)
    }
}

// MARK: - Writing

/// Writes a PDF without ever leaving a half-written file where the original
/// was: the document goes to a scratch file beside the destination first, and
/// only a complete write replaces it.
///
/// Replacing the file a live `PDFDocument` was opened from is safe — measured
/// by saving, editing further, and saving again over the same path — because
/// the replacement is a new file, and the document keeps reading the old one it
/// already has open.
///
/// An encrypted PDF that was unlocked to be opened is written back encrypted
/// with its original password: PDFKit does that on its own when no options are
/// given.
enum PDFFileWriter {
    enum WriteError: LocalizedError {
        case failed

        var errorDescription: String? { "The PDF couldn’t be written." }
        var recoverySuggestion: String? { "Check that the folder can be written to, or use Save As to put it somewhere else." }
    }

    static func write(_ document: PDFDocument, to url: URL) throws {
        try SafeFileWriter.write(to: url) { destination in
            guard document.write(to: destination) else { throw WriteError.failed }
        }
    }
}

// MARK: - Prompts

/// Asks for a PDF's password until it's right or the user gives up.
@MainActor
enum PDFPasswordPrompt {
    /// Returns `true` once the document is unlocked.
    static func unlock(_ document: PDFDocument, name: String) -> Bool {
        var failed = false
        while document.isLocked {
            let alert = NSAlert()
            alert.messageText = "“\(name)” is password protected."
            alert.informativeText = failed
                ? "That password isn’t right. Try again."
                : "Enter its password to open it."
            alert.alertStyle = failed ? .warning : .informational

            let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
            field.placeholderString = "Password"
            alert.accessoryView = field
            alert.addButton(withTitle: "Open")
            alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = field

            guard alert.runModal() == .alertFirstButtonReturn else { return false }
            if document.unlock(withPassword: field.stringValue) { return true }
            failed = true
        }
        return true
    }
}

/// The note editor: an alert with room to write in.
@MainActor
enum NotePrompt {
    enum Outcome {
        case save(String)
        case delete
        case cancel
    }

    static func run(title: String, text: String, canDelete: Bool) -> Outcome {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = canDelete ? "" : "The note appears as an icon on the page. Click it to read or change it."

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 110))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let editor = NSTextView(frame: scroll.bounds)
        editor.isRichText = false
        editor.font = .systemFont(ofSize: NSFont.systemFontSize)
        editor.string = text
        editor.autoresizingMask = [.width]
        editor.isVerticallyResizable = true
        editor.textContainer?.widthTracksTextView = true
        scroll.documentView = editor
        alert.accessoryView = scroll

        alert.addButton(withTitle: canDelete ? "Save" : "Add")
        alert.addButton(withTitle: "Cancel")
        if canDelete {
            let delete = alert.addButton(withTitle: "Delete Note")
            delete.hasDestructiveAction = true
        }
        alert.window.initialFirstResponder = editor

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return .save(editor.string.trimmingCharacters(in: .whitespacesAndNewlines))
        case .alertThirdButtonReturn:
            return .delete
        default:
            return .cancel
        }
    }
}
