import AppKit
import Foundation

// Turns a VS Code / Cursor colour theme into one of ours.
//
// A VS Code theme is two tables. `colors` names the chrome — the editor
// background, the cursor, the line numbers — in flat keys we can read straight
// across. `tokenColors` is the interesting half: TextMate rules, each claiming
// a *scope selector* like `keyword.control` or `entity.name.function`, and it's
// those that decide what code looks like.
//
// So importing is mostly a scope-resolution problem. For each role we know
// about, ask the theme's rules a short list of scopes from most specific to
// least, and take the first that answers. That's the same walk a TextMate
// grammar does, minus the grammar — we have no per-language scope stack, just a
// fixed set of questions.
//
// Three shapes come in: a `.json` theme file, a `.vsix` extension (a ZIP with
// the theme files inside), and a `.tmTheme` (a plist, the format VS Code's own
// format grew out of). Cursor, VSCodium, and Windsurf all use VS Code's format
// unchanged, which is why one importer covers the lot.

enum VSCodeThemeImporter {
    // MARK: - Errors

    enum ImportError: LocalizedError {
        case unreadable(String)
        case notATheme(String)
        case empty(String)

        var errorDescription: String? {
            switch self {
            case let .unreadable(name): "“\(name)” couldn’t be read."
            case let .notATheme(name): "“\(name)” isn’t a colour theme."
            case let .empty(name): "“\(name)” doesn’t contain any colour themes."
            }
        }

        var recoverySuggestion: String? {
            switch self {
            case .unreadable:
                "Check the file is a colour theme exported from VS Code or Cursor — a .json theme file, "
                    + "a .vsix extension, or a .tmTheme file."
            case .notATheme:
                "A VS Code theme file has a “colors” or “tokenColors” section. This one has neither."
            case .empty:
                "The extension has no themes in it — it may be a language or a tool rather than a colour theme."
            }
        }
    }

    /// What an import can be pointed at.
    static let readableExtensions = ["json", "jsonc", "vsix", "tmtheme"]

    // MARK: - Entry points

    /// Every theme a file or folder holds. A `.vsix` usually holds several
    /// (light and dark variants); a `.json` holds exactly one.
    static func themes(at url: URL) throws -> [EditorTheme] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw ImportError.unreadable(url.lastPathComponent)
        }

        if isDirectory.boolValue {
            return try themesInExtensionFolder(url)
        }

        switch url.pathExtension.lowercased() {
        case "vsix":
            return try themesInArchive(url)
        case "tmtheme":
            return [try tmTheme(at: url)]
        default:
            return [try jsonTheme(at: url)]
        }
    }

    // MARK: - A single JSON theme

    private static func jsonTheme(at url: URL) throws -> EditorTheme {
        guard let data = try? Data(contentsOf: url) else {
            throw ImportError.unreadable(url.lastPathComponent)
        }
        let directory = url.deletingLastPathComponent()
        // `include` is resolved against the file's own folder, so the loader is
        // just "read a sibling".
        let loader: (String) -> Data? = { path in
            try? Data(contentsOf: URL(fileURLWithPath: path, relativeTo: directory))
        }
        return try theme(
            from: data,
            at: url.lastPathComponent,
            loader: loader,
            fallbackName: url.deletingPathExtension().lastPathComponent,
            darkHint: manifestHint(for: url)
        )
    }

    /// Whether the extension this file belongs to calls it dark.
    ///
    /// A theme picked out of an extension folder is usually at
    /// `<extension>/themes/<name>.json`, and the `package.json` above it knows
    /// things the theme file itself may not — most importantly `uiTheme`, which
    /// is the only place a high-contrast theme says which way round it is.
    private static func manifestHint(for url: URL) -> Bool? {
        var folder = url.deletingLastPathComponent()
        for _ in 0 ..< 3 {
            let manifest = folder.appendingPathComponent("package.json")
            if let data = try? Data(contentsOf: manifest),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let target = url.standardizedFileURL.path
                for entry in declaredThemes(in: object) {
                    let candidate = URL(fileURLWithPath: entry.path, relativeTo: folder).standardizedFileURL
                    if candidate.path == target { return entry.isDark }
                }
                return nil
            }
            let parent = folder.deletingLastPathComponent()
            guard parent.path != folder.path else { break }
            folder = parent
        }
        return nil
    }

    // MARK: - A .vsix extension

    private static func themesInArchive(_ url: URL) throws -> [EditorTheme] {
        guard let archive = ZipArchive(url: url) else {
            throw ImportError.unreadable(url.lastPathComponent)
        }
        let loader: (String) -> Data? = { archive.contents(named: $0) }

        // The manifest lists the themes and their labels — better names than the
        // file names, and it skips everything in the extension that isn't a theme.
        var paths: [(path: String, label: String, isDark: Bool?)] = []
        if let manifest = archive.contents(named: "extension/package.json"),
           let object = try? JSONSerialization.jsonObject(with: manifest) as? [String: Any] {
            let strings = localizedStrings(archive.contents(named: "extension/package.nls.json"))
            paths = declaredThemes(in: object, strings: strings).map {
                ("extension/" + $0.path, $0.label, $0.isDark)
            }
        }

        // No manifest, or one that lists nothing: fall back to whatever JSON
        // sits in the extension's themes folder.
        if paths.isEmpty {
            paths = archive.entries
                .map(\.name)
                .filter { $0.hasPrefix("extension/themes/") && $0.lowercased().hasSuffix(".json") }
                .sorted()
                .map { ($0, (($0 as NSString).lastPathComponent as NSString).deletingPathExtension, nil) }
        }

        guard !paths.isEmpty else { throw ImportError.empty(url.lastPathComponent) }

        let results = paths.compactMap { entry -> EditorTheme? in
            guard let data = archive.contents(named: normalized(entry.path)) else { return nil }
            return try? theme(
                from: data,
                at: entry.path,
                loader: loader,
                fallbackName: entry.label,
                darkHint: entry.isDark
            )
        }
        guard !results.isEmpty else { throw ImportError.empty(url.lastPathComponent) }
        return results
    }

    /// An unpacked extension folder — what's actually on disk under
    /// `~/.vscode/extensions` and `~/.cursor/extensions`.
    private static func themesInExtensionFolder(_ url: URL) throws -> [EditorTheme] {
        let manifest = url.appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: manifest),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw ImportError.empty(url.lastPathComponent) }

        let strings = localizedStrings(try? Data(contentsOf: url.appendingPathComponent("package.nls.json")))
        let declared = declaredThemes(in: object, strings: strings)
        guard !declared.isEmpty else { throw ImportError.empty(url.lastPathComponent) }

        let results = declared.compactMap { entry -> EditorTheme? in
            let file = URL(fileURLWithPath: entry.path, relativeTo: url)
            if file.pathExtension.lowercased() == "tmtheme" {
                return try? tmTheme(at: file)
            }
            guard let themeData = try? Data(contentsOf: file) else { return nil }
            let folder = file.deletingLastPathComponent()
            return try? theme(
                from: themeData,
                at: file.lastPathComponent,
                loader: { try? Data(contentsOf: URL(fileURLWithPath: $0, relativeTo: folder)) },
                fallbackName: entry.label,
                darkHint: entry.isDark
            )
        }
        guard !results.isEmpty else { throw ImportError.empty(url.lastPathComponent) }
        return results
    }

    /// `contributes.themes` out of an extension manifest.
    private static func declaredThemes(
        in manifest: [String: Any],
        strings: [String: String] = [:]
    ) -> [(path: String, label: String, isDark: Bool)] {
        guard let contributes = manifest["contributes"] as? [String: Any],
              let themes = contributes["themes"] as? [Any]
        else { return [] }

        return themes.compactMap { element in
            guard let entry = element as? [String: Any], let path = entry["path"] as? String else { return nil }
            let fallback = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            let label = (entry["label"] as? String).map { localized($0, using: strings, fallback: fallback) } ?? fallback
            // `uiTheme` is `vs` for light, `vs-dark` / `hc-black` for dark.
            let ui = (entry["uiTheme"] as? String ?? "vs-dark").lowercased()
            return (path, label, ui != "vs" && ui != "hc-light")
        }
    }

    /// A manifest label may be a `%key%` placeholder pointing into the
    /// extension's `package.nls.json` — which is how VS Code's own bundled
    /// themes are named. Without this the browser lists
    /// `%darkModernThemeLabel%`.
    private static func localized(_ label: String, using strings: [String: String], fallback: String) -> String {
        guard label.hasPrefix("%"), label.hasSuffix("%"), label.count > 2 else { return label }
        let key = String(label.dropFirst().dropLast())
        return strings[key] ?? fallback
    }

    /// The extension's translation table, in either shape VS Code writes it:
    /// flat `{"key": "text"}` or `{"key": {"message": "text"}}`, optionally
    /// wrapped in a `contents` object.
    private static func localizedStrings(_ data: Data?) -> [String: String] {
        guard let data, var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        if let contents = object["contents"] as? [String: Any] { object = contents }

        var result: [String: String] = [:]
        for (key, value) in object {
            if let text = value as? String {
                result[key] = text
            } else if let nested = value as? [String: Any], let text = nested["message"] as? String {
                result[key] = text
            }
        }
        return result
    }

    // MARK: - Parsing

    /// - Parameter darkHint: what the extension manifest's `uiTheme` said, for
    ///   the themes whose own file doesn't declare a `type`.
    private static func theme(
        from data: Data,
        at path: String,
        loader: (String) -> Data?,
        fallbackName: String,
        darkHint: Bool? = nil
    ) throws -> EditorTheme {
        guard let merged = resolved(from: data, at: path, loader: loader, depth: 0) else {
            throw ImportError.unreadable(fallbackName)
        }

        guard merged["colors"] != nil || merged["tokenColors"] != nil || merged["semanticTokenColors"] != nil else {
            throw ImportError.notATheme(fallbackName)
        }

        let name = (merged["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? fallbackName
        let chrome = stringMap(merged["colors"])
        let scopes = ScopeTable(merged["tokenColors"])
        let semantic = SemanticTable(merged["semanticTokenColors"])

        var colors: [ThemeRole: String] = [:]
        var styles: [ThemeRole: TokenStyle] = [:]

        for (role, keys) in chromeKeys {
            if let hex = keys.lazy.compactMap({ usable(chrome[$0]) }).first {
                colors[role] = hex
            }
        }

        for (role, queries) in scopeQueries {
            // Every scope we know is asked for a confident answer before any of
            // them is allowed a guess — otherwise a vague match on the first
            // scope beats an exact match on the third.
            let match = queries.lazy.compactMap { scopes.lookup($0, strict: true) }.first
                ?? queries.lazy.compactMap { scopes.lookup($0, strict: false) }.first
            if let match {
                if let hex = usable(match.color) { colors[role] = hex }
                if let style = match.style { styles[role] = style }
            }
            // Semantic tokens are the newer, language-server-driven half of a
            // theme. Plenty of modern themes lean on them, so they're worth
            // asking — but only where the TextMate rules had nothing to say.
            if colors[role] == nil, let hex = usable(semantic.color(for: role)) {
                colors[role] = hex
            }
        }

        // A theme is allowed to have no `colors` block at all, in which case the
        // token rule with no scope carries the canvas — the TextMate convention.
        if colors[.background] == nil { colors[.background] = usable(scopes.globalBackground) }
        if colors[.foreground] == nil { colors[.foreground] = usable(scopes.globalForeground) }

        // What the file says, then what the extension manifest said, then the
        // background's own brightness. The manifest matters: VS Code's
        // high-contrast themes carry no `colors` block at all — the app itself
        // supplies their canvas — so their file gives nothing to measure, and
        // `uiTheme` is the only thing that knows Light High Contrast is light.
        let declaredDark: Bool? = switch (merged["type"] as? String)?.lowercased() {
        case "light", "vs", "hc-light": false
        case "dark", "vs-dark", "hc", "hc-black": true
        default: nil
        }
        let isDark = declaredDark
            ?? darkHint
            ?? ((colors[.background].flatMap { NSColor(themeHex: $0) }?.relativeLuminance ?? 0) < 0.5)

        return EditorTheme(
            id: slug(name),
            name: name,
            author: merged["author"] as? String ?? "",
            isDark: isDark,
            colors: colors,
            styles: styles
        )
    }

    /// The theme object with its whole `include` chain folded in.
    ///
    /// `include` lets a theme say "the dark one, but with these changes", and
    /// the base is usually itself an edit of something else — VS Code's own
    /// Dark Modern includes Dark+, which includes Dark (Visual Studio), and the
    /// syntax colours only appear at the bottom. So this recurses, resolving
    /// each base against *its* own folder. The depth guard is for a file that
    /// includes itself.
    private static func resolved(
        from data: Data,
        at path: String,
        loader: (String) -> Data?,
        depth: Int
    ) -> [String: Any]? {
        guard let object = jsonObject(from: data) else { return nil }
        guard depth < 8, let include = object["include"] as? String else { return object }

        let basePath = resolve(include, relativeTo: path)
        guard let baseData = loader(basePath),
              let base = resolved(from: baseData, at: basePath, loader: loader, depth: depth + 1)
        else { return object }

        return layer(object, over: base)
    }

    /// The string-valued entries of a JSON object.
    ///
    /// Not a `[String: String]` cast, which is all-or-nothing: one array value
    /// among two hundred colours — and GitHub's themes have exactly that, an
    /// array under `symbolIcon.constantForeground` — would make the whole table
    /// come back empty and the theme arrive with no background at all.
    private static func stringMap(_ raw: Any?) -> [String: String] {
        guard let object = raw as? [String: Any] else { return [:] }
        return object.compactMapValues { $0 as? String }
    }

    /// Drops a colour that can't be seen. VS Code themes routinely set
    /// `editor.lineHighlightBackground` to `#00000000` to switch the highlight
    /// off, and adopting that would make a role silently invisible.
    private static func usable(_ hex: String?) -> String? {
        guard let hex, let color = NSColor(themeHex: hex) else { return nil }
        return color.alphaComponent > 0.02 ? hex : nil
    }

    // MARK: - Where each role comes from

    /// The `colors` keys that answer for each canvas role, best first.
    private static let chromeKeys: [(ThemeRole, [String])] = [
        (.background, ["editor.background", "editorPane.background", "tab.activeBackground"]),
        (.foreground, ["editor.foreground", "foreground"]),
        (.caret, ["editorCursor.foreground", "editorCursor.background"]),
        (.selection, ["editor.selectionBackground", "editor.inactiveSelectionBackground", "selection.background"]),
        (.currentLine, ["editor.lineHighlightBackground", "editor.rangeHighlightBackground"]),
        (.gutterBackground, ["editorGutter.background"]),
        (.gutterForeground, ["editorLineNumber.foreground"]),
        (.gutterActiveForeground, ["editorLineNumber.activeForeground"]),
        (.separator, ["editorIndentGuide.background", "editorGroup.border", "panel.border"]),
        (
            .accent,
            [
                "textLink.foreground", "editorCursor.foreground", "focusBorder",
                "button.background", "activityBarBadge.background", "progressBar.background",
            ]
        ),
    ]

    /// The TextMate scopes that answer for each syntax role, most specific
    /// first. Order is the whole design here: `storage.type` is last on the
    /// `type` list because plenty of themes colour it as a keyword, and
    /// `constant` is last on `number` because it's the catch-all above it.
    private static let scopeQueries: [(ThemeRole, [String])] = [
        (.keyword, ["keyword.control", "keyword", "storage.modifier", "storage.type", "storage"]),
        (.string, ["string.quoted.double", "string.quoted", "string"]),
        (.comment, ["comment.line.double-slash", "comment.line", "comment.block", "comment"]),
        (.number, ["constant.numeric", "constant.numeric.integer", "constant"]),
        (
            .type,
            [
                "entity.name.type", "entity.name.class", "support.type", "support.class",
                "entity.name.type.class", "storage.type",
            ]
        ),
        (.function, ["entity.name.function", "support.function", "meta.function-call", "variable.function"]),
        (.variable, ["variable.other.readwrite", "variable.other", "variable", "meta.definition.variable.name"]),
        (.constant, ["constant.language", "constant.language.boolean", "support.constant", "constant.other"]),
        (.operator, ["keyword.operator", "keyword.operator.arithmetic", "punctuation.separator"]),
        (.punctuation, ["punctuation.definition.parameters", "punctuation.section", "punctuation", "meta.brace"]),
        (.attribute, ["entity.other.attribute-name", "support.type.property-name", "meta.attribute"]),
        (.tag, ["entity.name.tag", "meta.tag"]),
        (.heading, ["markup.heading", "entity.name.section"]),
        (.link, ["markup.underline.link", "string.other.link", "markup.link"]),
    ]

    // MARK: - Scope table

    /// The theme's `tokenColors`, indexed so a scope can be looked up.
    private struct ScopeTable {
        private struct Rule {
            let scope: String
            let color: String?
            let style: TokenStyle?
            let order: Int
            /// True when the selector was a descendant one — `meta.tag.sgml
            /// string` rather than plain `string`. Without a scope stack we
            /// can't tell whether we're inside the ancestor, so such a rule is
            /// only ever a last resort.
            let contextual: Bool
        }

        private var rules: [Rule] = []
        private(set) var globalBackground: String?
        private(set) var globalForeground: String?

        init(_ raw: Any?) {
            guard let entries = raw as? [Any] else { return }
            for (index, element) in entries.enumerated() {
                guard let entry = element as? [String: Any],
                      let settings = entry["settings"] as? [String: Any]
                else { continue }
                let color = settings["foreground"] as? String
                // An explicit empty `fontStyle` means "plain", which is a real
                // answer — it's how a theme un-italicises an inherited rule.
                let style = (settings["fontStyle"] as? String).map(TokenStyle.init(fontStyle:))

                let scopes = scopeList(entry["scope"])
                if scopes.isEmpty {
                    // The scope-less rule is the global one: the canvas, for a
                    // theme written in TextMate's shape.
                    globalForeground = globalForeground ?? color
                    globalBackground = globalBackground ?? settings["background"] as? String
                    continue
                }
                for (scope, contextual) in scopes {
                    rules.append(
                        Rule(scope: scope, color: color, style: style, order: index, contextual: contextual)
                    )
                }
            }
        }

        /// The rule that best claims `query`, or nil.
        ///
        /// Matches are ranked in tiers, best first:
        ///
        /// 1. the query exactly (`string` for `string`),
        /// 2. an ancestor of it (`string` for `string.quoted.double`),
        /// 3. something narrower than it (`string.quoted.double` for `string`),
        /// 4. any of the above, but written as a descendant selector.
        ///
        /// Within a tier the more specific scope wins, and between equals the
        /// later rule wins — which is how VS Code resolves it too.
        ///
        /// The tiers are the whole point. Quiet Light colours
        /// `meta.tag.sgml.doctype string` grey, and that rule comes after its
        /// real `string` rule; treat the two as equals and every string in the
        /// theme comes out grey.
        ///
        /// `strict` restricts the answer to the first two tiers, so a caller
        /// can ask every scope it knows for a confident answer before settling
        /// for a guess.
        func lookup(_ query: String, strict: Bool) -> (color: String?, style: TokenStyle?)? {
            var best: Rule?
            var bestScore = 0

            for rule in rules {
                let tier: Int
                if rule.scope == query {
                    tier = 4
                } else if query.hasPrefix(rule.scope + ".") {
                    tier = 3
                } else if rule.scope.hasPrefix(query + ".") {
                    tier = 2
                } else {
                    continue
                }

                let ranked = rule.contextual ? 1 : tier
                if strict, ranked < 3 { continue }

                let score = ranked * 1000 + min(rule.scope.count, 999)
                if score > bestScore || (score == bestScore && rule.order >= (best?.order ?? -1)) {
                    best = rule
                    bestScore = score
                }
            }

            guard let best, best.color != nil || best.style != nil else { return nil }
            return (best.color, best.style)
        }

        /// `scope` is a string, a comma-separated string, or an array of either.
        /// A descendant selector (`meta.function entity.name`) is reduced to its
        /// last component — the scope actually being coloured — and flagged, so
        /// the ranking can hold it at arm's length.
        private func scopeList(_ raw: Any?) -> [(scope: String, contextual: Bool)] {
            let pieces: [String] = switch raw {
            case let text as String: text.components(separatedBy: ",")
            case let list as [Any]: list.compactMap { $0 as? String }.flatMap { $0.components(separatedBy: ",") }
            default: []
            }
            return pieces.compactMap { piece in
                let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                let parts = trimmed.split(separator: " ")
                guard let last = parts.last else { return nil }
                return (String(last), parts.count > 1)
            }
        }
    }

    // MARK: - Semantic tokens

    /// The theme's `semanticTokenColors`, which names language-server token
    /// kinds (`function`, `class`, `parameter`) rather than TextMate scopes.
    private struct SemanticTable {
        private var colors: [String: String] = [:]

        init(_ raw: Any?) {
            guard let object = raw as? [String: Any] else { return }
            for (key, value) in object {
                // A value is either a colour or a settings object.
                let hex = (value as? String) ?? ((value as? [String: Any])?["foreground"] as? String)
                guard let hex else { continue }
                // Keys carry modifiers after a dot — `variable.readonly`. The
                // base kind is what we match on.
                colors[String(key.split(separator: ".").first ?? "")] = hex
            }
        }

        func color(for role: ThemeRole) -> String? {
            let kinds: [String] = switch role {
            case .function: ["function", "method", "macro"]
            case .type: ["class", "type", "struct", "enum", "interface", "typeParameter"]
            case .variable: ["variable", "parameter", "property", "member"]
            case .keyword: ["keyword", "modifier"]
            case .string: ["string"]
            case .comment: ["comment"]
            case .number: ["number"]
            case .constant: ["enumMember"]
            case .operator: ["operator"]
            case .tag: ["namespace"]
            default: []
            }
            return kinds.lazy.compactMap { colors[$0] }.first
        }
    }

    // MARK: - .tmTheme

    /// TextMate's own format: a plist whose `settings` array is the same idea as
    /// `tokenColors`, with the canvas in the one entry that has no scope.
    private static func tmTheme(at url: URL) throws -> EditorTheme {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let settings = plist["settings"] as? [[String: Any]]
        else { throw ImportError.unreadable(url.lastPathComponent) }

        // Re-shaped into the JSON theme's vocabulary so one code path resolves
        // both. The scope table already speaks TextMate.
        let scopes = ScopeTable(settings.map { entry -> [String: Any] in
            var rebuilt: [String: Any] = ["settings": entry["settings"] ?? [:]]
            if let scope = entry["scope"] { rebuilt["scope"] = scope }
            return rebuilt
        })

        let global = settings.first { $0["scope"] == nil }?["settings"] as? [String: String] ?? [:]
        var colors: [ThemeRole: String] = [:]
        var styles: [ThemeRole: TokenStyle] = [:]

        colors[.background] = usable(global["background"])
        colors[.foreground] = usable(global["foreground"])
        colors[.caret] = usable(global["caret"])
        colors[.selection] = usable(global["selection"])
        colors[.currentLine] = usable(global["lineHighlight"])
        colors[.gutterForeground] = usable(global["invisibles"])

        for (role, queries) in scopeQueries {
            let match = queries.lazy.compactMap { scopes.lookup($0, strict: true) }.first
                ?? queries.lazy.compactMap { scopes.lookup($0, strict: false) }.first
            guard let match else { continue }
            if let hex = usable(match.color) { colors[role] = hex }
            if let style = match.style { styles[role] = style }
        }

        let name = plist["name"] as? String ?? url.deletingPathExtension().lastPathComponent
        let luminance = colors[.background].flatMap { NSColor(themeHex: $0) }?.relativeLuminance ?? 0
        return EditorTheme(
            id: slug(name),
            name: name,
            author: plist["author"] as? String ?? "",
            isDark: luminance < 0.5,
            colors: colors.compactMapValues { $0 },
            styles: styles
        )
    }

    // MARK: - JSONC

    /// VS Code theme files are JSON with comments and trailing commas — the
    /// dialect its own settings files use. `JSONSerialization` won't touch
    /// either, so both are stripped first.
    private static func jsonObject(from data: Data) -> [String: Any]? {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return object
        }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let cleaned = Data(stripTrailingCommas(stripComments(text)).utf8)
        return try? JSONSerialization.jsonObject(with: cleaned) as? [String: Any]
    }

    private static func stripComments(_ source: String) -> String {
        var output = String()
        output.reserveCapacity(source.count)

        var inString = false
        var escaped = false
        var index = source.startIndex

        while index < source.endIndex {
            let character = source[index]

            if inString {
                output.append(character)
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
                index = source.index(after: index)
                continue
            }

            if character == "\"" {
                inString = true
                output.append(character)
                index = source.index(after: index)
                continue
            }

            let next = source.index(after: index)
            if character == "/", next < source.endIndex {
                if source[next] == "/" {
                    // `isNewline`, not `== "\n"`. Swift reads CRLF as a single
                    // Character `"\r\n"`, which is not equal to `"\n"` — and a
                    // line comment in a Windows-authored theme file would
                    // otherwise swallow the rest of the file.
                    while index < source.endIndex, !source[index].isNewline {
                        index = source.index(after: index)
                    }
                    continue
                }
                if source[next] == "*" {
                    index = source.index(after: next)
                    while index < source.endIndex {
                        let after = source.index(after: index)
                        if source[index] == "*", after < source.endIndex, source[after] == "/" {
                            index = source.index(after: after)
                            break
                        }
                        index = after
                    }
                    continue
                }
            }

            output.append(character)
            index = source.index(after: index)
        }
        return output
    }

    private static func stripTrailingCommas(_ source: String) -> String {
        var output = String()
        output.reserveCapacity(source.count)

        var inString = false
        var escaped = false
        var index = source.startIndex

        while index < source.endIndex {
            let character = source[index]

            if inString {
                output.append(character)
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
                index = source.index(after: index)
                continue
            }

            if character == "\"" {
                inString = true
                output.append(character)
                index = source.index(after: index)
                continue
            }

            if character == "," {
                // Look past the whitespace: a comma that closes a container is
                // the one JSON refuses.
                var lookahead = source.index(after: index)
                while lookahead < source.endIndex, source[lookahead].isWhitespace {
                    lookahead = source.index(after: lookahead)
                }
                if lookahead < source.endIndex, source[lookahead] == "}" || source[lookahead] == "]" {
                    index = source.index(after: index)
                    continue
                }
            }

            output.append(character)
            index = source.index(after: index)
        }
        return output
    }

    // MARK: - Merging and paths

    /// `child` laid over `base`, the way `include` means it: the child's colours
    /// win key by key, and its token rules are appended so they resolve later —
    /// which, by the specificity rule, is how they override.
    private static func layer(_ child: [String: Any], over base: [String: Any]) -> [String: Any] {
        var merged = base

        for (key, value) in child where key != "colors" && key != "tokenColors" && key != "semanticTokenColors" {
            merged[key] = value
        }

        let baseColors = base["colors"] as? [String: Any] ?? [:]
        let childColors = child["colors"] as? [String: Any] ?? [:]
        if !baseColors.isEmpty || !childColors.isEmpty {
            merged["colors"] = baseColors.merging(childColors) { _, new in new }
        }

        let baseTokens = base["tokenColors"] as? [Any] ?? []
        let childTokens = child["tokenColors"] as? [Any] ?? []
        if !baseTokens.isEmpty || !childTokens.isEmpty {
            merged["tokenColors"] = baseTokens + childTokens
        }

        let baseSemantic = base["semanticTokenColors"] as? [String: Any] ?? [:]
        let childSemantic = child["semanticTokenColors"] as? [String: Any] ?? [:]
        if !baseSemantic.isEmpty || !childSemantic.isEmpty {
            merged["semanticTokenColors"] = baseSemantic.merging(childSemantic) { _, new in new }
        }

        return merged
    }

    /// An `include` path, resolved against the including file and flattened, so
    /// the same string works for a folder on disk and an entry in a ZIP.
    private static func resolve(_ include: String, relativeTo path: String) -> String {
        let directory = (path as NSString).deletingLastPathComponent
        let combined = directory.isEmpty ? include : directory + "/" + include
        return normalized(combined)
    }

    private static func normalized(_ path: String) -> String {
        var parts: [String] = []
        for component in path.components(separatedBy: "/") {
            switch component {
            case "", ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(component)
            }
        }
        return parts.joined(separator: "/")
    }

    /// A stable, filename-safe id from a theme's name.
    static func slug(_ name: String) -> String {
        let lowered = name.lowercased()
        var result = ""
        var lastWasDash = false
        for character in lowered {
            if character.isLetter || character.isNumber {
                result.append(character)
                lastWasDash = false
            } else if !lastWasDash, !result.isEmpty {
                result.append("-")
                lastWasDash = true
            }
        }
        while result.hasSuffix("-") { result.removeLast() }
        return result.isEmpty ? "imported-theme" : result
    }
}

// MARK: - Finding what's already installed

extension VSCodeThemeImporter {
    /// A theme found in an editor already on this Mac.
    struct DiscoveredTheme: Identifiable, Hashable, Sendable {
        let id: String
        let name: String
        /// Which editor it was found in — "Cursor", "VS Code", and so on.
        let editor: String
        /// The extension it belongs to, for telling two "Dark+" apart.
        let package: String
        let isDark: Bool
        let url: URL
    }

    /// Every theme installed in VS Code, Cursor, or their relatives.
    ///
    /// Both keep unpacked extensions in a folder in the home directory, and both
    /// ship a set inside the app bundle. Reading them is just reading files —
    /// nothing is launched, and nothing is written.
    static func installedThemes() -> [DiscoveredTheme] {
        var found: [DiscoveredTheme] = []
        var seen = Set<String>()

        for location in searchLocations() {
            guard let folders = try? FileManager.default.contentsOfDirectory(
                at: location.url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for folder in folders.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let manifest = folder.appendingPathComponent("package.json")
                guard let data = try? Data(contentsOf: manifest),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }

                let strings = localizedStrings(
                    try? Data(contentsOf: folder.appendingPathComponent("package.nls.json"))
                )
                let package = (object["displayName"] as? String)
                    .map { localized($0, using: strings, fallback: folder.lastPathComponent) }
                    ?? (object["name"] as? String)
                    ?? folder.lastPathComponent

                for entry in declaredThemes(in: object, strings: strings) {
                    let file = URL(fileURLWithPath: entry.path, relativeTo: folder).standardizedFileURL
                    guard FileManager.default.fileExists(atPath: file.path) else { continue }
                    let key = location.name + "|" + entry.label + "|" + file.path
                    guard seen.insert(key).inserted else { continue }
                    found.append(
                        DiscoveredTheme(
                            id: key,
                            name: entry.label,
                            editor: location.name,
                            package: package,
                            isDark: entry.isDark,
                            url: file
                        )
                    )
                }
            }
        }

        return found.sorted {
            ($0.editor, $0.name.lowercased()) < ($1.editor, $1.name.lowercased())
        }
    }

    private static func searchLocations() -> [(name: String, url: URL)] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var locations: [(String, URL)] = [
            ("VS Code", home.appendingPathComponent(".vscode/extensions")),
            ("VS Code Insiders", home.appendingPathComponent(".vscode-insiders/extensions")),
            ("VSCodium", home.appendingPathComponent(".vscode-oss/extensions")),
            ("Cursor", home.appendingPathComponent(".cursor/extensions")),
            ("Windsurf", home.appendingPathComponent(".windsurf/extensions")),
        ]

        // The themes each editor ships with live inside its own bundle.
        let bundled: [(String, String)] = [
            ("VS Code", "/Applications/Visual Studio Code.app"),
            ("VS Code Insiders", "/Applications/Visual Studio Code - Insiders.app"),
            ("Cursor", "/Applications/Cursor.app"),
            ("VSCodium", "/Applications/VSCodium.app"),
            ("Windsurf", "/Applications/Windsurf.app"),
        ]
        for (name, path) in bundled {
            locations.append((name, URL(fileURLWithPath: path + "/Contents/Resources/app/extensions")))
        }

        return locations.filter { FileManager.default.fileExists(atPath: $0.1.path) }
    }
}
