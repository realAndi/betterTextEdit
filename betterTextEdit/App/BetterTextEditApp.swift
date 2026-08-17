import SwiftUI

@main
struct BetterTextEditApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 720, minHeight: 480)
                .onAppear {
                    appDelegate.connect(to: model)
                }
                .onOpenURL { url in
                    model.open(url)
                }
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            EditorCommands(model: model)
        }

        // No `Settings` scene. Settings opens as a tab in the window instead —
        // see `AppModel.showSettings()` — so it sits beside what it's changing
        // rather than floating in a panel over the top of it. That means
        // supplying the ⌘, menu item ourselves; see `EditorCommands`.
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var pendingURLs: [URL] = []
    private weak var model: AppModel?
    private var tabCycleMonitor: Any?
    private var hasOfferedUntitledDocument = false

    @MainActor
    func applicationDidFinishLaunching(_: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        // Before anything reads a setting: bring forward any that have changed
        // meaning since they were written.
        SettingsMigration.run()
        // Honour the saved theme and Light/Dark choice before any window is
        // drawn, so nothing flashes in the wrong colours on the way in.
        ThemeStore.shared.applyAppearance()
        installTabCycling()
        // Only now that the app is up — see `UpdaterService.start()` for why
        // this can't happen while the singleton is being built.
        UpdaterService.shared.start()
    }

    /// ⌃Tab and ⌃⇧Tab cycle tabs. A menu item can't carry Tab as its shortcut,
    /// so this watches for it directly — and only for that exact chord, so
    /// ordinary tabbing in the editor is untouched.
    private func installTabCycling() {
        tabCycleMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let tabKeyCode: UInt16 = 48
            guard event.keyCode == tabKeyCode,
                  event.modifierFlags.contains(.control),
                  !event.modifierFlags.contains(.command),
                  !event.modifierFlags.contains(.option),
                  let model = self?.model
            else { return event }

            if event.modifierFlags.contains(.shift) {
                model.selectPreviousDocument()
            } else {
                model.selectNextDocument()
            }
            return nil
        }
    }

    func application(_: NSApplication, open urls: [URL]) {
        guard let model else {
            pendingURLs.append(contentsOf: urls)
            return
        }
        for url in urls {
            model.open(url)
        }
    }

    @MainActor
    func connect(to model: AppModel) {
        self.model = model
        for url in pendingURLs {
            model.open(url)
        }
        pendingURLs.removeAll()
        offerUntitledDocument(model)
    }

    /// Launch straight into a blank document, the way TextEdit and Notepad do.
    ///
    /// `applicationOpenUntitledFile` would be the tidy hook, but SwiftUI creates
    /// the window itself, so AppKit never asks. Instead this waits a beat for any
    /// file the app was launched *with* to arrive, and only opens a blank
    /// document if nothing did.
    @MainActor
    private func offerUntitledDocument(_ model: AppModel) {
        guard !hasOfferedUntitledDocument else { return }
        hasOfferedUntitledDocument = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            if model.documents.isEmpty {
                model.newDocument()
            }
            // Whatever happened — a file opened, or the blank starter was just
            // created — the launch is over, so the welcome screen may show from
            // here on.
            model.markLaunchSettled()
        }
    }

    /// Clicking the Dock icon with everything closed gets a blank page too.
    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows: Bool) -> Bool {
        guard !hasVisibleWindows else { return true }
        Task { @MainActor in
            if AppModel.shared.documents.isEmpty { AppModel.shared.newDocument() }
        }
        return true
    }

    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        guard model?.hasUnsavedDocuments == true else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = "Do you want to quit without saving?"
        alert.informativeText = "You have files with unsaved changes. Your changes will be lost if you don’t save them."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Quit Without Saving")
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }
}

struct EditorCommands: Commands {
    @ObservedObject var model: AppModel
    @ObservedObject private var themes = ThemeStore.shared
    @ObservedObject private var updater = UpdaterService.shared
    @AppStorage(SettingsKey.wordWrap) private var wordWrap = false
    @AppStorage(SettingsKey.fontSize) private var fontSize = EditorMetrics.defaultFontSize
    @AppStorage(SettingsKey.sidebarVisible) private var sidebarVisible = false

    private var hasPreview: Bool {
        model.selectedDocument?.supportsPreview == true
    }

    private var isRich: Bool {
        model.selectedDocument?.kind == .rich
    }

    private var isPDF: Bool {
        model.selectedDocument?.kind == .pdf
    }

    private var isSVG: Bool {
        model.selectedDocument?.isSVG == true
    }

    private var canSave: Bool {
        guard let kind = model.selectedDocument?.kind else { return false }
        return kind == .plain || kind == .rich
    }

    private var formatting: RichTextController? {
        guard let document = model.selectedDocument, document.kind == .rich else { return nil }
        return document.formatting
    }

    var body: some Commands {
        // Straight under "About betterTextEdit", which is where every Mac app
        // puts it and so the first place anyone looks.
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { updater.checkForUpdates() }
                .disabled(!updater.canCheckForUpdates)
        }

        // The app menu's Settings item, which normally comes free with a
        // `Settings` scene. There isn't one — Settings is a tab — so the menu
        // item and its ⌘, are supplied here instead.
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { model.showSettings() }
                .keyboardShortcut(",", modifiers: .command)
        }

        CommandGroup(replacing: .newItem) {
            // The same blank document under both of the chords people arrive
            // with: ⌘N from every text editor, ⌘T from every tabbed app. A menu
            // item carries exactly one shortcut, so the second chord needs a
            // second item — and both names are true here, since a new file in
            // this app *is* a new tab.
            Button("New File") { model.newDocument() }
                .keyboardShortcut("n", modifiers: .command)
            Button("New Tab") { model.newDocument() }
                .keyboardShortcut("t", modifiers: .command)
            Button("Open…") { model.showOpenPanel() }
                .keyboardShortcut("o", modifiers: .command)
            Button("Open Folder…") { model.chooseSidebarFolder() }
                .keyboardShortcut("o", modifiers: [.command, .shift])

            Divider()

            // Closes the tab first; the window only goes once the tabs are gone.
            Button("Close") { model.closeSelectedOrWindow() }
                .keyboardShortcut("w", modifiers: .command)
        }

        CommandGroup(replacing: .saveItem) {
            Button("Save") { model.saveSelected() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!canSave)
            Button("Save As…") { model.saveSelectedAs() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(!canSave)
        }

        CommandGroup(after: .textEditing) {
            Button("Find…") {
                NotificationCenter.default.post(name: .editorShowFind, object: nil)
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(model.selectedDocument == nil)
        }

        // The View menu.
        CommandGroup(after: .toolbar) {
            Button(sidebarVisible ? "Hide File Browser" : "Show File Browser") {
                sidebarVisible.toggle()
            }
            .keyboardShortcut("s", modifiers: [.command, .control])

            Divider()

            // ⌥⌘ rather than plain ⌘, which now belongs to the tabs.
            Button("Source") { model.selectedDocument?.previewMode = .source }
                .keyboardShortcut("1", modifiers: [.command, .option])
                .disabled(!hasPreview)
            Button("Split") { model.selectedDocument?.previewMode = .split }
                .keyboardShortcut("2", modifiers: [.command, .option])
                .disabled(!hasPreview)
            Button("Preview") { model.selectedDocument?.previewMode = .preview }
                .keyboardShortcut("3", modifiers: [.command, .option])
                .disabled(!hasPreview)

            Divider()

            Toggle("Wrap Lines", isOn: $wordWrap)

            Divider()

            themeMenu

            Divider()

            Button("Bigger") { fontSize = EditorMetrics.bigger(than: fontSize) }
                .keyboardShortcut("+", modifiers: .command)
            Button("Smaller") { fontSize = EditorMetrics.smaller(than: fontSize) }
                .keyboardShortcut("-", modifiers: .command)
            Button("Actual Size") { fontSize = EditorMetrics.defaultFontSize }
                .keyboardShortcut("0", modifiers: .command)

            Divider()
        }

        CommandMenu("Format") {
            // ⇧⌘T rather than the ⌘T TextEdit uses: this panel only ever
            // applies to a rich-text document, and the plain chord is worth
            // more as New Tab, which works whatever is open. Not ⌥⌘T either —
            // that's the View menu's Show Toolbar, and the first matching item
            // in menu order is the one that fires, so Show Fonts would never
            // see it. ⇧⌘T also puts it beside Show Colours on ⇧⌘C.
            Button("Show Fonts") { formatting?.showFontPanel() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(!isRich)
            Button("Show Colours") { formatting?.showColorPanel() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(!isRich)

            Divider()

            Button("Bold") { formatting?.toggleBold() }
                .keyboardShortcut("b", modifiers: .command)
                .disabled(!isRich)
            Button("Italic") { formatting?.toggleItalic() }
                .keyboardShortcut("i", modifiers: .command)
                .disabled(!isRich)
            Button("Underline") { formatting?.toggleUnderline() }
                .keyboardShortcut("u", modifiers: .command)
                .disabled(!isRich)

            Divider()

            Button("Bigger") { formatting?.nudgeSize(by: 1) }
                .disabled(!isRich)
            Button("Smaller") { formatting?.nudgeSize(by: -1) }
                .disabled(!isRich)

            Divider()

            Button("Align Left") { formatting?.setAlignment(.left) }
                .keyboardShortcut("{", modifiers: .command)
                .disabled(!isRich)
            Button("Centre") { formatting?.setAlignment(.center) }
                .keyboardShortcut("|", modifiers: .command)
                .disabled(!isRich)
            Button("Align Right") { formatting?.setAlignment(.right) }
                .keyboardShortcut("}", modifiers: .command)
                .disabled(!isRich)
            Button("Justify") { formatting?.setAlignment(.justified) }
                .disabled(!isRich)

            Divider()

            Button("Format JSON") { model.formatSelectedJSON() }
                .keyboardShortcut("f", modifiers: [.command, .option, .shift])
                .disabled(model.selectedDocument?.language != .json)
        }

        // The Window menu, where macOS keeps tab navigation.
        CommandGroup(after: .windowList) {
            Divider()

            Button("Show Next Tab") { model.selectNextDocument() }
                .keyboardShortcut("]", modifiers: [.command, .shift])
                .disabled(model.tabIDs.count < 2)
            Button("Show Previous Tab") { model.selectPreviousDocument() }
                .keyboardShortcut("[", modifiers: [.command, .shift])
                .disabled(model.tabIDs.count < 2)

            if !model.documents.isEmpty {
                Divider()
                // ⌘1…⌘9 jump straight to a tab, listed by name the way Safari
                // lists its windows.
                ForEach(Array(model.documents.prefix(9).enumerated()), id: \.element.id) { index, document in
                    Button(document.displayName) { model.selectDocument(at: index) }
                        .keyboardShortcut(
                            KeyEquivalent(Character("\(index + 1)")),
                            modifiers: .command
                        )
                }
            }
        }

        CommandMenu("Convert") {
            Button("Extract Text from PDF") { model.extractTextFromPDF() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(!isPDF)
            Button("Convert to Markdown") { model.convertToMarkdown() }
                .disabled(!isRich && !isPDF)

            Divider()

            Button("Export SVG as PNG…") { model.exportSVGAsPNG() }
                .disabled(!isSVG)
        }
    }

    /// Switching theme without a trip to Settings. Grouped the way the gallery
    /// groups them, so the two read the same way.
    private var themeMenu: some View {
        Menu("Theme") {
            themeItem(BuiltInThemes.system)

            Section("Dark") {
                ForEach(BuiltInThemes.dark) { themeItem($0) }
            }

            Section("Light") {
                ForEach(BuiltInThemes.light) { themeItem($0) }
            }

            if !themes.imported.isEmpty {
                Section("Imported") {
                    ForEach(themes.imported) { themeItem($0) }
                }
            }
        }
    }

    private func themeItem(_ theme: EditorTheme) -> some View {
        Button {
            themes.selectedID = theme.id
        } label: {
            // A checkmark rather than a state toggle: this is a one-of-many
            // choice, and that's how macOS spells one in a menu.
            if themes.selectedID == theme.id {
                Label(theme.name, systemImage: "checkmark")
            } else {
                Text(theme.name)
            }
        }
    }
}

extension Notification.Name {
    static let editorShowFind = Notification.Name("betterTextEdit.editorShowFind")
}
