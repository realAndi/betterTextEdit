import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var themes = ThemeStore.shared
    @AppStorage(SettingsKey.windowSurface) private var surfaceRaw = WindowSurface.glass.rawValue
    @AppStorage(SettingsKey.glassOpacity) private var glassOpacity = 0.0
    @AppStorage(SettingsKey.themeAccent) private var themeAccent = true
    // Collapsed until asked for.
    @AppStorage(SettingsKey.sidebarVisible) private var sidebarVisible = false
    @State private var isTargeted = false

    private var surface: WindowSurface {
        WindowSurface(rawValue: surfaceRaw) ?? .glass
    }

    /// What the window's controls are coloured with. `Color.accentColor` is the
    /// one from System Settings; a theme can take it over.
    private var accent: Color {
        themeAccent ? themes.current.accentColor : .accentColor
    }

    var body: some View {
        ZStack {
            canvas

            HStack(spacing: 0) {
                if sidebarVisible {
                    FileSidebar()
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    // The theme's hairline rather than a system `Divider`, so
                    // all three edges around the canvas are the same line.
                    Rectangle()
                        .fill(themes.current.edge)
                        .frame(width: 1)
                }

                if model.hasWorkspace {
                    EditorWorkspaceView(translucent: surface.isTranslucent)
                } else if model.isLaunching {
                    // A bare canvas while the app is still opening its first
                    // document, so the welcome screen doesn't flash before the
                    // starter tab appears. It returns for good once the launch
                    // has settled — most visibly when the last tab is closed.
                    Color.clear
                } else {
                    WelcomeView()
                }
            }
            .animation(.easeInOut(duration: 0.18), value: sidebarVisible)
        }
        .navigationTitle(model.selectedDocument?.displayName ?? "betterTextEdit")
        .modifier(ProxyIcon(url: model.selectedDocument?.url))
        .toolbar { toolbar }
        // One tint for every stock control in the window — the segmented
        // pickers, the prominent buttons, the focus rings — so a theme reaches
        // the chrome and not just the code. Everything below reads it out of
        // the environment as `Color.accentColor`, so this is the only place the
        // choice has to be made.
        .tint(accent)
        .background(
            WindowConfigurator(
                translucent: surface.isTranslucent,
                background: themes.current.windowBackground
            )
        )
        .onDrop(of: [.fileURL], isTargeted: $isTargeted, perform: handleDrop)
        .overlay {
            RoundedRectangle(cornerRadius: Chrome.cornerRadius, style: .continuous)
                .strokeBorder(accent, lineWidth: 3)
                .padding(4)
                .opacity(isTargeted ? 1 : 0)
                .animation(.easeOut(duration: 0.12), value: isTargeted)
                .allowsHitTesting(false)
        }
    }

    /// The window's base surface, under everything.
    ///
    /// The two Liquid Glass surfaces tint themselves, because that's how the
    /// API wants to be told; the two that aren't glass take a flat wash of the
    /// same colour laid over the top. Either way the strength is the same
    /// number, so switching surface changes the material and nothing else.
    @ViewBuilder
    private var canvas: some View {
        switch surface {
        case .solid:
            themes.current.windowBackgroundColor.ignoresSafeArea()

        case .glass:
            LiquidGlassCanvas(style: .regular, tint: tint(washStrength))
                .ignoresSafeArea()

        case .clear:
            LiquidGlassCanvas(style: .clear, tint: tint(washStrength))
                .ignoresSafeArea()

        case .blur:
            MaterialCanvas()
                .ignoresSafeArea()
            wash(washStrength)

        case .sheer:
            // Nothing underneath at all: the window is a hole, and the wash is
            // the only thing between the code and the desktop. At zero there
            // isn't even that.
            wash(washStrength)
        }
    }

    /// How much of the theme's canvas colour the window carries.
    ///
    /// A theme keeps a floor on the surfaces that are meant to *be* a canvas,
    /// and takes the dial at its word on the ones that are meant to be seen
    /// through. See `WindowSurface.keepsThemeFloor`.
    private var washStrength: Double {
        surface.keepsThemeFloor
            ? themeWash(tint: glassOpacity, theme: themes.current)
            : glassOpacity
    }

    /// The theme's canvas colour at a given strength, or `nil` for no tint at
    /// all — which is what the System theme asks for with the dial down.
    private func tint(_ strength: Double) -> NSColor? {
        guard strength > 0.001 else { return nil }
        return themes.current.windowBackground.withAlphaComponent(min(strength, 1))
    }

    /// The same colour as a flat layer, for the surfaces that have no material
    /// of their own to tint.
    private func wash(_ strength: Double) -> some View {
        themes.current.windowBackgroundColor
            .opacity(min(strength, 1))
            .ignoresSafeArea()
            .allowsHitTesting(false)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                sidebarVisible.toggle()
            } label: {
                Label("Files", systemImage: "sidebar.leading")
            }
            .help(sidebarVisible ? "Hide the file browser" : "Show the file browser")
        }

        // One principal item whose *content* changes, rather than two items that
        // come and go. Adding and removing separate `.principal` items as the
        // selected document changes leaves SwiftUI showing a stale one — so the
        // preview picker would linger over a plain-text file. A single item that
        // switches what it holds updates cleanly.
        ToolbarItem(placement: .principal) {
            principalControl
        }

        ToolbarItemGroup(placement: .primaryAction) {
            ViewOptionsButton(document: model.selectedDocument)

            Button {
                model.showOpenPanel()
            } label: {
                Label("Open", systemImage: "folder")
            }
            .help("Open a file")

            Button {
                model.saveSelected()
            } label: {
                Label("Save", systemImage: "square.and.arrow.down")
            }
            .disabled(!canSave)
            .help("Save this file")

            ShareButton(url: shareURL, hint: shareHint)
        }
    }

    /// The centre of the toolbar: the Source/Split/Preview picker for a
    /// previewable file, the Extract-Text button for a PDF, and nothing at all
    /// for everything else.
    private var principalControl: some View {
        PrincipalControl(document: model.selectedDocument) {
            model.extractTextFromPDF()
        }
    }

    private var canSave: Bool {
        guard let kind = model.selectedDocument?.kind else { return false }
        return kind == .plain || kind == .rich
    }

    /// The file Share hands over: the one on disk that Save writes to. `nil` —
    /// and Share off with it — for Settings, for nothing selected, and for a
    /// document that has never been saved, since there'd be no file to give.
    ///
    /// Deliberately no save-first: a Share button that opens a Save panel isn't
    /// the button it appears to be, and the user can always press ⌘S.
    /// The file to hand to the share sheet.
    ///
    /// `url ?? sourceURL`, not just `url`. A document opened from a format
    /// macOS can read but not write — `.doc`, `.odt`, a web archive — carries
    /// no `url`, because Save mustn't overwrite it. That says nothing about
    /// whether it can be *shared*: the original is sitting on disk at
    /// `sourceURL`, and sending someone a copy of it is exactly right.
    ///
    /// What's left with neither is a document that has never been written at
    /// all, and there's genuinely nothing to send.
    private var shareURL: URL? {
        guard !model.isSettingsSelected, let document = model.selectedDocument else { return nil }
        return document.url ?? document.sourceURL
    }

    /// What Share says on hover — and, when it's off, why. A greyed-out control
    /// whose tooltip only names it tells you nothing you can act on.
    private var shareHint: String {
        guard !model.isSettingsSelected, model.selectedDocument != nil else {
            return "Open a file to share it"
        }
        guard shareURL == nil else { return "Share this file" }
        return "Save this file before you share it"
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers where provider.hasItemConformingToTypeIdentifier("public.file-url") {
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                let url: URL? = if let data = item as? Data {
                    URL(dataRepresentation: data, relativeTo: nil)
                } else {
                    item as? URL
                }
                if let url {
                    Task { @MainActor in model.open(url) }
                }
            }
        }
        return true
    }
}

/// Gives the window title bar the standard document proxy icon — the one you
/// can drag, or ⌘-click to walk back up the folder path.
private struct ProxyIcon: ViewModifier {
    let url: URL?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let url {
            content.navigationDocument(url)
        } else {
            content
        }
    }
}

// MARK: - Toolbar controls

/// The Source / Split / Preview switch, for Markdown and HTML alike. A stock
/// segmented picker — this is the control macOS already uses for exactly this job.
private struct PreviewModePicker: View {
    @ObservedObject var document: EditorDocument

    var body: some View {
        Picker("View", selection: $document.previewMode) {
            ForEach(EditorDocument.PreviewMode.allCases) { mode in
                Label(mode.label, systemImage: mode.symbol).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelStyle(.iconOnly)
        .labelsHidden()
        .help("Choose how to view this \(document.language.rawValue) file")
    }
}

/// Hands the file being worked on to the system share sheet.
///
/// `ShareLink` is the stock control and brings the whole sheet — Mail,
/// Messages, AirDrop, whatever the user has — with it, but it can only be given
/// a file that exists. So when there isn't one this is a dead button wearing the
/// same face, rather than an item that comes and goes: same reasoning as the
/// principal item, and it keeps the toolbar's spacing from shifting about.
private struct ShareButton: View {
    let url: URL?
    /// What to say on hover — including the reason it's off, when it is.
    let hint: String

    var body: some View {
        Group {
            if let url {
                ShareLink(item: url) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            } else {
                Button {} label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .disabled(true)
            }
        }
        .help(hint)
    }
}

/// What the middle of the toolbar shows, decided by the document rather than by
/// `ContentView`.
///
/// It has to be its own view because the answer turns on the document's
/// *language*, and language is published by the document, not by `AppModel`.
/// Deciding it inside `ContentView`'s body meant that setting an untitled file
/// to Markdown in the status bar left the toolbar showing nothing at all: the
/// document told its own observers, but nothing had re-run the test that would
/// have put the picker on screen.
///
/// The optional is unwrapped here rather than at the call site so the toolbar
/// keeps exactly one principal item whose *content* changes — items that come
/// and go leave SwiftUI showing a stale one.
private struct PrincipalControl: View {
    let document: EditorDocument?
    let extractText: () -> Void

    var body: some View {
        if let document {
            PrincipalContent(document: document, extractText: extractText)
        }
    }
}

private struct PrincipalContent: View {
    @ObservedObject var document: EditorDocument
    let extractText: () -> Void

    var body: some View {
        if document.supportsPreview {
            PreviewModePicker(document: document)
        } else if document.kind == .pdf {
            Button(action: extractText) {
                Label("Extract Text", systemImage: "text.viewfinder")
            }
            .help("Copy this PDF’s text into an editable document")
            .disabled(document.pdf == nil)
        }
    }
}

/// The "AA" toolbar control. A popover — not a menu — because it holds live
/// controls like steppers and toggles, which a menu can't show.
///
/// Takes the document rather than what it decided, for the same reason as
/// `PrincipalControl`: whether the HTML row belongs in the popover is a
/// question about the language, and only the document knows when that changes.
private struct ViewOptionsButton: View {
    let document: EditorDocument?
    @State private var showing = false

    var body: some View {
        Button {
            showing.toggle()
        } label: {
            Label("View Options", systemImage: "textformat.size")
        }
        .help("View and appearance options")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            if let document {
                ViewOptionsForm(document: document)
            } else {
                ViewOptionsForm(document: nil)
            }
        }
    }
}

/// The contents of the AA popover: the view options for the current document.
///
/// Window appearance — Light/Dark, glass, glass opacity — deliberately lives
/// only in Settings (⌘,), not here, so there's a single home for it rather than
/// two panels that can fall out of step.
private struct ViewOptionsForm: View {
    let document: EditorDocument?

    private var kind: EditorDocument.Kind { document?.kind ?? .plain }
    private var isHTML: Bool { document?.language == .html }

    @AppStorage(SettingsKey.fontSize) private var fontSize = EditorMetrics.defaultFontSize
    @AppStorage(SettingsKey.wordWrap) private var wordWrap = false
    @AppStorage(SettingsKey.previewJavaScript) private var previewJavaScript = true

    var body: some View {
        Form {
            documentSection
        }
        .formStyle(.grouped)
        .frame(width: 320)
        .frame(maxHeight: 520)
        .scrollBounceBehavior(.basedOnSize)
    }

    @ViewBuilder
    private var documentSection: some View {
        switch kind {
        case .plain:
            Section("Text") {
                EditorFontPicker()
                Stepper(
                    "Size: \(Int(fontSize)) pt",
                    value: $fontSize,
                    in: EditorMetrics.minimumFontSize ... EditorMetrics.maximumFontSize,
                    step: 1
                )
                .monospacedDigit()
                Toggle("Wrap long lines", isOn: $wordWrap)
                if isHTML {
                    Toggle("Run JavaScript in preview", isOn: $previewJavaScript)
                }
            }

        case .pdf:
            // As with images: zoom is continuous now, so a popup of fixed stops
            // would sit blank for most of the range.
            Section("View") {
                Text("Zoom is in the bar below the page. Pinch to zoom, or use Fit and 100%.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .image:
            // No zoom popup here any more. Zoom is continuous now — pinch, the
            // buttons under the picture, or a double-click — and a popup of
            // five fixed stops can't show a value like 137%: it would sit blank
            // for most of the range and read as broken.
            Section("View") {
                Text("Zoom is in the bar below the picture. Pinch to zoom, or double-click to "
                    + "switch between fitting the window and actual size.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .rich:
            Section("Text") {
                Text("Text size and style are in the Format menu.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
        }
    }
}

// MARK: - Empty state

private struct WelcomeView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ContentUnavailableView {
            Label("No File Open", systemImage: "doc.text")
        } description: {
            Text("Open a text, Markdown, or source file to edit it — or a Word, Rich Text, or OpenDocument file to edit it with its formatting, and save it back for Word. PDFs open as PDFs.")
        } actions: {
            VStack(spacing: 14) {
                HStack(spacing: 12) {
                    Button("Open…") { model.showOpenPanel() }
                        .buttonStyle(.borderedProminent)
                    Button("New File") { model.newDocument() }
                }
                .controlSize(.large)

                Text("You can also drag a file into this window.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
