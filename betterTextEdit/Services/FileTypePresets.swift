import Foundation
import SwiftUI

// Per-language overrides: "Markdown in Georgia at 15pt on Cherry Sakura, but
// leave everything else alone."
//
// Every field is optional, and that's the whole design. A preset says only what
// it wants changed; anything it doesn't mention falls through to the setting in
// General or Appearance. So a preset that names a font is a preset about fonts,
// and it keeps working when the theme is changed elsewhere.
//
// Presets are matched on `FileLanguage`, not on file extension, because the
// language is already what the editor reasons in — it's what the highlighter
// switches on, what the status bar shows, and what the user can override by
// hand there. Matching extensions instead would mean a preset for `.js` that
// missed `.mjs`.

struct FileTypePreset: Identifiable, Hashable, Codable {
    var id: UUID
    var language: FileLanguage

    /// The id of a theme, or `nil` to keep whichever is chosen globally.
    var themeID: String?
    /// A font family name, `""` for the system monospaced face, or `nil` to
    /// leave the font alone.
    var fontName: String?
    var fontSize: Double?
    var lineSpacing: Double?
    var wordWrap: Bool?

    init(
        id: UUID = UUID(),
        language: FileLanguage,
        themeID: String? = nil,
        fontName: String? = nil,
        fontSize: Double? = nil,
        lineSpacing: Double? = nil,
        wordWrap: Bool? = nil
    ) {
        self.id = id
        self.language = language
        self.themeID = themeID
        self.fontName = fontName
        self.fontSize = fontSize
        self.lineSpacing = lineSpacing
        self.wordWrap = wordWrap
    }

    /// True when the preset would change nothing — worth telling the user,
    /// since an empty preset looks like a broken one.
    var isEmpty: Bool {
        themeID == nil && fontName == nil && fontSize == nil && lineSpacing == nil && wordWrap == nil
    }
}

/// The presets, and the lookup the rest of the app does against them.
@MainActor
final class PresetStore: ObservableObject {
    static let shared = PresetStore()

    /// Loaded as the property's default value rather than assigned in `init`,
    /// and that distinction is load-bearing.
    ///
    /// `didSet` below reaches for `ThemeStore.shared`, and `ThemeStore`'s own
    /// initialiser reaches back here through `effective`. Assigning inside
    /// `init` fires `didSet` — Swift only skips observers for the *default*
    /// value, not for a later assignment in the initialiser body — so the two
    /// stores would each end up waiting on the other's `dispatch_once` and the
    /// app would hang on launch. It only bit once a preset had actually been
    /// saved, since the old code returned early when there was nothing to load.
    ///
    /// A default value never triggers an observer, so loading here breaks the
    /// cycle outright rather than relying on ordering.
    @Published private(set) var presets: [FileTypePreset] = PresetStore.stored() {
        didSet {
            save()
            // A preset can name a theme, so changing one may have just changed
            // the theme in force.
            ThemeStore.shared.presetsChanged()
        }
    }

    private static let storageKey = "presets.fileTypes"

    private init() {}

    /// What was saved last time, or nothing at all.
    private static func stored() -> [FileTypePreset] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([FileTypePreset].self, from: data)
        else { return [] }
        return decoded
    }

    /// The preset for a language, if there is one.
    ///
    /// First match wins rather than merging several, so the list stays a list of
    /// answers rather than a pile of layers whose order you'd have to reason
    /// about. Adding a second preset for a language is prevented at the point of
    /// adding instead.
    func preset(for language: FileLanguage?) -> FileTypePreset? {
        guard let language else { return nil }
        return presets.first { $0.language == language }
    }

    /// The languages that don't have a preset yet — what the "add" menu offers.
    var unusedLanguages: [FileLanguage] {
        FileLanguage.selectable.filter { language in
            !presets.contains { $0.language == language }
        }
    }

    func add(_ language: FileLanguage) {
        guard !presets.contains(where: { $0.language == language }) else { return }
        presets.append(FileTypePreset(language: language))
    }

    func update(_ preset: FileTypePreset) {
        guard let index = presets.firstIndex(where: { $0.id == preset.id }) else { return }
        presets[index] = preset
    }

    func remove(_ preset: FileTypePreset) {
        presets.removeAll { $0.id == preset.id }
    }

    /// A binding to one preset, so a row can edit it in place.
    func binding(for preset: FileTypePreset) -> Binding<FileTypePreset> {
        Binding(
            get: { [weak self] in
                self?.presets.first { $0.id == preset.id } ?? preset
            },
            set: { [weak self] updated in
                self?.update(updated)
            }
        )
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}

// MARK: - Resolving

/// The settings actually in force for the document on screen: the globals, with
/// any preset for its language laid over the top.
///
/// One place where the fall-through happens, so the editor, the status bar, and
/// the settings preview can't disagree about what's in effect.
struct EffectiveEditorSettings {
    var fontName: String
    var fontSize: Double
    var lineSpacing: Double
    var wordWrap: Bool

    init(
        preset: FileTypePreset?,
        fontName: String,
        fontSize: Double,
        lineSpacing: Double,
        wordWrap: Bool
    ) {
        self.fontName = preset?.fontName ?? fontName
        self.fontSize = preset?.fontSize ?? fontSize
        self.lineSpacing = preset?.lineSpacing ?? lineSpacing
        self.wordWrap = preset?.wordWrap ?? wordWrap
    }
}
