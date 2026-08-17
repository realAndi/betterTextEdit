import AppKit
import UniformTypeIdentifiers

// MARK: - Text formats

/// A format that is just characters under a particular extension.
///
/// Everything betterTextEdit reads as text it can also write as text, so this
/// catalogue *is* the read list turned around: pick `Shell Script (.sh)` in the
/// Save panel and the file goes out as `.sh`, highlighted as a shell script the
/// next time it's opened.
struct TextFormat: Hashable, Identifiable {
    let name: String
    let fileExtension: String
    let language: FileLanguage

    var id: String { fileExtension }
    var title: String { "\(name) (.\(fileExtension))" }

    init(_ name: String, _ fileExtension: String, _ language: FileLanguage) {
        self.name = name
        self.fileExtension = fileExtension
        self.language = language
    }
}

/// The text formats offered in the Save panel, in the groups they're listed in.
enum TextFormatCatalog {
    struct Group {
        let title: String
        let formats: [TextFormat]
    }

    static let plainText = TextFormat("Plain Text", "txt", .plainText)
    static let markdown = TextFormat("Markdown", "md", .markdown)

    static let groups: [Group] = [
        Group(title: "Text", formats: [
            plainText,
            markdown,
            TextFormat("Comma-Separated Values", "csv", .plainText),
            TextFormat("Tab-Separated Values", "tsv", .plainText),
            TextFormat("Log File", "log", .plainText),
            TextFormat("reStructuredText", "rst", .plainText),
            TextFormat("LaTeX", "tex", .plainText),
        ]),
        Group(title: "Web", formats: [
            TextFormat("HTML", "html", .html),
            TextFormat("CSS", "css", .css),
            TextFormat("Sass", "scss", .css),
            TextFormat("JavaScript", "js", .javascript),
            TextFormat("JavaScript Module", "mjs", .javascript),
            TextFormat("TypeScript", "ts", .typescript),
            TextFormat("TypeScript JSX", "tsx", .typescript),
            TextFormat("PHP", "php", .php),
            TextFormat("SVG", "svg", .xml),
        ]),
        Group(title: "Data & Configuration", formats: [
            TextFormat("JSON", "json", .json),
            TextFormat("YAML", "yaml", .yaml),
            TextFormat("TOML", "toml", .toml),
            TextFormat("XML", "xml", .xml),
            TextFormat("Property List", "plist", .xml),
            TextFormat("Config File", "ini", .ini),
            TextFormat("Environment File", "env", .ini),
            TextFormat("SQL", "sql", .sql),
        ]),
        Group(title: "Code", formats: [
            TextFormat("Shell Script", "sh", .shell),
            TextFormat("Zsh Script", "zsh", .shell),
            TextFormat("Python", "py", .python),
            TextFormat("Ruby", "rb", .ruby),
            TextFormat("Swift", "swift", .swift),
            TextFormat("C", "c", .cFamily),
            TextFormat("C Header", "h", .cFamily),
            TextFormat("C++", "cpp", .cFamily),
            TextFormat("Objective-C", "m", .cFamily),
            TextFormat("Rust", "rs", .rust),
            TextFormat("Go", "go", .go),
            TextFormat("Java", "java", .java),
            TextFormat("Kotlin", "kt", .java),
            TextFormat("Lua", "lua", .lua),
        ]),
    ]

    static let all: [TextFormat] = groups.flatMap(\.formats)

    /// The catalogue entry for an extension, if there is one.
    static func format(forExtension fileExtension: String) -> TextFormat? {
        let wanted = fileExtension.lowercased()
        return all.first { $0.fileExtension == wanted }
    }
}

// MARK: - Save formats

/// The formats a document can be written as.
enum SaveFormat: Hashable {
    /// Writes the characters as they are, under whatever name is typed — so a
    /// `.swift` file stays a `.swift` file, and an extension that isn't in the
    /// catalogue still works.
    case automatic
    /// Writes the characters under a known extension.
    case text(TextFormat)
    case richText
    case richTextBundle
    case word
    /// A laid-out web page, not source — formatting survives.
    case webPage
    case pdf

    var title: String {
        switch self {
        case .automatic: "Automatic (from file name)"
        case let .text(format): format.title
        case .richText: "Rich Text (.rtf)"
        case .richTextBundle: "Rich Text with Images (.rtfd)"
        case .word: "Word Document (.docx)"
        case .webPage: "Web Page (.html)"
        case .pdf: "PDF (.pdf)"
        }
    }

    /// `nil` keeps whatever extension the name field already has.
    var fileExtension: String? {
        switch self {
        case .automatic: nil
        case let .text(format): format.fileExtension
        case .richText: "rtf"
        case .richTextBundle: "rtfd"
        case .word: "docx"
        case .webPage: "html"
        case .pdf: "pdf"
        }
    }

    var contentType: UTType? {
        switch self {
        case .automatic: nil
        case let .text(format): UTType(filenameExtension: format.fileExtension)
        case .richText: .rtf
        case .richTextBundle: .rtfd
        case .word: UTType("org.openxmlformats.wordprocessingml.document")
        case .webPage: .html
        case .pdf: .pdf
        }
    }

    /// True when the text has to be laid out as formatted text on the way out.
    var needsAttributedText: Bool {
        switch self {
        case .richText, .richTextBundle, .word, .webPage, .pdf: true
        case .automatic, .text: false
        }
    }

    /// What a document saved in this format becomes — used to decide whether the
    /// open tab should follow the file that was just written.
    var isPlainCharacters: Bool {
        switch self {
        case .automatic, .text: true
        default: false
        }
    }

    // MARK: - The popup's contents

    /// A row in the File Format popup: a format to pick, or a heading over the
    /// ones that follow.
    enum Item {
        case format(SaveFormat)
        case section(String)
    }

    static func items(for kind: EditorDocument.Kind) -> [Item] {
        switch kind {
        case .plain:
            [.format(.automatic)]
                + TextFormatCatalog.groups.flatMap { group in
                    [Item.section(group.title)] + group.formats.map { Item.format(.text($0)) }
                }
                + [.section("Documents"), .format(.word), .format(.richText), .format(.pdf)]

        case .rich:
            // Formatted first: these are the ones that keep the document intact.
            [.format(.word), .format(.richText), .format(.richTextBundle), .format(.webPage), .format(.pdf)]
                + [
                    .section("Text"),
                    .format(.text(TextFormatCatalog.plainText)),
                    .format(.text(TextFormatCatalog.markdown)),
                ]

        case .pdf, .image:
            []
        }
    }

    static func options(for kind: EditorDocument.Kind) -> [SaveFormat] {
        items(for: kind).compactMap { item in
            if case let .format(format) = item { return format }
            return nil
        }
    }
}

// MARK: - The Save panel's format popup

/// The "File Format:" popup that sits under the Save panel's file list.
///
/// `NSSavePanel` won't grow one of these on its own, so this is the accessory
/// view TextEdit and friends use: pick a format and the panel's name and
/// permitted types follow along.
@MainActor
final class SaveFormatAccessory: NSObject {
    let view: NSView
    private(set) var selected: SaveFormat

    /// One entry per menu item, so the popup's index maps straight back to a
    /// format. Headings and separators hold `nil`.
    private var formats: [SaveFormat?] = []
    private let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    private weak var panel: NSSavePanel?

    init(items: [SaveFormat.Item], initial: SaveFormat, panel: NSSavePanel) {
        let available = items.compactMap { item -> SaveFormat? in
            if case let .format(format) = item { return format }
            return nil
        }
        selected = available.contains(initial) ? initial : (available.first ?? .automatic)
        self.panel = panel

        let label = NSTextField(labelWithString: "File Format:")
        label.alignment = .right

        let stack = NSStackView(views: [label, popup])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 12, right: 16)
        view = stack

        super.init()

        build(items)
        popup.target = self
        popup.action = #selector(formatChanged)
        apply()
    }

    /// Builds the menu, with the groups shown as headings so a long list still
    /// reads as sections rather than one run of forty items.
    private func build(_ items: [SaveFormat.Item]) {
        let menu = NSMenu()
        var first = true

        for item in items {
            switch item {
            case let .section(title):
                if !first { menu.addItem(.separator()); formats.append(nil) }
                let heading = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                heading.isEnabled = false
                menu.addItem(heading)
                formats.append(nil)

            case let .format(format):
                let entry = NSMenuItem(title: format.title, action: nil, keyEquivalent: "")
                menu.addItem(entry)
                formats.append(format)
            }
            first = false
        }

        popup.menu = menu
        if let index = formats.firstIndex(where: { $0 == selected }) {
            popup.selectItem(at: index)
        }
    }

    @objc private func formatChanged() {
        guard let format = formats[safe: popup.indexOfSelectedItem] ?? nil else { return }
        selected = format
        apply()
    }

    /// Keeps the panel's permitted types and the typed filename in step with the
    /// popup. Order matters: setting the types can rewrite the name field, so
    /// the name is set afterwards.
    private func apply() {
        guard let panel else { return }
        let base = (panel.nameFieldStringValue as NSString).deletingPathExtension
        panel.allowedContentTypes = selected.contentType.map { [$0] } ?? []
        if let ext = selected.fileExtension, !base.isEmpty {
            panel.nameFieldStringValue = base + "." + ext
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
