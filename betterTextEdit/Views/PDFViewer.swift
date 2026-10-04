import PDFKit
import SwiftUI

extension SettingsKey {
    static let pdfSidebarVisible = "pdf.sidebarVisible"
}

/// Shows a PDF as a PDF — and lets it be worked on as one.
///
/// Anything that flattens a PDF to text throws away the part that took the
/// effort — the typography, the spacing, the colour, the figures. PDFKit
/// renders the pages exactly as they were authored, with selection, search, and
/// zoom included, and it fills in forms in place. What's added on top is what a
/// reader actually does to a PDF: mark it up, leave notes, turn and reorder and
/// drop pages, and find things in it. Turning the text into something editable
/// is still a separate, deliberate step.
///
/// Zoom works the way it does for images: 0 means "fit the window" and re-fits
/// as the window resizes, and any other value is a fixed multiple of the page's
/// own size that stays put. The bar underneath is the same one, so the two
/// viewers behave identically.
struct PDFViewer: View {
    let document: PDFDocument
    @ObservedObject var editor: PDFEditingController
    @Binding var zoom: Double

    @AppStorage(SettingsKey.pdfSidebarVisible) private var showsSidebar = false

    /// This viewer's own `PDFView`, made once and kept while it is on screen.
    @StateObject private var holder = PDFViewHolder()

    /// What PDFKit is actually showing, which is not always what `zoom` says:
    /// under "fit" the scale moves on its own as the window resizes, and a
    /// pinch changes it without going through us.
    @State private var scale: Double = 1

    @State private var query = ""
    @State private var pageField = ""
    @FocusState private var findFocused: Bool

    private static let limits = 0.05 ... 20.0
    private static let step = 1.25

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                if showsSidebar {
                    PDFSidebar(editor: editor, document: document)
                    Divider()
                }
                PDFCanvas(editor: editor, pdfView: pdfView, document: document, zoom: $zoom, scale: $scale)
                    .overlay(alignment: .top) { RecognitionBanner(editor: editor) }
            }
            Divider()
            controls
        }
        .onReceive(NotificationCenter.default.publisher(for: .editorShowFind)) { _ in
            findFocused = true
        }
        // Typing pauses for a beat before searching, so a long document isn't
        // searched once per keystroke. Changing the query cancels the wait.
        .task(id: query) {
            guard !query.isEmpty else {
                editor.clearFind()
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            editor.find(query)
        }
        .onAppear { pageField = "\(editor.currentPageIndex + 1)" }
        .onChange(of: editor.currentPageIndex) { _, index in pageField = "\(index + 1)" }
    }

    private var pdfView: EditablePDFView {
        if let view = holder.view { return view }
        let view = editor.makeView()
        holder.view = view
        return view
    }

    private func clamped(_ value: Double) -> Double {
        min(max(value, Self.limits.lowerBound), Self.limits.upperBound)
    }

    /// Zooms by a factor of what's on screen, so stepping up out of "fit"
    /// carries on from the size the page was actually being shown at.
    private func zoom(by factor: Double) {
        zoom = clamped(scale * factor)
    }

    // MARK: - The bar

    private var controls: some View {
        HStack(spacing: 10) {
            Button {
                showsSidebar.toggle()
            } label: {
                Image(systemName: "sidebar.left")
            }
            .help(showsSidebar ? "Hide thumbnails" : "Show thumbnails")

            pageNavigator

            Divider().frame(height: 16)

            findField

            Spacer(minLength: 8)

            markupMenu
            pagesMenu

            Divider().frame(height: 16)

            zoomControls
        }
        .font(.subheadline)
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .frame(height: 34)
    }

    private var pageNavigator: some View {
        HStack(spacing: 4) {
            Button {
                editor.go(toPage: editor.currentPageIndex - 1)
            } label: {
                Image(systemName: "chevron.up")
            }
            .disabled(editor.currentPageIndex <= 0)
            .help("Previous page")

            TextField("Page", text: $pageField)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 40)
                .onSubmit {
                    if let number = Int(pageField.trimmingCharacters(in: .whitespaces)) {
                        editor.go(toPage: number - 1)
                    }
                    pageField = "\(editor.currentPageIndex + 1)"
                }
                .help("Go to page")

            Text("of \(editor.pageCount)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .fixedSize()

            Button {
                editor.go(toPage: editor.currentPageIndex + 1)
            } label: {
                Image(systemName: "chevron.down")
            }
            .disabled(editor.currentPageIndex >= editor.pageCount - 1)
            .help("Next page")
        }
    }

    /// Return finds the next match and ⇧Return the previous one, the way the
    /// find bar works everywhere else on the Mac. Escape clears.
    private var findField: some View {
        HStack(spacing: 4) {
            TextField("Find in PDF", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($findFocused)
                .frame(minWidth: 80, idealWidth: 170, maxWidth: 200)
                .onSubmit {
                    if editor.findMatches.isEmpty {
                        editor.find(query)
                    } else {
                        editor.stepFind(forward: !NSEvent.modifierFlags.contains(.shift))
                    }
                }
                .onExitCommand {
                    query = ""
                    editor.clearFind()
                }

            if !query.isEmpty {
                Text(findStatus)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .fixedSize()

                Button {
                    editor.stepFind(forward: false)
                } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(editor.findMatches.isEmpty)
                .help("Previous match")

                Button {
                    editor.stepFind(forward: true)
                } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(editor.findMatches.isEmpty)
                .help("Next match")
            }
        }
    }

    private var findStatus: String {
        guard !editor.findMatches.isEmpty else { return "Not found" }
        let position = editor.findIndex.map { "\($0 + 1) of " } ?? ""
        return "\(position)\(editor.findMatches.count)"
    }

    private var markupMenu: some View {
        Menu {
            Button("Highlight") { editor.addMarkup(.highlight) }
                .disabled(!editor.hasTextSelection)
            Button("Underline") { editor.addMarkup(.underline) }
                .disabled(!editor.hasTextSelection)
            Button("Strikethrough") { editor.addMarkup(.strikeOut) }
                .disabled(!editor.hasTextSelection)
            Divider()
            Button("Add Note…") { editor.addNote() }
            Divider()
            Button("Remove Markup in Selection") { editor.removeMarkupInSelection() }
                .disabled(!editor.hasTextSelection)
        } label: {
            Image(systemName: "highlighter")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Mark up the selected text, or add a note")
    }

    private var pagesMenu: some View {
        Menu {
            Button("Rotate Left") { editor.rotateTargetPages(by: -90) }
            Button("Rotate Right") { editor.rotateTargetPages(by: 90) }
            Divider()
            Button("Move Page Up") { editor.moveCurrentPage(by: -1) }
                .disabled(!editor.canMoveCurrentPageUp)
            Button("Move Page Down") { editor.moveCurrentPage(by: 1) }
                .disabled(!editor.canMoveCurrentPageDown)
            Divider()
            Button("Insert Pages from File…") { AppModel.shared.insertPagesIntoPDF() }
            Button("Export Pages…") { AppModel.shared.exportPDFPages() }
            Divider()
            Button(editor.selectedPages.count > 1 ? "Delete Selected Pages" : "Delete Page", role: .destructive) {
                editor.deleteTargetPages()
            }
            .disabled(editor.pageCount <= 1)
        } label: {
            Image(systemName: "doc.on.doc")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Rotate, reorder, insert, export, or delete pages")
    }

    private var zoomControls: some View {
        HStack(spacing: 10) {
            Button {
                zoom(by: 1 / Self.step)
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .help("Zoom out")
            .disabled(scale <= Self.limits.lowerBound)

            Text("\(Int((scale * 100).rounded()))%")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 44)

            Button {
                zoom(by: Self.step)
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .help("Zoom in")
            .disabled(scale >= Self.limits.upperBound)

            Button("Fit") { zoom = 0 }
                .disabled(zoom == 0)
                .help("Resize the page to the window, and keep it there")

            Button("100%") { zoom = 1 }
                .disabled(zoom == 1)
                .help("The page at its authored size")
        }
    }
}

// MARK: - Recognition progress

/// A pill over the page while Vision reads it — scanned PDF pages one at a
/// time, or a picture all at once — with a way out, since a long scan takes a
/// while.
struct RecognitionBanner: View {
    @ObservedObject var editor: PDFEditingController

    var body: some View {
        if let progress = editor.recognition {
            HStack(spacing: 10) {
                if progress.total > 0 {
                    ProgressView(value: Double(progress.completed), total: Double(progress.total))
                        .frame(width: 110)
                } else {
                    ProgressView().controlSize(.small)
                }

                Text(label(for: progress))
                    .monospacedDigit()

                Button("Cancel") { editor.cancelRecognition() }
                    .controlSize(.small)
            }
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .glassEffect(.regular, in: Capsule())
            .padding(.top, 12)
            .transition(.opacity)
        }
    }

    private func label(for progress: PDFEditingController.Recognition) -> String {
        guard progress.total > 0 else { return "Reading text…" }
        let page = min(progress.completed + 1, progress.total)
        return progress.total == 1
            ? "Reading the scanned page…"
            : "Reading scanned page \(page) of \(progress.total)…"
    }
}

/// "Page 3 of 12" for the status bar.
struct PDFPageStatus: View {
    @ObservedObject var editor: PDFEditingController

    var body: some View {
        Text("Page \(editor.currentPageIndex + 1) of \(editor.pageCount)")
            .monospacedDigit()
    }
}

/// Holds a viewer's `PDFView` for as long as the viewer is on screen.
private final class PDFViewHolder: ObservableObject {
    var view: EditablePDFView?
}

// MARK: - The canvas

/// Puts a viewer's `PDFView` on screen, and tells the controller while it's
/// there — that's what lets the menu commands find it, and what lets the next
/// view of this document open at the page this one was showing.
private struct PDFCanvas: NSViewRepresentable {
    let editor: PDFEditingController
    let pdfView: EditablePDFView
    let document: PDFDocument
    @Binding var zoom: Double
    @Binding var scale: Double

    func makeCoordinator() -> Coordinator {
        Coordinator(zoom: $zoom, scale: $scale)
    }

    func makeNSView(context: Context) -> EditablePDFView {
        let view = pdfView
        editor.register(view)
        context.coordinator.editor = editor

        // PDFKit does its own pinch handling, and does it well — page-aware and
        // properly centred. Rather than fight it with a gesture of our own, we
        // listen for the result and adopt it.
        context.coordinator.observe(view)
        DispatchQueue.main.async {
            scale = view.scaleFactor
            // So ⌘Z, Copy, and the arrow keys reach the PDF straight away.
            if view.window?.firstResponder === view.window {
                view.window?.makeFirstResponder(view)
            }
        }
        return view
    }

    func updateNSView(_ view: EditablePDFView, context: Context) {
        context.coordinator.zoom = $zoom
        context.coordinator.scale = $scale

        if view.document !== document {
            view.document = document
            view.autoScales = true
        }

        // 0 is "fit", which is exactly what `autoScales` does — including
        // re-fitting when the window changes size.
        if zoom > 0 {
            view.autoScales = false
            if abs(view.scaleFactor - zoom) > 0.001 {
                view.scaleFactor = zoom
            }
        } else if !view.autoScales {
            view.autoScales = true
        }
    }

    static func dismantleNSView(_ view: EditablePDFView, coordinator: Coordinator) {
        coordinator.stopObserving()
        coordinator.editor?.retire(view)
    }

    final class Coordinator: NSObject {
        var zoom: Binding<Double>
        var scale: Binding<Double>
        weak var editor: PDFEditingController?
        private weak var observed: PDFView?

        init(zoom: Binding<Double>, scale: Binding<Double>) {
            self.zoom = zoom
            self.scale = scale
        }

        func observe(_ view: PDFView) {
            stopObserving()
            observed = view
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(scaleChanged),
                name: .PDFViewScaleChanged,
                object: view
            )
        }

        func stopObserving() {
            NotificationCenter.default.removeObserver(self, name: .PDFViewScaleChanged, object: observed)
            observed = nil
        }

        /// PDFKit changed the scale — because the window resized under "fit",
        /// because the user pinched, or because we asked it to.
        ///
        /// Telling those apart is what `autoScales` is for. While it's on we're
        /// fitting, and the scale is only worth reporting for the percentage on
        /// the bar; adopting it into `zoom` there would turn the first window
        /// resize into a fixed zoom and quietly break fitting. Once it's off,
        /// the number *is* the setting, so a pinch sticks.
        @objc func scaleChanged(_ note: Notification) {
            guard let view = note.object as? PDFView else { return }
            scale.wrappedValue = view.scaleFactor

            guard !view.autoScales, abs(view.scaleFactor - zoom.wrappedValue) > 0.001 else { return }
            zoom.wrappedValue = view.scaleFactor
        }
    }
}
