import AppKit
import SwiftUI

// The colour model behind betterTextEdit's themes.
//
// A theme is a flat table of hex colours keyed by role. That's deliberately the
// shape a VS Code theme boils down to once its TextMate scopes are resolved,
// which is what makes importing one a mapping job rather than a translation.
//
// Nothing in `EditorTheme` paints. It's the storable form — Codable, hand-
// editable JSON. `ResolvedTheme` is the painting form: the same table with the
// hex turned into `NSColor`s and every gap filled in, so the highlighter and the
// editor can ask for any role and always get a colour back.

// MARK: - Roles

/// Every colour betterTextEdit knows how to use.
///
/// Kept small on purpose. A theme file out in the world names hundreds of
/// things; almost all of them describe chrome this app doesn't have. These are
/// the ones that change what you actually see while editing.
enum ThemeRole: String, CaseIterable, Codable, Sendable {
    // The canvas.
    case background
    case foreground
    case caret
    case selection
    case currentLine
    case gutterBackground
    case gutterForeground
    case gutterActiveForeground
    case separator
    case accent

    // Syntax.
    case keyword
    case string
    case comment
    case number
    case type
    case function
    case variable
    case constant
    case `operator`
    case punctuation
    case attribute
    case tag
    case heading
    case link

    /// Where a role looks when the theme doesn't name it, tried in order.
    ///
    /// This is what lets a theme be as sparse as a background and a foreground
    /// and still paint something sensible — and it's what catches the imported
    /// theme that simply has no opinion about, say, operators. The lists are
    /// walked flat rather than recursively, so a pair that points at each other
    /// (number ↔ constant) can't spin.
    var fallbacks: [ThemeRole] {
        switch self {
        case .background, .foreground: []
        case .caret: [.accent, .foreground]
        case .accent: [.keyword, .foreground]
        // Derived from the canvas rather than borrowed — see `ResolvedTheme`.
        case .selection, .currentLine, .gutterForeground, .separator: []
        case .gutterBackground: [.background]
        case .gutterActiveForeground: [.foreground]
        case .keyword, .string, .comment, .type, .variable, .punctuation: [.foreground]
        case .number: [.constant, .foreground]
        case .constant: [.number, .foreground]
        case .function: [.type, .foreground]
        case .operator: [.keyword, .foreground]
        case .attribute: [.type, .foreground]
        case .tag: [.keyword, .foreground]
        case .heading: [.keyword, .foreground]
        case .link: [.accent, .type, .foreground]
        }
    }
}

// MARK: - Token style

/// Bold, italic, underline — the three things a theme can say about a token
/// beyond its colour, and the three VS Code's `fontStyle` carries.
struct TokenStyle: OptionSet, Hashable, Codable, Sendable {
    let rawValue: Int

    init(rawValue: Int) { self.rawValue = rawValue }

    static let bold = TokenStyle(rawValue: 1 << 0)
    static let italic = TokenStyle(rawValue: 1 << 1)
    static let underline = TokenStyle(rawValue: 1 << 2)

    /// Parses VS Code's `fontStyle`: a space-separated list, where the empty
    /// string means "explicitly plain" rather than "unspecified".
    init(fontStyle: String) {
        var result: TokenStyle = []
        for word in fontStyle.lowercased().split(separator: " ") {
            switch word {
            case "bold": result.insert(.bold)
            case "italic": result.insert(.italic)
            case "underline": result.insert(.underline)
            default: break
            }
        }
        self = result
    }

    /// The same spelling back out, for the JSON we write.
    var fontStyle: String {
        var words: [String] = []
        if contains(.bold) { words.append("bold") }
        if contains(.italic) { words.append("italic") }
        if contains(.underline) { words.append("underline") }
        return words.joined(separator: " ")
    }
}

// MARK: - The stored theme

/// A theme as it lives on disk: names, a table of hex colours, and an optional
/// table of font styles.
struct EditorTheme: Identifiable, Hashable, Codable {
    var id: String
    var name: String
    var author: String
    /// Whether the theme wants dark window chrome around it. Imported themes
    /// that don't say get judged on the brightness of their background.
    var isDark: Bool
    var colors: [ThemeRole: String]
    var styles: [ThemeRole: TokenStyle]
    /// Built-ins ship with the app and can't be deleted; imports can.
    var isBuiltIn: Bool
    /// Only the System theme sets this. It paints with macOS's own semantic
    /// colours, so it follows the Light/Dark switch without a palette at all.
    var followsSystem: Bool

    init(
        id: String,
        name: String,
        author: String = "",
        isDark: Bool,
        colors: [ThemeRole: String],
        styles: [ThemeRole: TokenStyle] = [:],
        isBuiltIn: Bool = false,
        followsSystem: Bool = false
    ) {
        self.id = id
        self.name = name
        self.author = author
        self.isDark = isDark
        self.colors = colors
        self.styles = styles
        self.isBuiltIn = isBuiltIn
        self.followsSystem = followsSystem
    }

    func hex(_ role: ThemeRole) -> String? {
        colors[role]
    }

    // MARK: Codable

    // Hand-written so the JSON on disk is a plain `{"role": "#rrggbb"}` map —
    // the format someone would write by hand if they were making a theme in a
    // text editor, which is after all what this app is.

    private enum CodingKeys: String, CodingKey {
        case id, name, author, isDark, colors, styles, isBuiltIn
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let identifier = try container.decode(String.self, forKey: .id)
        id = identifier
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? identifier
        author = try container.decodeIfPresent(String.self, forKey: .author) ?? ""

        let rawColors = try container.decodeIfPresent([String: String].self, forKey: .colors) ?? [:]
        var parsed: [ThemeRole: String] = [:]
        for (key, value) in rawColors {
            if let role = ThemeRole(rawValue: key) { parsed[role] = value }
        }
        colors = parsed

        let rawStyles = try container.decodeIfPresent([String: String].self, forKey: .styles) ?? [:]
        var parsedStyles: [ThemeRole: TokenStyle] = [:]
        for (key, value) in rawStyles {
            if let role = ThemeRole(rawValue: key) { parsedStyles[role] = TokenStyle(fontStyle: value) }
        }
        styles = parsedStyles

        // A theme that doesn't declare its mood is judged on its background —
        // the same call VS Code's own `type` field is making.
        if let declared = try container.decodeIfPresent(Bool.self, forKey: .isDark) {
            isDark = declared
        } else {
            let background = parsed[.background].flatMap { NSColor(themeHex: $0) }
            isDark = (background?.relativeLuminance ?? 0) < 0.5
        }

        // Anything read off disk is an import, whatever the file claims.
        isBuiltIn = false
        followsSystem = false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        if !author.isEmpty { try container.encode(author, forKey: .author) }
        try container.encode(isDark, forKey: .isDark)
        try container.encode(
            Dictionary(uniqueKeysWithValues: colors.map { ($0.key.rawValue, $0.value) }),
            forKey: .colors
        )
        if !styles.isEmpty {
            try container.encode(
                Dictionary(uniqueKeysWithValues: styles.map { ($0.key.rawValue, $0.value.fontStyle) }),
                forKey: .styles
            )
        }
    }
}

// MARK: - The painting form

/// A theme with every role resolved to an `NSColor` — no optionals, no lookups
/// that can fail. Built once when the theme changes and then handed around.
struct ResolvedTheme: Equatable {
    let id: String
    let name: String
    let isDark: Bool
    /// True only for the System theme. Everything that has to decide between
    /// "paint the theme" and "let macOS paint" asks this.
    let followsSystem: Bool

    let background: NSColor
    let foreground: NSColor
    let caret: NSColor
    let selection: NSColor
    let currentLine: NSColor
    let gutterBackground: NSColor
    let gutterForeground: NSColor
    let gutterActiveForeground: NSColor
    let separator: NSColor
    let accent: NSColor

    private let syntax: [ThemeRole: NSColor]
    private let styles: [ThemeRole: TokenStyle]

    func color(_ role: ThemeRole) -> NSColor {
        syntax[role] ?? foreground
    }

    func style(_ role: ThemeRole) -> TokenStyle {
        styles[role] ?? []
    }

    /// What to wash the window with, behind and around the editor.
    ///
    /// Under the System theme that's the window colour macOS uses for chrome,
    /// not the brighter one it uses for text — the app looked right that way
    /// before themes existed and should still. A chosen theme has one canvas
    /// colour and uses it everywhere.
    var windowBackground: NSColor {
        followsSystem ? .windowBackgroundColor : background
    }

    /// The faint deepening that sets chrome back from the editor canvas — the
    /// file browser, and the band the tabs sit on.
    ///
    /// One definition, used by both, so the two regions can't drift apart. It's
    /// derived from the theme's own canvas rather than picked, which is what
    /// keeps it inside whatever palette is in force instead of introducing a
    /// grey the theme never asked for. The System theme has no canvas colour to
    /// deepen with, so it gets a neutral wash that follows Light and Dark.
    var recess: Color {
        followsSystem ? Color.primary.opacity(0.05) : backgroundColor.opacity(0.22)
    }

    /// The hairline that ends a recessed region — under the tabs, beside the
    /// file browser.
    var edge: Color {
        followsSystem ? Color(nsColor: .separatorColor) : Color(nsColor: separator).opacity(0.8)
    }

    // SwiftUI-side conveniences, so views don't each write the bridge.
    var backgroundColor: Color { Color(nsColor: background) }
    var windowBackgroundColor: Color { Color(nsColor: windowBackground) }
    var foregroundColor: Color { Color(nsColor: foreground) }
    var accentColor: Color { Color(nsColor: accent) }
    func swiftUIColor(_ role: ThemeRole) -> Color { Color(nsColor: color(role)) }

    // MARK: Building

    init(_ theme: EditorTheme) {
        id = theme.id
        name = theme.name
        isDark = theme.isDark
        followsSystem = theme.followsSystem

        if theme.followsSystem {
            // macOS's own colours, which are already dynamic: they re-resolve
            // themselves when the appearance changes, so the System theme
            // follows the Light/Dark switch with no work from us.
            background = .textBackgroundColor
            foreground = .textColor
            caret = .controlAccentColor
            selection = .selectedTextBackgroundColor
            currentLine = SystemPalette.currentLine
            gutterBackground = .textBackgroundColor
            gutterForeground = .tertiaryLabelColor
            gutterActiveForeground = .secondaryLabelColor
            separator = .separatorColor
            accent = .controlAccentColor
            syntax = SystemPalette.syntax
            styles = [:]
            return
        }

        let resolve = { (role: ThemeRole) -> NSColor? in
            for candidate in [role] + role.fallbacks {
                if let hex = theme.colors[candidate], let color = NSColor(themeHex: hex) {
                    return color
                }
            }
            return nil
        }

        // The two roles with no fallback of their own — every derived colour
        // below is measured against these.
        let canvas = resolve(.background) ?? (theme.isDark ? .black : .white)
        let ink = resolve(.foreground) ?? (theme.isDark ? .white : .black)
        background = canvas
        foreground = ink

        let tint = resolve(.accent) ?? ink
        accent = tint
        caret = resolve(.caret) ?? tint

        // The four that are derived rather than borrowed. Lifting the canvas
        // towards the ink keeps them in the theme's own family: a highlight on
        // Solarized Light stays warm, and one on Tokyo Midnight stays blue.
        selection = resolve(.selection) ?? tint.withAlphaComponent(0.3)
        currentLine = resolve(.currentLine) ?? canvas.blended(towards: ink, by: 0.07)
        separator = resolve(.separator) ?? canvas.blended(towards: ink, by: 0.22)
        gutterBackground = resolve(.gutterBackground) ?? canvas
        gutterForeground = resolve(.gutterForeground) ?? canvas.blended(towards: ink, by: 0.45)
        gutterActiveForeground = resolve(.gutterActiveForeground) ?? ink

        var table: [ThemeRole: NSColor] = [:]
        for role in ThemeRole.allCases {
            table[role] = resolve(role) ?? ink
        }
        // The canvas roles were just derived above; put those answers in the
        // table too, so `color(_:)` and the named properties never disagree.
        table[.background] = canvas
        table[.foreground] = ink
        table[.accent] = tint
        table[.caret] = caret
        table[.selection] = selection
        table[.currentLine] = currentLine
        table[.separator] = separator
        table[.gutterBackground] = gutterBackground
        table[.gutterForeground] = gutterForeground
        table[.gutterActiveForeground] = gutterActiveForeground
        syntax = table
        styles = theme.styles
    }

    // Themes are swapped, not mutated, so identity plus a cheap content check is
    // enough to tell SwiftUI whether the editor needs repainting.
    static func == (lhs: ResolvedTheme, rhs: ResolvedTheme) -> Bool {
        lhs.id == rhs.id
            && lhs.background == rhs.background
            && lhs.foreground == rhs.foreground
            && lhs.syntax == rhs.syntax
            && lhs.styles == rhs.styles
    }
}

/// The colours the System theme paints with: the ones the app used before
/// themes existed, kept exactly as they were.
///
/// Held as statics so the dynamic `NSColor`s are created once. That matters for
/// `ResolvedTheme`'s equality — a fresh `NSColor(name:)` is never equal to
/// another, which would have the editor repainting itself on every update.
private enum SystemPalette {
    static let keyword = dynamic(dark: "#c785ff", light: "#8c29b8")
    static let string = dynamic(dark: "#f59e7a", light: "#b8291f")
    static let comment = dynamic(dark: "#73b87a", light: "#387b40")
    static let number = dynamic(dark: "#8fb8ff", light: "#2456c2")
    static let type = dynamic(dark: "#7ad6e0", light: "#057b8a")
    static let function = dynamic(dark: "#8fb8ff", light: "#2456c2")
    static let currentLine = dynamic(dark: "#ffffff14", light: "#00000008")

    static let syntax: [ThemeRole: NSColor] = {
        var table: [ThemeRole: NSColor] = [:]
        for role in ThemeRole.allCases {
            table[role] = NSColor.textColor
        }
        table[.keyword] = keyword
        table[.string] = string
        table[.comment] = comment
        table[.number] = number
        table[.constant] = number
        table[.type] = type
        table[.function] = function
        table[.attribute] = type
        table[.tag] = keyword
        table[.heading] = keyword
        table[.operator] = keyword
        table[.link] = type
        table[.accent] = NSColor.controlAccentColor
        return table
    }()

    private static func dynamic(dark: String, light: String) -> NSColor {
        let darkColor = NSColor(themeHex: dark) ?? .textColor
        let lightColor = NSColor(themeHex: light) ?? .textColor
        return NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? darkColor : lightColor
        }
    }
}

// MARK: - Hex

extension NSColor {
    /// Parses `#rgb`, `#rgba`, `#rrggbb`, and `#rrggbbaa` — the four spellings a
    /// VS Code theme uses, with or without the leading hash.
    convenience init?(themeHex hex: String) {
        var digits = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if digits.hasPrefix("#") { digits.removeFirst() }
        guard [3, 4, 6, 8].contains(digits.count),
              digits.allSatisfy(\.isHexDigit),
              let value = UInt64(digits, radix: 16)
        else { return nil }

        // The short forms repeat each digit: #1a3 is #11aa33.
        let expanded: UInt64
        let count: Int
        if digits.count <= 4 {
            var wide: UInt64 = 0
            for position in 0 ..< digits.count {
                let place = UInt64(digits.count - 1 - position)
                let nibble = (value >> (place * 4)) & 0xF
                wide |= (nibble << 4 | nibble) << (place * 8)
            }
            expanded = wide
            count = digits.count * 2
        } else {
            expanded = value
            count = digits.count
        }

        let hasAlpha = count == 8
        let shift = hasAlpha ? 8 : 0
        let red = CGFloat((expanded >> UInt64(16 + shift)) & 0xFF) / 255
        let green = CGFloat((expanded >> UInt64(8 + shift)) & 0xFF) / 255
        let blue = CGFloat((expanded >> UInt64(shift)) & 0xFF) / 255
        let alpha = hasAlpha ? CGFloat(expanded & 0xFF) / 255 : 1

        self.init(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    /// `#rrggbb`, or `#rrggbbaa` when the colour isn't opaque.
    var themeHex: String {
        guard let srgb = usingColorSpace(.sRGB) else { return "#000000" }
        let red = Int((srgb.redComponent * 255).rounded())
        let green = Int((srgb.greenComponent * 255).rounded())
        let blue = Int((srgb.blueComponent * 255).rounded())
        let alpha = Int((srgb.alphaComponent * 255).rounded())
        if alpha >= 255 {
            return String(format: "#%02x%02x%02x", red, green, blue)
        }
        return String(format: "#%02x%02x%02x%02x", red, green, blue, alpha)
    }

    /// How bright the colour reads, 0...1 — the WCAG relative luminance. Used to
    /// tell a dark theme from a light one when the file doesn't say.
    var relativeLuminance: CGFloat {
        guard let srgb = usingColorSpace(.sRGB) else { return 0 }
        func linear(_ channel: CGFloat) -> CGFloat {
            channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(srgb.redComponent)
            + 0.7152 * linear(srgb.greenComponent)
            + 0.0722 * linear(srgb.blueComponent)
    }

    /// A mix of two colours in sRGB. `blended(withFraction:of:)` refuses across
    /// mismatched colour spaces, and the colours here come from four different
    /// places, so both sides are converted first.
    func blended(towards other: NSColor, by fraction: CGFloat) -> NSColor {
        guard let base = usingColorSpace(.sRGB), let target = other.usingColorSpace(.sRGB) else { return self }
        return base.blended(withFraction: fraction, of: target) ?? self
    }
}
