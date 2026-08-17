import AppKit
import Foundation

// Which theme is on, and what's available to switch to.
//
// Built-in themes live in the binary; imported ones live as JSON in Application
// Support, one file per theme, named by id. That's deliberately a folder full
// of readable files rather than a blob in `UserDefaults` — a theme you imported
// is a thing you can look at, edit, copy to another Mac, or throw away in the
// Finder.

@MainActor
final class ThemeStore: ObservableObject {
    static let shared = ThemeStore()

    /// Themes read from Application Support, newest import last.
    @Published private(set) var imported: [EditorTheme] = []

    /// The theme in force, ready to paint with. Everything that draws reads
    /// this and nothing else.
    @Published private(set) var current: ResolvedTheme

    /// The id of the chosen theme. Setting it is how the app changes theme.
    @Published var selectedID: String {
        didSet {
            guard selectedID != oldValue else { return }
            UserDefaults.standard.set(selectedID, forKey: SettingsKey.themeID)
            rebuild()
            applyAppearance()
        }
    }

    /// The language of the document on screen, or `nil` when there isn't one.
    ///
    /// Set by the window as the selection moves, and it's what lets a file-type
    /// preset swap the theme when you switch tabs. Keeping it here rather than
    /// having every view ask "which theme for this language?" means the dozens
    /// of existing `themes.current` call sites — the sidebar, the tab band, the
    /// status bar — keep working untouched and simply see a different answer.
    @Published var activeLanguage: FileLanguage? {
        didSet {
            guard activeLanguage != oldValue else { return }
            rebuild()
            applyAppearance()
        }
    }

    /// Everything on offer, built-ins first.
    var all: [EditorTheme] { BuiltInThemes.all + imported }

    /// The theme the user picked in Settings, before any preset has a say.
    var selected: EditorTheme {
        all.first { $0.id == selectedID } ?? BuiltInThemes.system
    }

    /// The theme actually in force: the chosen one, unless a file-type preset
    /// names a different one for what's on screen.
    ///
    /// A preset naming a theme that's since been deleted falls back rather than
    /// leaving the window with nothing — the same rule `selected` follows.
    var effective: EditorTheme {
        guard let id = PresetStore.shared.preset(for: activeLanguage)?.themeID,
              let preset = all.first(where: { $0.id == id })
        else { return selected }
        return preset
    }

    /// True when a preset, rather than the Settings choice, is deciding.
    var isThemeFromPreset: Bool {
        effective.id != selected.id
    }

    private init() {
        let stored = UserDefaults.standard.string(forKey: SettingsKey.themeID) ?? BuiltInThemes.system.id
        selectedID = stored
        // Set before `imported` is filled, so there's never a moment with no
        // theme; `rebuild()` below settles it once the folder has been read.
        current = ResolvedTheme(BuiltInThemes.theme(id: stored) ?? BuiltInThemes.system)
        imported = loadImported()
        rebuild()
    }

    private func rebuild() {
        current = ResolvedTheme(effective)
    }

    /// Re-reads the presets. They live in their own store, so a change there
    /// has to say so — the theme in force may have just moved.
    func presetsChanged() {
        rebuild()
        applyAppearance()
    }

    // MARK: - Appearance

    /// Puts the window chrome in step with the theme.
    ///
    /// The Appearance setting still wins when it's been set to Light or Dark
    /// explicitly — that's a decision the user made about their windows, and a
    /// theme shouldn't overrule it. On "System", though, the theme is the better
    /// answer: a dark theme in a light window looks like a mistake.
    func applyAppearance() {
        let raw = UserDefaults.standard.string(forKey: SettingsKey.appearance)
        let mode = raw.flatMap(AppearanceMode.init) ?? .system
        if let explicit = mode.nsAppearance {
            NSApp.appearance = explicit
            return
        }
        NSApp.appearance = current.followsSystem
            ? nil
            : NSAppearance(named: current.isDark ? .darkAqua : .aqua)
    }

    // MARK: - Importing

    /// Reads every theme out of the given files and keeps them.
    ///
    /// Returns what was added. Anything that couldn't be read is collected and
    /// thrown at the end, so one bad file in a selection of ten doesn't lose the
    /// other nine.
    @discardableResult
    func importThemes(from urls: [URL]) throws -> [EditorTheme] {
        var added: [EditorTheme] = []
        var failures: [Error] = []

        for url in urls {
            do {
                for theme in try VSCodeThemeImporter.themes(at: url) {
                    added.append(try store(theme))
                }
            } catch {
                failures.append(error)
            }
        }

        if !added.isEmpty {
            imported = loadImported()
            rebuild()
        }
        if let failure = failures.first, added.isEmpty { throw failure }
        return added
    }

    /// Writes one theme to the themes folder and returns it under the id it
    /// actually got.
    private func store(_ theme: EditorTheme) throws -> EditorTheme {
        var stored = theme
        stored.id = availableID(for: theme.id)

        let directory = themesDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(stored)
        try data.write(to: directory.appendingPathComponent(stored.id + ".json"), options: .atomic)
        return stored
    }

    /// An id no built-in already owns.
    ///
    /// Colliding with another *import* is fine and deliberate: re-importing a
    /// theme you've tweaked in VS Code updates the copy here instead of leaving
    /// you with "Tokyo Night" and "Tokyo Night 2".
    private func availableID(for id: String) -> String {
        var candidate = id
        var counter = 2
        while BuiltInThemes.all.contains(where: { $0.id == candidate }) {
            candidate = "\(id)-\(counter)"
            counter += 1
        }
        return candidate
    }

    // MARK: - Removing

    func remove(_ theme: EditorTheme) {
        guard !theme.isBuiltIn else { return }
        try? FileManager.default.removeItem(at: themesDirectory.appendingPathComponent(theme.id + ".json"))
        imported.removeAll { $0.id == theme.id }
        if selectedID == theme.id {
            // Falls back rather than leaving the app pointing at nothing.
            selectedID = BuiltInThemes.system.id
        } else {
            rebuild()
        }
    }

    // MARK: - On disk

    /// `~/Library/Application Support/betterTextEdit/Themes`.
    var themesDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("betterTextEdit", isDirectory: true)
            .appendingPathComponent("Themes", isDirectory: true)
    }

    /// Opens the themes folder in the Finder, creating it first so there's
    /// always something to show.
    func revealThemesFolder() {
        let directory = themesDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([directory])
    }

    /// Re-reads the themes folder — for after someone has edited a file by hand.
    func reload() {
        imported = loadImported()
        rebuild()
    }

    private func loadImported() -> [EditorTheme] {
        let directory = themesDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let decoder = JSONDecoder()
        return files
            .filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(EditorTheme.self, from: data)
            }
    }
}
