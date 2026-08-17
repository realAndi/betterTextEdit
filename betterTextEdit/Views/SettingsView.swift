import AppKit
import SwiftUI

// betterTextEdit's Settings (⌘,), which opens as a tab in the window rather
// than a panel over it.
//
// Everything here writes to the same `@AppStorage` keys the editor already
// reads, so a change takes effect the moment it's made — no apply button, the
// way a Mac settings pane is expected to behave. That matters more here than in
// a panel: most of what's below changes how the window looks, and the window is
// right there behind it.

// MARK: - Storage keys

enum SettingsKey {
    static let fontName = "settings.fontName"
    static let fontSize = "editor.fontSize"
    static let wordWrap = "editor.wordWrap"
    /// Legacy. Superseded by `windowSurface`, and read exactly once — by the
    /// migration that carries its answer across.
    static let translucent = "editor.translucent"
    /// Solid, Glass, or Clear — see `WindowSurface`.
    static let windowSurface = "window.surface"
    static let appearance = "settings.appearance"
    /// The id of the chosen editor theme — see `ThemeStore`.
    static let themeID = "theme.id"
    static let sidebarVisible = "sidebar.visible"
    static let pdfZoom = "editor.pdfZoom"
    static let imageZoom = "image.zoom"
    static let previewJavaScript = "preview.javaScript"
    /// How strongly the glass is tinted towards the window colour — 0 leaves it
    /// alone, up towards 1 saturates it. Kept below 1 so it never turns fully
    /// solid; that's what the Solid surface is for.
    static let glassOpacity = "glass.opacity"
    /// Whether the line-number gutter is drawn at all.
    static let showLineNumbers = "editor.showLineNumbers"
    /// Extra leading between lines in the code editor, in points.
    static let lineSpacing = "editor.lineSpacing"
    /// Whether a band is drawn behind the line the caret is on.
    static let highlightCurrentLine = "editor.highlightCurrentLine"
    /// Whether the theme's accent drives the window's controls, or the one the
    /// user chose in System Settings does.
    static let themeAccent = "appearance.themeAccent"
}

/// The strongest the tint is allowed to get. Left a little short of solid so
/// even "most opaque" keeps some depth.
let maximumGlassOpacity = 0.9

// MARK: - The window's surface

/// What the window's canvas is made of.
///
/// A picker rather than a translucency switch, because macOS offers several
/// genuinely different ways for a window to be see-through and they aren't
/// points on one scale. Two are Liquid Glass; two aren't.
enum WindowSurface: String, CaseIterable, Identifiable {
    /// The theme's background, painted. No desktop at all.
    case solid
    /// `NSGlassEffectView` at `.regular`: frosted glass, tinted by the theme.
    case glass
    /// `NSGlassEffectView` at `.clear`: barely there, but still refracting.
    case clear
    /// `NSVisualEffectView`'s behind-window material — the blur macOS had
    /// before Liquid Glass. Flatter and softer: it smears what's behind the
    /// window without bending or catching light on it.
    case blur
    /// No material at all. The desktop shows through sharp, dimmed only by the
    /// tint — and with the tint down, not dimmed at all.
    case sheer

    var id: String { rawValue }

    var label: String {
        switch self {
        case .solid: "Solid"
        case .glass: "Glass"
        case .clear: "Clear"
        case .blur: "Blur"
        case .sheer: "Sheer"
        }
    }

    var explanation: String {
        switch self {
        case .solid: "A painted background. The desktop behind the window doesn’t show at all."
        case .glass: "Frosted Liquid Glass. What’s behind the window shows through, softened."
        case .clear: "Clear Liquid Glass. Barely there, but still refracting what’s behind it."
        case .blur: "The classic behind-window blur, without Liquid Glass. Flatter, and it stays put."
        case .sheer: "No material at all — colour over a sharp desktop. Tint down for a fully transparent window."
        }
    }

    /// True when anything of the desktop comes through — which is the question
    /// every view that has to decide whether to paint a background is asking.
    var isTranslucent: Bool { self != .solid }

    /// Whether a theme's tint keeps its floor here.
    ///
    /// The surfaces with a material behind them get it: their job is to be a
    /// canvas, and a canvas the theme has faded out of isn't one. Clear and
    /// Sheer are both someone asking to see through the window, so they take
    /// the dial at its word all the way down to nothing.
    var keepsThemeFloor: Bool {
        self == .glass || self == .blur
    }
}

/// Carries settings across a change in what they mean.
enum SettingsMigration {
    /// The Translucent switch became a three-way choice. Its old answer is
    /// copied over once so nobody's window changes under them on upgrade.
    @MainActor
    static func run(in defaults: UserDefaults = .standard) {
        guard defaults.object(forKey: SettingsKey.windowSurface) == nil else { return }
        let wasTranslucent = defaults.object(forKey: SettingsKey.translucent) as? Bool ?? true
        let surface: WindowSurface = wasTranslucent ? .glass : .solid
        defaults.set(surface.rawValue, forKey: SettingsKey.windowSurface)
    }
}

/// The least of itself a chosen theme washes over the glass.
///
/// A theme can't be allowed to fade to nothing behind a glass window. Its
/// syntax colours were picked to sit on its own canvas, and with no canvas at
/// all they'd be sitting on whatever happens to be on the desktop. This is the
/// floor that keeps a theme legible while still leaving the glass clearly
/// glass.
///
/// It applies to Glass and to Glass only. Clear is someone asking, in as many
/// words, for a see-through window; quietly frosting it would be refusing to
/// give them the thing they picked.
let minimumThemeWash = 0.55

/// How far to pull the glass towards the window's tint colour.
///
/// Under the System theme this is the Tint dial and nothing else — the app's
/// behaviour before themes existed, unchanged.
///
/// A chosen theme instead travels between that floor and the same maximum, so
/// the dial stays live across its whole length rather than being clamped flat
/// for the first two thirds.
///
/// The glass style doesn't enter into it. Clear glass skips the floor entirely
/// rather than compensating for it — see `minimumThemeWash`.
func themeWash(tint: Double, theme: ResolvedTheme) -> Double {
    guard !theme.followsSystem else { return tint }

    // Defensive: `@AppStorage` hands back whatever is on disk, including a
    // value written by an older build or edited by hand.
    let dial = Swift.min(Swift.max(tint, 0), maximumGlassOpacity)
    return minimumThemeWash + dial / maximumGlassOpacity * (maximumGlassOpacity - minimumThemeWash)
}

// MARK: - Appearance

/// Light, Dark, or follow the system — the three states macOS itself offers.
/// Glass (translucency) is kept separate, as a property that sits on top of any
/// of these, so a dark-glass or light-glass window is possible.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

// Applying an appearance now belongs to `ThemeStore`, because the answer
// depends on the theme as well as on this setting: "System" means *follow the
// theme* whenever a theme has been picked, and only falls back to the macOS
// setting under the System theme. See `ThemeStore.applyAppearance()`.

// MARK: - Fonts

/// The fonts offered for the editor.
///
/// Rather than the full system font list — thousands of faces, most of them
/// useless for code — this is a short, curated set, filtered down to the ones
/// actually installed so the menu never offers a font that isn't there. The
/// empty string is the default: the system monospaced face (SF Mono).
enum EditorFonts {
    static let systemMonospaced = ""

    private static let candidates = [
        "Menlo",
        "Monaco",
        "SF Mono",
        "Courier New",
        "Andale Mono",
        "PT Mono",
        "Fira Code",
        "JetBrains Mono",
        "Source Code Pro",
        "IBM Plex Mono",
        "Cascadia Code",
        // A few proportional faces, for prose and Markdown.
        "Helvetica Neue",
        "Georgia",
        "Times New Roman",
    ]

    /// The candidates that are actually installed, in the order above.
    static let available: [String] = candidates.filter { NSFont(name: $0, size: 12) != nil }

    /// Resolves a stored name to a usable font, falling back to the system
    /// monospaced face for the default (or a name that's since been uninstalled).
    static func font(named name: String, size: CGFloat) -> NSFont {
        if !name.isEmpty, let font = NSFont(name: name, size: size) {
            return font
        }
        return .monospacedSystemFont(ofSize: size, weight: .regular)
    }
}

/// The curated font menu, shared by the Settings window and the toolbar's "AA"
/// popover so the two always offer the same list.
struct EditorFontPicker: View {
    @AppStorage(SettingsKey.fontName) private var fontName = EditorFonts.systemMonospaced

    var body: some View {
        Picker("Font", selection: $fontName) {
            Text("System Monospaced").tag(EditorFonts.systemMonospaced)
            if !EditorFonts.available.isEmpty {
                Divider()
                ForEach(EditorFonts.available, id: \.self) { name in
                    Text(name).tag(name)
                }
            }
        }
    }
}

// MARK: - The pane

/// What Settings is divided into.
enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case themes
    case appearance
    case fileTypes

    var id: String { rawValue }

    var label: String {
        switch self {
        case .general: "General"
        case .themes: "Themes"
        case .appearance: "Appearance"
        case .fileTypes: "File Types"
        }
    }

    var symbol: String {
        switch self {
        case .general: "textformat"
        case .themes: "swatchpalette"
        case .appearance: "paintpalette"
        case .fileTypes: "doc.badge.gearshape"
        }
    }
}

/// Settings, as a pane in the window rather than a panel over it.
///
/// A list down the side rather than a `TabView` across the top: a tab bar is
/// for a panel, and this isn't one — it has the whole window's width to work
/// with, and the list reads as part of the app the way a row of tab buttons
/// floating in the middle of the canvas never could.
///
/// Nothing here paints a surface of its own beyond the list's recess. The forms
/// have their scroll backgrounds hidden so the window's canvas — glass, blur,
/// or the theme's colour — runs underneath the whole pane.
struct SettingsView: View {
    @ObservedObject private var themes = ThemeStore.shared
    @State private var section: SettingsSection = .general

    var body: some View {
        HStack(spacing: 0) {
            sections

            Rectangle()
                .fill(themes.current.edge)
                .frame(width: 1)

            detail
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The same recess and hairline as the file browser, so the two panels in
    /// the window are plainly the same kind of thing.
    private var sections: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsSection.allCases) { candidate in
                SettingsSectionRow(
                    section: candidate,
                    selected: candidate == section,
                    select: { section = candidate }
                )
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 12)
        .frame(width: 184)
        .background(themes.current.recess)
    }

    @ViewBuilder
    private var detail: some View {
        Group {
            switch section {
            case .general: GeneralSettings()
            case .themes: ThemeSettings()
            case .appearance: AppearanceSettings()
            case .fileTypes: PresetSettings()
            }
        }
        // Held to a readable column so a wide window doesn't stretch a form
        // across two feet of screen, but leading-aligned rather than centred,
        // so it stays anchored to the list it belongs to.
        .frame(maxWidth: 720, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The frame every settings section sits in: a scrolling column with no surface
/// of its own, so the window's canvas runs underneath it.
///
/// Hand-laid rather than a `Form`. Grouped forms draw each section as a card on
/// an opaque backing, which over glass reads as a stack of grey slabs; the
/// columns style is flat but right-aligns its labels into a gutter, so rows
/// drift away from the left edge by however long the longest label happens to
/// be. Everything below is left-aligned to one margin instead, and every row is
/// the same shape: title, an optional line of explanation, then the control.
struct SettingsPage<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                content
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}

/// A named run of settings.
struct SettingsGroup<Content: View>: View {
    private let title: String
    private let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.caption)
                .fontWeight(.semibold)
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
                .kerning(0.6)

            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One setting: what it is, what it does, and the control that changes it.
struct SettingsRow<Control: View>: View {
    private let title: String
    private let caption: String
    private let control: Control

    init(_ title: String, caption: String = "", @ViewBuilder control: () -> Control) {
        self.title = title
        self.caption = caption
        self.control = control()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            SettingsLabel(title: title, caption: caption)
            control
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A setting whose control is a switch.
///
/// The switch goes on the trailing edge rather than under the title, because a
/// row that's only a switch reads better as one line than as two — and it's
/// what System Settings does.
struct SettingsToggle: View {
    private let title: String
    private let caption: String
    @Binding private var isOn: Bool

    init(_ title: String, caption: String = "", isOn: Binding<Bool>) {
        self.title = title
        self.caption = caption
        _isOn = isOn
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            SettingsLabel(title: title, caption: caption)
            Spacer(minLength: 0)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The title-and-explanation pair every row starts with.
private struct SettingsLabel: View {
    let title: String
    var caption: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .fontWeight(.medium)
            if !caption.isEmpty {
                Text(caption)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // Explanations wrap rather than stretching the window: past this the
        // eye has to travel too far back to find the next line.
        .frame(maxWidth: 520, alignment: .leading)
    }
}

private struct SettingsSectionRow: View {
    let section: SettingsSection
    let selected: Bool
    let select: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: section.symbol)
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                .frame(width: 18)
            Text(section.label)
                .fontWeight(selected ? .medium : .regular)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(rowBackground)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
    }

    private var rowBackground: Color {
        if selected { return Color.accentColor.opacity(0.22) }
        return hovering ? Color.primary.opacity(0.06) : .clear
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @AppStorage(SettingsKey.fontName) private var fontName = EditorFonts.systemMonospaced
    @AppStorage(SettingsKey.fontSize) private var fontSize = EditorMetrics.defaultFontSize
    @AppStorage(SettingsKey.wordWrap) private var wordWrap = false

    var body: some View {
        SettingsPage {
            SettingsGroup("Editor Font") {
                SettingsRow("Typeface", caption: "The face the code editor uses. A file type can ask for a different one in Appearance.") {
                    EditorFontPicker()
                        .labelsHidden()
                        .frame(width: 260)
                }

                SettingsRow("Size") {
                    HStack(spacing: 12) {
                        Slider(
                            value: $fontSize,
                            in: EditorMetrics.minimumFontSize ... EditorMetrics.maximumFontSize,
                            step: 1
                        )
                        .frame(width: 220)
                        Stepper(
                            "\(Int(fontSize)) pt",
                            value: $fontSize,
                            in: EditorMetrics.minimumFontSize ... EditorMetrics.maximumFontSize,
                            step: 1
                        )
                        .monospacedDigit()
                        .fixedSize()
                    }
                }

                SettingsRow("Preview") {
                    FontSample(fontName: fontName, size: fontSize)
                }
            }

            SettingsGroup("Editing") {
                SettingsToggle(
                    "Wrap long lines",
                    caption: "Break lines at the window's edge instead of scrolling sideways.",
                    isOn: $wordWrap
                )
            }

            UpdateSettings()
        }
    }
}

/// The updates group, at the foot of General.
///
/// Sparkle already has a "Check for Updates…" item in the app menu, but the
/// switch that decides whether it happens on its own has to live somewhere a
/// person would look for it — and this is where every other preference is.
private struct UpdateSettings: View {
    @ObservedObject private var updater = UpdaterService.shared

    var body: some View {
        SettingsGroup("Updates") {
            SettingsToggle(
                "Check for updates automatically",
                caption: "Look for a new version once a day. You'll be asked before anything is installed.",
                isOn: Binding(
                    get: { updater.checksAutomatically },
                    set: { updater.checksAutomatically = $0 }
                )
            )

            SettingsRow("Version", caption: "You're running betterTextEdit \(updater.versionDescription).") {
                Button("Check Now") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
        }
    }
}

/// A live line of code shown in whatever font and size is picked, so the choice
/// can be judged before leaving the window.
private struct FontSample: View {
    let fontName: String
    let size: Double

    var body: some View {
        Text("func greet(_ name: String) { print(\"Hi, \\(name)\") }")
            .font(Font(EditorFonts.font(named: fontName, size: CGFloat(size))))
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(9)
            .frame(maxWidth: 520, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(ThemeStore.shared.current.backgroundColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(ThemeStore.shared.current.edge)
            )
    }
}

// MARK: - Appearance

private struct AppearanceSettings: View {
    var body: some View {
        SettingsPage {
            SettingsGroup("Window") { WindowAppearanceControls() }
            SettingsGroup("Editor") { EditorAppearanceControls() }
            SettingsGroup("Controls") { ControlAppearanceControls() }
        }
    }
}

/// How the editor itself is laid out — the things that change what a page of
/// code looks like without changing a single colour.
private struct EditorAppearanceControls: View {
    @AppStorage(SettingsKey.showLineNumbers) private var showLineNumbers = true
    @AppStorage(SettingsKey.highlightCurrentLine) private var highlightCurrentLine = true
    @AppStorage(SettingsKey.lineSpacing) private var lineSpacing = EditorMetrics.defaultLineSpacing

    var body: some View {
        SettingsToggle(
            "Show line numbers",
            caption: "The gutter down the left of the editor.",
            isOn: $showLineNumbers
        )

        SettingsToggle(
            "Highlight the current line",
            caption: "A band behind the line the caret is on, in the theme’s own colour. "
                + "It steps aside while there’s a selection.",
            isOn: $highlightCurrentLine
        )

        SettingsRow("Line spacing", caption: "How much air sits between lines. The font size is in General.") {
            HStack(spacing: 12) {
                Slider(
                    value: $lineSpacing,
                    in: EditorMetrics.minimumLineSpacing ... EditorMetrics.maximumLineSpacing,
                    step: 0.5
                )
                .frame(width: 220)
                Text(spacingLabel)
                    .foregroundStyle(.secondary)
                    .frame(width: 70, alignment: .leading)
            }
        }
    }

    /// A word rather than a number: nobody chooses leading in points, they
    /// choose how dense they want the page to feel.
    private var spacingLabel: String {
        switch lineSpacing {
        case ..<1: "Tight"
        case ..<4: "Normal"
        case ..<7.5: "Relaxed"
        default: "Airy"
        }
    }
}

/// What colours the window's own controls.
private struct ControlAppearanceControls: View {
    @ObservedObject private var themes = ThemeStore.shared
    @AppStorage(SettingsKey.themeAccent) private var themeAccent = true

    var body: some View {
        SettingsToggle("Use the theme’s accent colour", caption: explanation, isOn: $themeAccent)
            .disabled(themes.current.followsSystem)
    }

    private var explanation: String {
        themes.current.followsSystem
            ? "The System theme has no accent of its own, so this follows System Settings either way."
            : "Colours buttons, pickers, and focus rings with \(themes.current.name) instead of the "
                + "accent from System Settings."
    }
}

/// The window rows — Light/Dark/System, the surface, and the tint dial. Window
/// appearance lives here and only here; the toolbar's "AA" popover sticks to
/// per-document view options.
struct WindowAppearanceControls: View {
    @ObservedObject private var themes = ThemeStore.shared
    @AppStorage(SettingsKey.appearance) private var appearanceRaw = AppearanceMode.system.rawValue
    @AppStorage(SettingsKey.windowSurface) private var surfaceRaw = WindowSurface.glass.rawValue
    @AppStorage(SettingsKey.glassOpacity) private var glassOpacity = 0.0

    private var appearance: Binding<AppearanceMode> {
        Binding(
            get: { AppearanceMode(rawValue: appearanceRaw) ?? .system },
            set: { appearanceRaw = $0.rawValue }
        )
    }

    private var surface: Binding<WindowSurface> {
        Binding(
            get: { WindowSurface(rawValue: surfaceRaw) ?? .glass },
            set: { surfaceRaw = $0.rawValue }
        )
    }

    /// True when a theme is supplying the window's colour *and* the surface is
    /// one that keeps a floor under it.
    private var tintFloorApplies: Bool {
        !themes.current.followsSystem && surface.wrappedValue.keepsThemeFloor
    }

    private var tintCaption: String {
        if tintFloorApplies {
            return "How much of \(themes.current.name) the window carries. A theme keeps a little "
                + "whatever this says, so its colours stay readable over the desktop. Clear and "
                + "Sheer don’t hold anything back."
        }
        if !surface.wrappedValue.isTranslucent {
            return "A solid window is already all colour, so there’s nothing here to set."
        }
        return "How much colour is laid over what’s behind the window. All the way down leaves "
            + "nothing between the text and the desktop but the surface itself."
    }

    var body: some View {
        SettingsRow(
            "Appearance",
            caption: "“System” follows the theme you’ve chosen; Light and Dark override it."
        ) {
            Picker("", selection: appearance) {
                ForEach(AppearanceMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 280)
        }

        SettingsRow("Window", caption: surface.wrappedValue.explanation) {
            Picker("", selection: surface) {
                ForEach(WindowSurface.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 420)
        }

        // No blur dial anywhere. Neither glass nor the behind-window material
        // exposes an amount, and mixing a blurred copy in over a sharp one is a
        // different thing wearing the word’s clothes. The Window picker above is
        // the whole of the choice.

        SettingsRow("Tint", caption: tintCaption) {
            HStack(spacing: 10) {
                Image(systemName: "circle.dotted")
                    .foregroundStyle(.secondary)
                    .help(tintFloorApplies ? "As little as the theme allows" : "None")
                Slider(value: $glassOpacity, in: 0 ... maximumGlassOpacity)
                    .frame(width: 220)
                Image(systemName: "circle.fill")
                    .foregroundStyle(.secondary)
                    .help("Frosted")
            }
        }
        .disabled(surface.wrappedValue == .solid)

        Button("Reset Appearance") { glassOpacity = 0 }
            .disabled(!surface.wrappedValue.isTranslucent || glassOpacity == 0)
            .onChange(of: appearanceRaw) { _, _ in
                ThemeStore.shared.applyAppearance()
            }
    }
}
