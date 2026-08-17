import SwiftUI
import UniformTypeIdentifiers

struct EditorWorkspaceView: View {
    @EnvironmentObject private var model: AppModel
    let translucent: Bool

    var body: some View {
        VStack(spacing: 0) {
            if model.hasWorkspace {
                TabStrip()
            }

            if model.isSettingsSelected {
                SettingsView()
            } else if let document = model.selectedDocument {
                DocumentEditor(document: document, translucent: translucent)
                    .id(document.id)
            } else {
                ContentUnavailableView("No File Selected", systemImage: "doc.text")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Tell the theme store what's on screen, so a file-type preset naming a
        // theme can swap the *window's* colours and not just the editor's.
        //
        // Driven from the selection rather than from the editor's own lifetime,
        // so switching to a PDF, an image, or Settings clears it — otherwise a
        // preset's theme would linger over a tab it says nothing about.
        .onAppear { syncActiveLanguage() }
        .onChange(of: model.selectedID) { _, _ in syncActiveLanguage() }
        .onChange(of: model.selectedDocument?.language) { _, _ in syncActiveLanguage() }
    }

    private func syncActiveLanguage() {
        let document = model.selectedDocument
        ThemeStore.shared.activeLanguage = document?.kind == .plain ? document?.language : nil
    }
}

// MARK: - Tabs

/// The tab strip floats over the canvas rather than sitting in a bar of its
/// own: the selected tab rides on a piece of Liquid Glass that slides between
/// tabs as the selection moves, and the new-tab button is a glass button. The
/// `GlassEffectContainer` is what lets those two shapes see each other — when
/// they come within `Chrome.glassSpacing` they merge instead of overlapping.
private struct TabStrip: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var themes = ThemeStore.shared
    @Namespace private var glass
    /// How wide the tabs' scroll view is, so the empty stretch after the last
    /// tab can be made to fill it — see `emptyStrip`.
    @State private var viewport: CGFloat = 0
    /// The tab being dragged, if any. Held here rather than in the tab because
    /// a reorder is a conversation between two of them.
    @State private var dragging: EditorDocument.ID?
    /// Where each tab currently sits, in the strip's own coordinate space.
    ///
    /// A drag has to answer "which tab am I over?", and only the strip can see
    /// all of them — so each tab reports its own frame as it lays out.
    @State private var tabFrames: [EditorDocument.ID: CGRect] = [:]

    /// The space tab frames and drag locations are both measured in, so that
    /// the two can be compared at all.
    static let space = "tabStrip"

    var body: some View {
        GlassEffectContainer(spacing: Chrome.glassSpacing) {
            HStack(spacing: 6) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(model.documents) { document in
                            TabItem(
                                document: document,
                                selected: model.selectedID == document.id,
                                namespace: glass,
                                dragging: $dragging,
                                frames: $tabFrames,
                                reorder: { model.moveDocument($0, toPositionOf: $1) },
                                select: { model.selectedID = document.id },
                                close: { model.close(document) }
                            )
                        }

                        // Settings sits at the end of the strip, after the
                        // documents, the way a tool tab does in VS Code.
                        if model.isShowingSettings {
                            SettingsTabItem(
                                selected: model.isSettingsSelected,
                                namespace: glass,
                                select: { model.selectedID = AppModel.settingsTabID },
                                close: { model.closeSettings() }
                            )
                        }

                        emptyStrip
                    }
                    .padding(4)
                    // At least as wide as the viewport, so `emptyStrip` has
                    // something to fill when there are only a few tabs. It's a
                    // *minimum*, so a strip that overflows still scrolls.
                    .frame(minWidth: viewport, alignment: .leading)
                    .coordinateSpace(.named(Self.space))
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewport = $0 }

                // No hard frame on the label: the glass style supplies its own
                // padding, so forcing a size on top of it just inflates the
                // button past the height of the tabs beside it. A small control
                // in a circle lands at the right size on its own.
                Button {
                    model.newDocument()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .controlSize(.small)
                .help("New tab")
            }
            .padding(.horizontal, 4)
        }
        .animation(.smooth(duration: 0.25), value: model.selectedID)
        // Tabs slide to their new places rather than jumping, which is most of
        // what makes a reorder legible while it's happening.
        .animation(.smooth(duration: 0.2), value: model.documents.map(\.id))
        .padding(.horizontal, Chrome.inset)
        .padding(.vertical, 7)
        // The tabs float on glass, but the band they float *on* needs to be
        // legible as a band — otherwise the strip reads as a pill loose in the
        // middle of the document. Same recess as the file browser, closed with
        // the same hairline the status bar uses at the other end, so the editor
        // canvas sits between two matching edges.
        .frame(maxWidth: .infinity)
        .background(themes.current.recess)
        // The strip's own margins — the inset either side and the air above and
        // below the tabs. These sit outside the scroll view, so a catcher back
        // here is the one thing under the pointer there.
        .background { MiddleClickCatcher(action: newTab) }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(themes.current.edge)
                .frame(height: 1)
        }
    }

    /// The stretch of empty strip after the last tab.
    ///
    /// It has to live *inside* the scroll view rather than behind it. The scroll
    /// view's own document view answers the hit test everywhere in its bounds,
    /// so anything placed behind it never hears a click that lands out here —
    /// and out here is most of the strip most of the time.
    ///
    /// Lowest layout priority, so it yields all of its width to the tabs the
    /// moment they need it and the strip goes back to scrolling normally.
    ///
    /// The height is pinned rather than given a minimum. An `NSView` has no
    /// intrinsic size, so SwiftUI reads it as flexible on both axes and hands it
    /// every point on offer — which, in a strip whose parent proposes the rest
    /// of the window, means the tab bar grows to fill the editor.
    private var emptyStrip: some View {
        MiddleClickCatcher(action: newTab)
            .frame(maxWidth: .infinity)
            .frame(height: Self.tabHeight)
            .layoutPriority(-1)
    }

    /// The height of a tab, which the empty stretch beside them matches so it
    /// can't be what decides how tall the strip is.
    private static let tabHeight: CGFloat = 26

    private func newTab() {
        model.newDocument()
    }
}

private struct TabItem: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var document: EditorDocument
    let selected: Bool
    let namespace: Namespace.ID
    @Binding var dragging: EditorDocument.ID?
    @Binding var frames: [EditorDocument.ID: CGRect]
    let reorder: (EditorDocument.ID, EditorDocument.ID) -> Void
    let select: () -> Void
    let close: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: document.language.symbol)
                .foregroundStyle(selected ? document.language.tint : Color.secondary)
                .imageScale(.small)

            Text(document.displayName)
                .lineLimit(1)

            // The macOS convention: a dot means unsaved changes, and pointing at
            // it turns it into the close button.
            if document.isModified, !hovering {
                Image(systemName: "circle.fill")
                    .font(.system(size: 6))
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 14)
            } else {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Close")
            }
        }
        .font(.callout)
        .foregroundStyle(selected ? .primary : .secondary)
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(height: 26)
        .modifier(TabBackground(selected: selected, hovering: hovering, id: document.id, namespace: namespace))
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        // Middle-click closes the tab, as it does in every browser. The
        // overlay hears only the middle button — see `MiddleClickCatcher` —
        // so the tap gesture above and the close button beside it are
        // unaffected.
        .overlay { MiddleClickCatcher(action: close) }
        .onHover { hovering = $0 }
        .help(document.pathLabel)
        // Reordering is a plain `DragGesture`, not `onDrag`.
        //
        // `onDrag` hands the tab to the system's drag-and-drop machinery, and on
        // a view that also has an `onTapGesture` — which every tab needs, to be
        // selectable — the tap wins arbitration and the drag never starts at
        // all. A `DragGesture` with a movement threshold coexists with a tap
        // properly: no movement selects, movement drags.
        //
        // It's the better fit anyway. Nothing here has to leave the window, so
        // there's no reason to serialise a tab onto a pasteboard and match it
        // back by id at the other end — the gesture already knows which tab it
        // began on.
        .zIndex(dragging == document.id ? 1 : 0)
        .scaleEffect(dragging == document.id ? 1.05 : 1)
        .animation(.smooth(duration: 0.15), value: dragging)
        .onGeometryChange(for: CGRect.self) {
            $0.frame(in: .named(TabStrip.space))
        } action: {
            frames[document.id] = $0
        }
        .gesture(
            DragGesture(minimumDistance: 5, coordinateSpace: .named(TabStrip.space))
                .onChanged { value in
                    dragging = document.id
                    reorder(towards: value.location.x)
                }
                // Unlike a drop, this always arrives — a cancelled drag ends
                // here too, which is what makes it safe to draw the lifted tab
                // from `dragging` without it getting stuck that way.
                .onEnded { _ in dragging = nil }
        )
    }

    /// Hands the dragged tab over to whichever one the pointer is inside.
    ///
    /// Compared on x alone, so wandering above or below the strip mid-drag
    /// doesn't stop the reorder tracking.
    ///
    /// This runs on every movement, but it can't thrash: once a move lands, the
    /// dragged tab is itself the one under the pointer, so the next call finds
    /// its own id and does nothing until a real boundary is crossed.
    private func reorder(towards x: CGFloat) {
        guard let target = frames.first(where: { $0.value.minX <= x && x <= $0.value.maxX })?.key,
              target != document.id
        else { return }
        reorder(document.id, target)
    }
}

/// The Settings tab. The same shape as a document's, minus the parts only a
/// document has — there's no unsaved dot, and no path to put in the tooltip.
private struct SettingsTabItem: View {
    let selected: Bool
    let namespace: Namespace.ID
    let select: () -> Void
    let close: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "gearshape")
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                .imageScale(.small)

            Text("Settings")
                .lineLimit(1)

            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .font(.callout)
        .foregroundStyle(selected ? .primary : .secondary)
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(height: 26)
        .modifier(
            TabBackground(
                selected: selected,
                hovering: hovering,
                id: AppModel.settingsTabID,
                namespace: namespace
            )
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        // Closes on a middle-click like a document tab does, so the strip
        // behaves the same way end to end.
        .overlay { MiddleClickCatcher(action: close) }
        .onHover { hovering = $0 }
    }
}

/// Only the selected tab gets glass. Putting it on all of them would stack
/// glass on glass — which Apple's guidance warns against, and which in practice
/// just reads as a muddy strip.
private struct TabBackground: ViewModifier {
    let selected: Bool
    let hovering: Bool
    let id: EditorDocument.ID
    let namespace: Namespace.ID

    @ViewBuilder
    func body(content: Content) -> some View {
        if selected {
            content
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 8, style: .continuous))
                .glassEffectID(id, in: namespace)
        } else {
            content.background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.06 : 0))
            )
        }
    }
}

// MARK: - Editor

private struct DocumentEditor: View {
    @ObservedObject var document: EditorDocument
    @ObservedObject private var themes = ThemeStore.shared
    @ObservedObject private var presets = PresetStore.shared
    let translucent: Bool
    @AppStorage(SettingsKey.wordWrap) private var wordWrap = false
    @AppStorage(SettingsKey.fontSize) private var fontSize = EditorMetrics.defaultFontSize
    @AppStorage(SettingsKey.fontName) private var fontName = EditorFonts.systemMonospaced
    @AppStorage(SettingsKey.showLineNumbers) private var showLineNumbers = true
    @AppStorage(SettingsKey.highlightCurrentLine) private var highlightCurrentLine = true
    @AppStorage(SettingsKey.lineSpacing) private var lineSpacing = EditorMetrics.defaultLineSpacing
    @AppStorage(SettingsKey.pdfZoom) private var pdfZoom = 0.0
    @AppStorage(SettingsKey.previewJavaScript) private var previewJavaScript = true
    @AppStorage(SettingsKey.imageZoom) private var imageZoom = 0.0

    var body: some View {
        VStack(spacing: 0) {
            if document.isLoading {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Opening \(document.displayName)…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = document.errorMessage {
                ContentUnavailableView {
                    Label("The File Couldn’t Be Opened", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                editorContent
            }

            statusBar
        }
    }

    @ViewBuilder
    private var editorContent: some View {
        switch document.kind {
        case .rich:
            VStack(spacing: 0) {
                FormatBar(controller: document.formatting)
                RichTextEditor(document: document)
            }

        case .pdf:
            if let pdf = document.pdf {
                PDFViewer(document: pdf, zoom: $pdfZoom)
            } else {
                ContentUnavailableView("Empty PDF", systemImage: "doc")
            }

        case .image:
            if let image = document.image {
                ImageViewer(document: image, zoom: $imageZoom)
            } else {
                ContentUnavailableView("Empty Image", systemImage: "photo")
            }

        case .plain:
            plainContent
        }
    }

    @ViewBuilder
    private var plainContent: some View {
        if document.supportsPreview {
            switch document.previewMode {
            case .source:
                codeEditor
            case .split:
                HSplitView {
                    codeEditor.frame(minWidth: 280)
                    preview.frame(minWidth: 280)
                }
            case .preview:
                preview
            }
        } else {
            codeEditor
        }
    }

    @ViewBuilder
    private var preview: some View {
        switch document.previewKind {
        case .html:
            HTMLPreview(
                html: document.text,
                directory: document.resourceDirectory,
                documentName: document.displayName,
                allowsJavaScript: previewJavaScript
            )
        case .svg:
            SVGPreview(svg: document.text)
        case .markdown, .none:
            MarkdownPreview(markdown: document.text)
        }
    }

    /// The settings in force for *this* document: the globals, with any
    /// file-type preset for its language laid over the top.
    private var settings: EffectiveEditorSettings {
        EffectiveEditorSettings(
            preset: presets.preset(for: document.language),
            fontName: fontName,
            fontSize: fontSize,
            lineSpacing: lineSpacing,
            wordWrap: wordWrap
        )
    }

    private var codeEditor: some View {
        CodeEditor(
            text: $document.text,
            language: document.language,
            fontSize: settings.fontSize,
            fontName: settings.fontName,
            wordWrap: settings.wordWrap,
            translucent: translucent,
            theme: themes.current,
            showsLineNumbers: showLineNumbers,
            lineSpacing: settings.lineSpacing,
            highlightsCurrentLine: highlightCurrentLine,
            cursorPosition: { line, column in
                document.cursorLine = line
                document.cursorColumn = column
            }
        )
    }

    private var statusBar: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(document.language.tint)
                .frame(width: 6, height: 6)

            if document.kind == .plain {
                languagePicker
            } else {
                Text(originLabel)
            }

            if let note = document.imageNote {
                Text("·")
                Label(note, systemImage: "photo.badge.exclamationmark")
                    .help("macOS can’t write pictures into a Word file. Saving creates a copy "
                        + "without them, so the original keeps its images.")
            } else if document.kind == .image, let image = document.image {
                Text("·")
                Text(image.summary)
            } else if document.needsSaveAs, document.kind != .plain {
                Text("·")
                Text(document.kind == .pdf ? "Read only" : "Saves as a Word copy")
            }

            Spacer()

            if document.kind == .pdf {
                if let pdf = document.pdf {
                    Text("\(pdf.pageCount) \(pdf.pageCount == 1 ? "page" : "pages")")
                        .monospacedDigit()
                }
            } else if document.kind == .image {
                if let image = document.image, image.isAnimated {
                    Text("\(image.frames.count) frames").monospacedDigit()
                }
            } else {
                Text("Line \(document.cursorLine), Column \(document.cursorColumn)")
                    .monospacedDigit()
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 12)
        .frame(height: 24)
        // The bottom half of the same idea as the tab band: matching recess,
        // matching hairline, so the editor canvas reads as the thing held
        // between them rather than as everything that isn't a control.
        .background(themes.current.recess)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(themes.current.edge)
                .frame(height: 1)
        }
    }

    /// What the editor thinks this text is, and a way to say otherwise.
    ///
    /// Detection is a guess, and a guess the user can't correct is an
    /// annoyance — so the label that reports it is also the control that
    /// overrides it, the way Xcode and BBEdit put the language in the status
    /// bar. "Automatic" hands it back.
    private var languagePicker: some View {
        Menu {
            item(named: automaticTitle, selected: document.chosenLanguage == nil) {
                document.setLanguage(nil)
            }
            Divider()
            ForEach(FileLanguage.selectable) { language in
                item(named: language.rawValue, selected: document.chosenLanguage == language) {
                    document.setLanguage(language)
                }
            }
        } label: {
            Text(originLabel)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("The language this file is highlighted and previewed as")
    }

    private var automaticTitle: String {
        document.languageWasDetected
            ? "Automatic (\(document.language.rawValue))"
            : "Automatic"
    }

    private func item(named title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if selected {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    /// For an imported document, the format it came from is more useful than
    /// the generic kind — "Word document" beats "Formatted Text".
    private var originLabel: String {
        if document.kind != .plain, let format = document.importedFormat {
            return format.displayName
        }
        return document.language.rawValue
    }
}
