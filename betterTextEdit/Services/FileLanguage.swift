import SwiftUI

enum FileLanguage: String, CaseIterable, Identifiable, Codable {
    case plainText = "Plain Text"
    case richText = "Formatted Text"
    case pdf = "PDF"
    case image = "Image"
    case markdown = "Markdown"
    case json = "JSON"
    case swift = "Swift"
    case javascript = "JavaScript"
    case typescript = "TypeScript"
    case python = "Python"
    case ruby = "Ruby"
    case php = "PHP"
    case lua = "Lua"
    case html = "HTML"
    case css = "CSS"
    case cFamily = "C / C++"
    case rust = "Rust"
    case go = "Go"
    case java = "Java"
    case shell = "Shell"
    case yaml = "YAML"
    case toml = "TOML"
    case ini = "Config"
    case xml = "XML"
    case sql = "SQL"

    var id: String { rawValue }

    /// The languages a plain-text document can be set to by hand. The three
    /// left out aren't languages — they're what kind of file it is.
    static let selectable: [FileLanguage] = allCases.filter {
        ![.richText, .pdf, .image].contains($0)
    }

    // MARK: - Detection by name

    /// What each extension means. Anything not listed here is a file whose name
    /// tells us nothing, which is what sends `LanguageDetector` to the contents.
    private static let byExtension: [String: FileLanguage] = [
        "txt": .plainText, "text": .plainText, "log": .plainText,
        "csv": .plainText, "tsv": .plainText, "rst": .plainText, "tex": .plainText,
        "md": .markdown, "markdown": .markdown, "mdown": .markdown, "mkd": .markdown, "mdx": .markdown,
        "json": .json, "jsonc": .json, "json5": .json, "geojson": .json,
        "swift": .swift,
        "js": .javascript, "jsx": .javascript, "mjs": .javascript, "cjs": .javascript,
        "ts": .typescript, "tsx": .typescript, "mts": .typescript, "cts": .typescript,
        "py": .python, "pyw": .python, "pyi": .python,
        "rb": .ruby, "rake": .ruby, "gemspec": .ruby,
        "php": .php, "phtml": .php,
        "lua": .lua,
        "html": .html, "htm": .html, "xhtml": .html,
        "css": .css, "scss": .css, "sass": .css, "less": .css,
        "c": .cFamily, "h": .cFamily, "cc": .cFamily, "cpp": .cFamily, "cxx": .cFamily,
        "hpp": .cFamily, "hh": .cFamily, "m": .cFamily, "mm": .cFamily, "cs": .cFamily,
        "rs": .rust,
        "go": .go,
        "java": .java, "kt": .java, "kts": .java, "scala": .java, "groovy": .java,
        "sh": .shell, "bash": .shell, "zsh": .shell, "ksh": .shell, "fish": .shell, "command": .shell,
        "yaml": .yaml, "yml": .yaml,
        "toml": .toml,
        "ini": .ini, "cfg": .ini, "conf": .ini, "properties": .ini, "env": .ini,
        "xml": .xml, "svg": .xml, "plist": .xml, "xib": .xml, "storyboard": .xml,
        "xsd": .xml, "xsl": .xml, "rss": .xml, "atom": .xml,
        "sql": .sql,
    ]

    /// Files everyone knows by name rather than by extension. Foundation
    /// doesn't treat a leading dot as an extension, so `.zshrc` only ever
    /// arrives here.
    private static let byName: [String: FileLanguage] = [
        ".bashrc": .shell, ".bash_profile": .shell, ".bash_aliases": .shell,
        ".zshrc": .shell, ".zprofile": .shell, ".zshenv": .shell, ".zlogin": .shell,
        ".profile": .shell, ".xinitrc": .shell,
        ".gitignore": .ini, ".gitattributes": .ini, ".gitconfig": .ini,
        ".editorconfig": .ini, ".env": .ini, ".npmrc": .ini, ".curlrc": .ini,
        ".eslintrc": .json, ".babelrc": .json, ".prettierrc": .json, ".swiftlint.yml": .yaml,
        "gemfile": .ruby, "rakefile": .ruby, "podfile": .ruby, "brewfile": .ruby, "fastfile": .ruby,
        "package.swift": .swift,
    ]

    static func detect(from fileExtension: String) -> FileLanguage {
        byExtension[fileExtension.lowercased()] ?? .plainText
    }

    /// What the file's *name* says it is, or `nil` when the name says nothing —
    /// an extension nobody recognises, or none at all.
    static func known(for url: URL) -> FileLanguage? {
        if let named = byName[url.lastPathComponent.lowercased()] { return named }
        let ext = url.pathExtension.lowercased()
        guard !ext.isEmpty else { return nil }
        return byExtension[ext]
    }

    /// Same, but settling for plain text — for places like the file browser
    /// that need an icon for every row.
    static func detect(for url: URL) -> FileLanguage {
        known(for: url) ?? .plainText
    }

    /// The extension to suggest when saving a document of this kind.
    var fileExtension: String {
        switch self {
        case .plainText: "txt"
        case .richText: "docx"
        case .pdf: "pdf"
        case .image: "png"
        case .markdown: "md"
        case .json: "json"
        case .swift: "swift"
        case .javascript: "js"
        case .typescript: "ts"
        case .python: "py"
        case .ruby: "rb"
        case .php: "php"
        case .lua: "lua"
        case .html: "html"
        case .css: "css"
        case .cFamily: "c"
        case .rust: "rs"
        case .go: "go"
        case .java: "java"
        case .shell: "sh"
        case .yaml: "yaml"
        case .toml: "toml"
        case .ini: "ini"
        case .xml: "xml"
        case .sql: "sql"
        }
    }

    var symbol: String {
        switch self {
        case .plainText: "doc.plaintext"
        case .richText: "doc.richtext"
        case .pdf: "doc.text.image"
        case .image: "photo"
        case .markdown: "text.document"
        case .json: "curlybraces"
        case .swift: "swift"
        case .javascript, .typescript: "j.square"
        case .python: "chevron.left.forwardslash.chevron.right"
        case .ruby: "diamond"
        case .php, .lua: "chevron.left.forwardslash.chevron.right"
        case .html, .xml: "chevron.left.forwardslash.chevron.right"
        case .css: "paintbrush"
        case .cFamily, .rust, .go, .java: "chevron.left.forwardslash.chevron.right"
        case .shell: "terminal"
        case .yaml, .toml, .ini: "list.bullet.indent"
        case .sql: "cylinder"
        }
    }

    var tint: Color {
        switch self {
        case .richText: .blue
        case .pdf: .red
        case .image: .teal
        case .markdown: .blue
        case .json: .yellow
        case .swift: .orange
        case .javascript: .yellow
        case .typescript: .blue
        case .python: .green
        case .ruby: .red
        case .php: .purple
        case .lua: .blue
        case .html: .orange
        case .css: .purple
        case .rust: .orange
        case .go: .cyan
        case .shell: .green
        case .yaml, .toml, .ini: .pink
        case .sql: .indigo
        default: .secondary
        }
    }

    // MARK: - Comments

    /// How this language marks a comment, which is all the highlighter needs to
    /// know to grey one out.
    enum CommentStyle {
        case none
        /// `# to end of line` — shells, Python, Ruby, YAML, TOML, config files.
        case hash
        /// `// to end of line`, and `/* … */`.
        case slashes
        /// `<!-- … -->`.
        case markup
        /// `-- to end of line` — Lua and SQL.
        case doubleDash
    }

    var commentStyle: CommentStyle {
        switch self {
        case .plainText, .richText, .pdf, .image, .markdown: .none
        case .python, .shell, .ruby, .yaml, .toml, .ini: .hash
        case .html, .xml: .markup
        case .lua, .sql: .doubleDash
        default: .slashes
        }
    }
}
