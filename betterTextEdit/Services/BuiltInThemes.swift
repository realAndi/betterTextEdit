import Foundation

// The themes that ship with betterTextEdit.
//
// Each one is a full palette rather than a handful of accents on top of the
// system colours: a theme that only recolours keywords and leaves the canvas
// alone never actually looks like the thing it's named after. The set covers
// the families people already have in their editor — so importing a VS Code
// theme is for the ones that *aren't* here, not for the basics.
//
// The System theme is the odd one out and has no palette at all. It paints with
// macOS's own semantic colours, which is how it follows the Light/Dark switch.
//
// Each theme is its own declaration rather than an entry in one long array
// literal. Swift type-checks an array literal as a single expression, and two
// dozen palettes in one of those takes the compiler minutes.

enum BuiltInThemes {
    /// The default: macOS's colours, following Light/Dark on their own.
    static let system = EditorTheme(
        id: "system",
        name: "System",
        isDark: false,
        colors: [:],
        isBuiltIn: true,
        followsSystem: true
    )

    static let dark: [EditorTheme] = [
        tokyoMidnight, sakuraNight, kanagawaWave, nordAurora, dracula,
        catppuccinMocha, gruvboxDusk, monokaiNeon, oneDark, rosePine,
        nightOwl, ayuMirage, everforest, synthwaveSunset, solarizedDark,
    ]

    static let light: [EditorTheme] = [
        cherrySakura, catppuccinLatte, rosePineDawn, gruvboxDawn,
        solarizedLight, paperWhite,
    ]

    static let all: [EditorTheme] = [system] + dark + light

    static func theme(id: String) -> EditorTheme? {
        all.first { $0.id == id }
    }

    // MARK: - Dark

    private static let tokyoMidnight = make("tokyo-midnight", "Tokyo Midnight", dark: true, [
        .background: "#1a1b26", .foreground: "#a9b1d6",
        .caret: "#c0caf5", .selection: "#33467c", .currentLine: "#24283b",
        .gutterForeground: "#3b4261", .gutterActiveForeground: "#737aa2",
        .accent: "#7aa2f7", .separator: "#292e42",
        .keyword: "#bb9af7", .string: "#9ece6a", .comment: "#565f89",
        .number: "#ff9e64", .type: "#2ac3de", .function: "#7aa2f7",
        .variable: "#c0caf5", .constant: "#ff9e64", .operator: "#89ddff",
        .punctuation: "#9aa5ce", .attribute: "#bb9af7", .tag: "#f7768e",
        .heading: "#7aa2f7", .link: "#73daca",
    ])

    private static let sakuraNight = make("sakura-night", "Sakura Night", dark: true, [
        .background: "#1b1520", .foreground: "#ebdfe8",
        .caret: "#ff9ec8", .selection: "#45304a", .currentLine: "#251d2b",
        .gutterForeground: "#5b4a60", .gutterActiveForeground: "#c9a6c9",
        .accent: "#ff9ec8", .separator: "#332839",
        .keyword: "#ff8fc0", .string: "#c3e88d", .comment: "#7d6b82",
        .number: "#ffb86c", .type: "#9ad8d8", .function: "#d7a6ff",
        .variable: "#ebdfe8", .constant: "#ffb86c", .operator: "#ff8fc0",
        .punctuation: "#b9a6bb", .attribute: "#9ad8d8", .tag: "#ff8fc0",
        .heading: "#d7a6ff", .link: "#9ad8d8",
    ])

    private static let kanagawaWave = make("kanagawa-wave", "Kanagawa Wave", dark: true, [
        .background: "#1f1f28", .foreground: "#dcd7ba",
        .caret: "#c8c093", .selection: "#2d4f67", .currentLine: "#223249",
        .gutterForeground: "#54546d", .gutterActiveForeground: "#c8c093",
        .accent: "#7e9cd8", .separator: "#2a2a37",
        .keyword: "#957fb8", .string: "#98bb6c", .comment: "#727169",
        .number: "#d27e99", .type: "#7aa89f", .function: "#7e9cd8",
        .variable: "#dcd7ba", .constant: "#ffa066", .operator: "#c0a36e",
        .punctuation: "#9cabca", .attribute: "#7aa89f", .tag: "#e46876",
        .heading: "#7e9cd8", .link: "#7fb4ca",
    ])

    private static let nordAurora = make("nord-aurora", "Nord Aurora", dark: true, [
        .background: "#2e3440", .foreground: "#d8dee9",
        .caret: "#d8dee9", .selection: "#434c5e", .currentLine: "#3b4252",
        .gutterForeground: "#4c566a", .gutterActiveForeground: "#d8dee9",
        .accent: "#88c0d0", .separator: "#3b4252",
        .keyword: "#81a1c1", .string: "#a3be8c", .comment: "#616e88",
        .number: "#b48ead", .type: "#8fbcbb", .function: "#88c0d0",
        .variable: "#d8dee9", .constant: "#b48ead", .operator: "#81a1c1",
        .punctuation: "#eceff4", .attribute: "#8fbcbb", .tag: "#81a1c1",
        .heading: "#88c0d0", .link: "#88c0d0",
    ])

    private static let dracula = make("dracula", "Dracula", dark: true, [
        .background: "#282a36", .foreground: "#f8f8f2",
        .caret: "#f8f8f2", .selection: "#44475a", .currentLine: "#343746",
        .gutterForeground: "#6272a4", .gutterActiveForeground: "#f8f8f2",
        .accent: "#bd93f9", .separator: "#3b3d4c",
        .keyword: "#ff79c6", .string: "#f1fa8c", .comment: "#6272a4",
        .number: "#bd93f9", .type: "#8be9fd", .function: "#50fa7b",
        .variable: "#f8f8f2", .constant: "#bd93f9", .operator: "#ff79c6",
        .punctuation: "#f8f8f2", .attribute: "#50fa7b", .tag: "#ff79c6",
        .heading: "#bd93f9", .link: "#8be9fd",
    ])

    private static let catppuccinMocha = make("catppuccin-mocha", "Catppuccin Mocha", dark: true, [
        .background: "#1e1e2e", .foreground: "#cdd6f4",
        .caret: "#f5e0dc", .selection: "#313244", .currentLine: "#292c3c",
        .gutterForeground: "#45475a", .gutterActiveForeground: "#7f849c",
        .accent: "#cba6f7", .separator: "#313244",
        .keyword: "#cba6f7", .string: "#a6e3a1", .comment: "#6c7086",
        .number: "#fab387", .type: "#f9e2af", .function: "#89b4fa",
        .variable: "#cdd6f4", .constant: "#fab387", .operator: "#89dceb",
        .punctuation: "#9399b2", .attribute: "#f9e2af", .tag: "#89b4fa",
        .heading: "#89b4fa", .link: "#94e2d5",
    ])

    private static let gruvboxDusk = make("gruvbox-dusk", "Gruvbox Dusk", dark: true, [
        .background: "#282828", .foreground: "#ebdbb2",
        .caret: "#ebdbb2", .selection: "#504945", .currentLine: "#32302f",
        .gutterForeground: "#7c6f64", .gutterActiveForeground: "#bdae93",
        .accent: "#fabd2f", .separator: "#3c3836",
        .keyword: "#fb4934", .string: "#b8bb26", .comment: "#928374",
        .number: "#d3869b", .type: "#fabd2f", .function: "#b8bb26",
        .variable: "#ebdbb2", .constant: "#d3869b", .operator: "#fe8019",
        .punctuation: "#a89984", .attribute: "#8ec07c", .tag: "#8ec07c",
        .heading: "#fabd2f", .link: "#83a598",
    ])

    private static let monokaiNeon = make("monokai-neon", "Monokai Neon", dark: true, [
        .background: "#272822", .foreground: "#f8f8f2",
        .caret: "#f8f8f0", .selection: "#49483e", .currentLine: "#3e3d32",
        .gutterForeground: "#75715e", .gutterActiveForeground: "#f8f8f2",
        .accent: "#a6e22e", .separator: "#3e3d32",
        .keyword: "#f92672", .string: "#e6db74", .comment: "#75715e",
        .number: "#ae81ff", .type: "#66d9ef", .function: "#a6e22e",
        .variable: "#f8f8f2", .constant: "#ae81ff", .operator: "#f92672",
        .punctuation: "#f8f8f2", .attribute: "#a6e22e", .tag: "#f92672",
        .heading: "#a6e22e", .link: "#66d9ef",
    ])

    private static let oneDark = make("one-dark", "One Dark", dark: true, [
        .background: "#282c34", .foreground: "#abb2bf",
        .caret: "#528bff", .selection: "#3e4451", .currentLine: "#2c313c",
        .gutterForeground: "#4b5263", .gutterActiveForeground: "#abb2bf",
        .accent: "#61afef", .separator: "#3b4048",
        .keyword: "#c678dd", .string: "#98c379", .comment: "#5c6370",
        .number: "#d19a66", .type: "#e5c07b", .function: "#61afef",
        .variable: "#e06c75", .constant: "#d19a66", .operator: "#56b6c2",
        .punctuation: "#abb2bf", .attribute: "#d19a66", .tag: "#e06c75",
        .heading: "#61afef", .link: "#56b6c2",
    ])

    private static let rosePine = make("rose-pine", "Rosé Pine", dark: true, [
        .background: "#191724", .foreground: "#e0def4",
        .caret: "#e0def4", .selection: "#312f44", .currentLine: "#21202e",
        .gutterForeground: "#6e6a86", .gutterActiveForeground: "#908caa",
        .accent: "#c4a7e7", .separator: "#26233a",
        .keyword: "#31748f", .string: "#f6c177", .comment: "#6e6a86",
        .number: "#ebbcba", .type: "#9ccfd8", .function: "#ebbcba",
        .variable: "#e0def4", .constant: "#ebbcba", .operator: "#908caa",
        .punctuation: "#908caa", .attribute: "#9ccfd8", .tag: "#eb6f92",
        .heading: "#c4a7e7", .link: "#9ccfd8",
    ])

    private static let nightOwl = make("night-owl", "Night Owl", dark: true, [
        .background: "#011627", .foreground: "#d6deeb",
        .caret: "#80a4c2", .selection: "#1d3b53", .currentLine: "#0b2942",
        .gutterForeground: "#4b6479", .gutterActiveForeground: "#c5e4fd",
        .accent: "#82aaff", .separator: "#122d42",
        .keyword: "#c792ea", .string: "#ecc48d", .comment: "#637777",
        .number: "#f78c6c", .type: "#ffcb8b", .function: "#82aaff",
        .variable: "#d6deeb", .constant: "#f78c6c", .operator: "#c792ea",
        .punctuation: "#c5e4fd", .attribute: "#addb67", .tag: "#7fdbca",
        .heading: "#82aaff", .link: "#7fdbca",
    ])

    private static let ayuMirage = make("ayu-mirage", "Ayu Mirage", dark: true, [
        .background: "#1f2430", .foreground: "#cbccc6",
        .caret: "#ffcc66", .selection: "#34455a", .currentLine: "#242b38",
        .gutterForeground: "#454b5a", .gutterActiveForeground: "#8a9199",
        .accent: "#ffcc66", .separator: "#2a3140",
        .keyword: "#ffa759", .string: "#bae67e", .comment: "#5c6773",
        .number: "#ffcc66", .type: "#73d0ff", .function: "#ffd580",
        .variable: "#cbccc6", .constant: "#d4bfff", .operator: "#f29e74",
        .punctuation: "#8a9199", .attribute: "#ffd580", .tag: "#5ccfe6",
        .heading: "#ffcc66", .link: "#5ccfe6",
    ])

    private static let everforest = make("everforest", "Everforest", dark: true, [
        .background: "#2d353b", .foreground: "#d3c6aa",
        .caret: "#d3c6aa", .selection: "#475258", .currentLine: "#343f44",
        .gutterForeground: "#7a8478", .gutterActiveForeground: "#9da9a0",
        .accent: "#a7c080", .separator: "#3d484d",
        .keyword: "#e67e80", .string: "#a7c080", .comment: "#859289",
        .number: "#d699b6", .type: "#dbbc7f", .function: "#a7c080",
        .variable: "#d3c6aa", .constant: "#d699b6", .operator: "#e69875",
        .punctuation: "#9da9a0", .attribute: "#83c092", .tag: "#e67e80",
        .heading: "#a7c080", .link: "#83c092",
    ])

    private static let synthwaveSunset = make("synthwave-sunset", "Synthwave Sunset", dark: true, [
        .background: "#262335", .foreground: "#f0eff1",
        .caret: "#f97e72", .selection: "#463465", .currentLine: "#241b2f",
        .gutterForeground: "#495495", .gutterActiveForeground: "#848bbd",
        .accent: "#f97e72", .separator: "#34294f",
        .keyword: "#fede5d", .string: "#ff8b39", .comment: "#848bbd",
        .number: "#f97e72", .type: "#fe4450", .function: "#36f9f6",
        .variable: "#ff7edb", .constant: "#f97e72", .operator: "#fede5d",
        .punctuation: "#ff7edb", .attribute: "#36f9f6", .tag: "#fe4450",
        .heading: "#36f9f6", .link: "#36f9f6",
    ])

    private static let solarizedDark = make("solarized-dark", "Solarized Dark", dark: true, [
        .background: "#002b36", .foreground: "#93a1a1",
        .caret: "#93a1a1", .selection: "#0e4b57", .currentLine: "#073642",
        .gutterForeground: "#586e75", .gutterActiveForeground: "#93a1a1",
        .accent: "#268bd2", .separator: "#073642",
        .keyword: "#859900", .string: "#2aa198", .comment: "#586e75",
        .number: "#d33682", .type: "#b58900", .function: "#268bd2",
        .variable: "#268bd2", .constant: "#d33682", .operator: "#859900",
        .punctuation: "#93a1a1", .attribute: "#b58900", .tag: "#268bd2",
        .heading: "#cb4b16", .link: "#268bd2",
    ])

    // MARK: - Light

    private static let cherrySakura = make("cherry-sakura", "Cherry Sakura", dark: false, [
        .background: "#fff4f6", .foreground: "#4b3b46",
        .caret: "#c2185b", .selection: "#fbd5e0", .currentLine: "#fdeaf0",
        .gutterForeground: "#d6a7b8", .gutterActiveForeground: "#c2185b",
        .accent: "#e4739b", .separator: "#f6dbe3",
        .keyword: "#c2185b", .string: "#6f8f45", .comment: "#b58aa0",
        .number: "#cf6335", .type: "#8e5fbf", .function: "#d4568c",
        .variable: "#4b3b46", .constant: "#cf6335", .operator: "#a35d7a",
        .punctuation: "#8a7480", .attribute: "#8e5fbf", .tag: "#c2185b",
        .heading: "#8e5fbf", .link: "#3f7f96",
    ])

    private static let catppuccinLatte = make("catppuccin-latte", "Catppuccin Latte", dark: false, [
        .background: "#eff1f5", .foreground: "#4c4f69",
        .caret: "#dc8a78", .selection: "#ccd0da", .currentLine: "#e6e9ef",
        .gutterForeground: "#9ca0b0", .gutterActiveForeground: "#6c6f85",
        .accent: "#8839ef", .separator: "#dce0e8",
        .keyword: "#8839ef", .string: "#40a02b", .comment: "#8c8fa1",
        .number: "#fe640b", .type: "#df8e1d", .function: "#1e66f5",
        .variable: "#4c4f69", .constant: "#fe640b", .operator: "#04a5e5",
        .punctuation: "#7c7f93", .attribute: "#df8e1d", .tag: "#1e66f5",
        .heading: "#1e66f5", .link: "#179299",
    ])

    private static let rosePineDawn = make("rose-pine-dawn", "Rosé Pine Dawn", dark: false, [
        .background: "#faf4ed", .foreground: "#575279",
        .caret: "#575279", .selection: "#eee4dc", .currentLine: "#fffaf3",
        .gutterForeground: "#9893a5", .gutterActiveForeground: "#797593",
        .accent: "#907aa9", .separator: "#f2e9e1",
        .keyword: "#286983", .string: "#ea9d34", .comment: "#9893a5",
        .number: "#d7827e", .type: "#56949f", .function: "#d7827e",
        .variable: "#575279", .constant: "#d7827e", .operator: "#797593",
        .punctuation: "#797593", .attribute: "#56949f", .tag: "#b4637a",
        .heading: "#907aa9", .link: "#56949f",
    ])

    private static let gruvboxDawn = make("gruvbox-dawn", "Gruvbox Dawn", dark: false, [
        .background: "#fbf1c7", .foreground: "#3c3836",
        .caret: "#3c3836", .selection: "#ebdbb2", .currentLine: "#f2e5bc",
        .gutterForeground: "#bdae93", .gutterActiveForeground: "#7c6f64",
        .accent: "#b57614", .separator: "#ebdbb2",
        .keyword: "#9d0006", .string: "#79740e", .comment: "#928374",
        .number: "#8f3f71", .type: "#b57614", .function: "#79740e",
        .variable: "#3c3836", .constant: "#8f3f71", .operator: "#af3a03",
        .punctuation: "#7c6f64", .attribute: "#427b58", .tag: "#427b58",
        .heading: "#b57614", .link: "#076678",
    ])

    private static let solarizedLight = make("solarized-light", "Solarized Light", dark: false, [
        .background: "#fdf6e3", .foreground: "#657b83",
        .caret: "#657b83", .selection: "#eee8d5", .currentLine: "#f5efdc",
        .gutterForeground: "#93a1a1", .gutterActiveForeground: "#586e75",
        .accent: "#268bd2", .separator: "#eee8d5",
        .keyword: "#859900", .string: "#2aa198", .comment: "#93a1a1",
        .number: "#d33682", .type: "#b58900", .function: "#268bd2",
        .variable: "#268bd2", .constant: "#d33682", .operator: "#859900",
        .punctuation: "#657b83", .attribute: "#b58900", .tag: "#268bd2",
        .heading: "#cb4b16", .link: "#268bd2",
    ])

    private static let paperWhite = make("paper-white", "Paper White", dark: false, [
        .background: "#ffffff", .foreground: "#24292f",
        .caret: "#0969da", .selection: "#cfe4ff", .currentLine: "#f6f8fa",
        .gutterForeground: "#8c959f", .gutterActiveForeground: "#24292f",
        .accent: "#0969da", .separator: "#eaeef2",
        .keyword: "#cf222e", .string: "#0a3069", .comment: "#6e7781",
        .number: "#0550ae", .type: "#953800", .function: "#8250df",
        .variable: "#24292f", .constant: "#0550ae", .operator: "#cf222e",
        .punctuation: "#57606a", .attribute: "#0550ae", .tag: "#116329",
        .heading: "#0550ae", .link: "#0969da",
    ])

    // MARK: - Building

    /// Comments come out italic across the board, which is the convention every
    /// one of these palettes was drawn from — and the one thing that most makes
    /// a themed editor look like the theme rather than like a recolouring.
    private static func make(
        _ id: String,
        _ name: String,
        dark: Bool,
        _ colors: [ThemeRole: String]
    ) -> EditorTheme {
        EditorTheme(
            id: id,
            name: name,
            isDark: dark,
            colors: colors,
            styles: [.comment: .italic],
            isBuiltIn: true
        )
    }
}
