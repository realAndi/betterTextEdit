import AppKit

/// Colours a text storage according to the active theme.
///
/// The rules are regular expressions applied in order, and **later rules win**.
/// That ordering is the whole design: strings are matched after keywords, and
/// comments after everything, so a keyword inside a string stays a string and a
/// URL inside a comment stays a comment. Get the order wrong and `// if this`
/// lights up the `if`.
///
/// Rules name a `ThemeRole`, never a colour. Which means the rule tables are
/// built once and shared, and a theme change is a re-run rather than a rebuild.
final class SyntaxHighlighter {
    private struct Rule {
        let pattern: String
        let options: NSRegularExpression.Options
        let role: ThemeRole
        /// Which capture group to paint. 0 is the whole match; a group is for
        /// the rules that have to match context they shouldn't colour — the
        /// `(` after a function name, say.
        let group: Int

        init(_ pattern: String, options: NSRegularExpression.Options = [], _ role: ThemeRole, group: Int = 0) {
            self.pattern = pattern
            self.options = options
            self.role = role
            self.group = group
        }
    }

    /// Compiling a regex is not free, and the highlighter re-runs on every
    /// keystroke, so the compiled forms are kept. The set of patterns is fixed
    /// and small, so this never grows without bound.
    private static let regexCache = RegexCache()

    private final class RegexCache: @unchecked Sendable {
        private var storage: [String: NSRegularExpression] = [:]
        private let lock = NSLock()

        func regex(_ pattern: String, _ options: NSRegularExpression.Options) -> NSRegularExpression? {
            let key = "\(options.rawValue)|\(pattern)"
            lock.lock()
            defer { lock.unlock() }
            if let cached = storage[key] { return cached }
            guard let compiled = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
            storage[key] = compiled
            return compiled
        }
    }

    /// The layout every line of code is laid out with.
    ///
    /// Shared with the editor's typing attributes, so text typed before the
    /// next highlight pass already sits at the right leading rather than
    /// jumping into place a moment later.
    static func paragraphStyle(font: NSFont, lineSpacing: Double) -> NSParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = CGFloat(max(lineSpacing, 0))
        paragraph.tabStops = []
        paragraph.defaultTabInterval = font.maximumAdvancement.width * 4
        return paragraph
    }

    func apply(
        to storage: NSTextStorage,
        language: FileLanguage,
        font: NSFont,
        theme: ResolvedTheme,
        lineSpacing: Double
    ) {
        let fullRange = NSRange(location: 0, length: storage.length)
        guard fullRange.length > 0 else { return }

        let paragraph = Self.paragraphStyle(font: font, lineSpacing: lineSpacing)

        storage.beginEditing()
        // Everything is reset first, which is also what clears the bold, italic,
        // and underline a previous theme may have left behind.
        storage.setAttributes([
            .font: font,
            .foregroundColor: theme.foreground,
            .paragraphStyle: paragraph,
        ], range: fullRange)

        // Keep very large files responsive; editing remains fully available.
        guard storage.length <= 2_000_000 else {
            storage.endEditing()
            return
        }

        // The rules decide the colours; the storage is only written afterwards,
        // and strictly left to right.
        //
        // This is not tidiness — it's the difference between a responsive
        // editor and a stalled one. `NSTextStorage` keeps its attributes as a
        // run list, and writing a run in the middle shifts everything after it.
        // Colouring rule-by-rule scatters writes across the whole document, so
        // each pass pays for the runs the previous passes left behind, and the
        // cost goes quadratic: on a 1.5 MB file that's several seconds. Working
        // out every colour first and then painting in order appends rather than
        // inserts, and the same file takes a tenth of a second.
        let map = roleMap(for: storage.string, in: fullRange, language: language)
        paint(map, into: storage, using: attributes(for: theme, font: font))

        storage.endEditing()
    }

    /// One byte per UTF-16 unit saying which role covers it, or `noRole`.
    ///
    /// Rules are applied in order and simply overwrite, which is what gives
    /// later rules the last word — a keyword inside a string is stamped by the
    /// keyword rule and then stamped over by the string rule.
    private func roleMap(for source: String, in fullRange: NSRange, language: FileLanguage) -> [UInt8] {
        var map = [UInt8](repeating: Self.noRole, count: fullRange.length)

        for rule in rules(for: language) {
            guard let regex = Self.regexCache.regex(rule.pattern, rule.options),
                  let code = Self.roleCodes[rule.role]
            else { continue }

            regex.enumerateMatches(in: source, range: fullRange) { match, _, _ in
                guard let match else { return }
                let range = rule.group == 0 ? match.range : match.range(at: rule.group)
                guard range.location != NSNotFound, range.length > 0 else { return }
                let end = min(range.location + range.length, map.count)
                for index in range.location ..< end {
                    map[index] = code
                }
            }
        }
        return map
    }

    /// Walks the map once, coalescing equal neighbours into the longest runs it
    /// can, and writes each run to the storage in ascending order.
    private func paint(
        _ map: [UInt8],
        into storage: NSTextStorage,
        using painted: [ThemeRole: [NSAttributedString.Key: Any]]
    ) {
        var index = 0
        while index < map.count {
            let code = map[index]
            var end = index + 1
            while end < map.count, map[end] == code { end += 1 }

            if code != Self.noRole,
               let role = Self.rolesByCode[Int(code)],
               let attributes = painted[role] {
                storage.addAttributes(attributes, range: NSRange(location: index, length: end - index))
            }
            index = end
        }
    }

    /// `0` is "no rule claimed this", so role codes start at 1.
    private static let noRole: UInt8 = 0

    private static let roleCodes: [ThemeRole: UInt8] = {
        var codes: [ThemeRole: UInt8] = [:]
        for (index, role) in ThemeRole.allCases.enumerated() {
            codes[role] = UInt8(index + 1)
        }
        return codes
    }()

    private static let rolesByCode: [Int: ThemeRole] = {
        var roles: [Int: ThemeRole] = [:]
        for (index, role) in ThemeRole.allCases.enumerated() {
            roles[index + 1] = role
        }
        return roles
    }()

    // MARK: - Turning roles into attributes

    /// The attribute dictionary each role paints with, worked out once per pass
    /// rather than once per match.
    private func attributes(for theme: ResolvedTheme, font: NSFont) -> [ThemeRole: [NSAttributedString.Key: Any]] {
        var result: [ThemeRole: [NSAttributedString.Key: Any]] = [:]
        var fonts: [Int: NSFont] = [:]

        for role in ThemeRole.allCases {
            var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: theme.color(role)]
            let style = theme.style(role)

            if !style.isEmpty {
                let variant = fonts[style.rawValue] ?? Self.variant(of: font, style: style)
                fonts[style.rawValue] = variant
                attributes[.font] = variant

                // A monospaced face often has no italic cut at all. Slanting the
                // glyphs is what keeps a theme's italic comments italic in every
                // font rather than only in the few that ship one.
                if style.contains(.italic), !variant.fontDescriptor.symbolicTraits.contains(.italic) {
                    attributes[.obliqueness] = 0.18
                }
                if style.contains(.underline) {
                    attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                }
            }
            result[role] = attributes
        }
        return result
    }

    private static func variant(of font: NSFont, style: TokenStyle) -> NSFont {
        var traits = font.fontDescriptor.symbolicTraits
        if style.contains(.bold) { traits.insert(.bold) }
        if style.contains(.italic) { traits.insert(.italic) }
        let descriptor = font.fontDescriptor.withSymbolicTraits(traits)
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }

    // MARK: - Rules

    private func rules(for language: FileLanguage) -> [Rule] {
        switch language {
        case .plainText, .richText, .pdf, .image: []
        case .markdown: Self.markdown
        case .json: Self.json
        case .html, .xml: Self.markup
        case .css: Self.css
        case .yaml, .toml, .ini: Self.config
        case .sql: Self.sql
        default: Self.code(for: language)
        }
    }

    // MARK: Markdown

    private static let markdown: [Rule] = [
        Rule("(?m)^\\s*(?:[-*+]|\\d+\\.)(?=\\s)", .operator),
        Rule("(?m)^#{1,6}\\s+.*$", .heading),
        Rule("(\\*\\*|__)(?=\\S)[\\s\\S]*?\\S\\1", .keyword),
        Rule("!?\\[[^\\]]*\\]\\([^)]*\\)", .link),
        Rule("(?m)^\\s*(?:---+|\\*\\*\\*+|___+)\\s*$", .comment),
        Rule("`{1,3}[^`]*`{1,3}", .string),
        Rule("(?m)^\\s*>.*$", .comment),
    ]

    // MARK: JSON

    private static let json: [Rule] = [
        Rule("[{}\\[\\],:]", .punctuation),
        Rule("(?<![\\w.])-?\\b\\d+(?:\\.\\d+)?(?:[eE][+-]?\\d+)?\\b", .number),
        Rule("\\b(?:true|false)\\b", .constant),
        Rule("\\bnull\\b", .keyword),
        Rule("\"(?:\\\\.|[^\"\\\\])*\"", .string),
        // After the general string rule, so a key beats the string it also is.
        Rule("\"(?:\\\\.|[^\"\\\\])*\"(?=\\s*:)", .attribute),
    ]

    // MARK: HTML and XML

    private static let markup: [Rule] = [
        Rule("</?|/?>", .punctuation),
        Rule("</?([A-Za-z_][-\\w:.]*)", .tag, group: 1),
        Rule("\\b([A-Za-z_:][-\\w:.]*)(?=\\s*=)", .attribute, group: 1),
        Rule("&[A-Za-z][A-Za-z0-9]*;|&#\\d+;", .constant),
        Rule("\"[^\"]*\"|'[^']*'", .string),
        Rule("<!--[\\s\\S]*?-->", .comment),
    ]

    // MARK: CSS

    private static let css: [Rule] = [
        Rule("(?m)^[^{}\\n]+(?=\\s*\\{)", .tag),
        Rule("[{}();:,]", .punctuation),
        Rule("([-a-zA-Z]+)(?=\\s*:)", .attribute, group: 1),
        Rule("#[0-9a-fA-F]{3,8}\\b|(?<![\\w.#])-?\\d+(?:\\.\\d+)?(?:px|em|rem|ex|ch|%|vh|vw|vmin|vmax|fr|s|ms|deg|turn)?\\b", .number),
        Rule("@[-\\w]+|!important", .keyword),
        Rule("\\b([-\\w]+)(?=\\()", .function, group: 1),
        Rule("\"[^\"]*\"|'[^']*'", .string),
        Rule("/\\*[\\s\\S]*?\\*/", .comment),
    ]

    // MARK: YAML, TOML, and config files

    private static let config: [Rule] = [
        Rule("(?m)^\\s*(?:-\\s*)?([A-Za-z0-9_.\\-\"']+)(?=\\s*[:=])", .attribute, group: 1),
        Rule("(?m)^\\s*\\[[^\\]]*\\]", .type),
        Rule("(?m)^\\s*-(?=\\s)", .operator),
        Rule("\\b(?:true|false|null|yes|no|on|off)\\b", options: .caseInsensitive, .constant),
        Rule("(?<![\\w.])-?\\b\\d+(?:\\.\\d+)?\\b", .number),
        Rule("\\$\\{[^}]*\\}|\\$[A-Za-z_]\\w*", .variable),
        Rule("\"(?:\\\\.|[^\"\\\\])*\"|'[^']*'", .string),
        Rule("(?m)(?:^|\\s)#.*$", .comment),
    ]

    // MARK: SQL

    private static let sql: [Rule] = [
        Rule("[(),;.]", .punctuation),
        Rule("\\b(?:COUNT|SUM|AVG|MIN|MAX|ROUND|ABS|COALESCE|NULLIF|CAST|CONVERT|LENGTH|SUBSTR|SUBSTRING|TRIM|UPPER|LOWER|NOW|DATE|ROW_NUMBER|RANK)\\b(?=\\s*\\()", options: .caseInsensitive, .function),
        Rule("\\b(?:SELECT|FROM|WHERE|JOIN|LEFT|RIGHT|FULL|CROSS|INNER|OUTER|ON|AS|INSERT|INTO|VALUES|UPDATE|SET|DELETE|CREATE|ALTER|DROP|TRUNCATE|TABLE|VIEW|INDEX|GROUP|ORDER|BY|HAVING|LIMIT|OFFSET|AND|OR|NOT|IS|IN|LIKE|BETWEEN|EXISTS|CASE|WHEN|THEN|ELSE|END|DISTINCT|UNION|ALL|WITH|PRIMARY|FOREIGN|KEY|REFERENCES|DEFAULT|CONSTRAINT|BEGIN|COMMIT|ROLLBACK)\\b", options: .caseInsensitive, .keyword),
        Rule("\\b(?:NULL|TRUE|FALSE)\\b", options: .caseInsensitive, .constant),
        Rule("(?<![\\w.])-?\\d+(?:\\.\\d+)?\\b", .number),
        Rule("'(?:''|[^'])*'", .string),
        Rule("\"[^\"]*\"|`[^`]*`", .variable),
        Rule("(?m)--.*$|/\\*[\\s\\S]*?\\*/", .comment),
    ]

    // MARK: Everything else

    /// Rules shared by the C-shaped languages, differing only in their keyword
    /// list and how they mark a comment. Built per language and cached, since
    /// the pattern strings are interpolated.
    private static func code(for language: FileLanguage) -> [Rule] {
        if let cached = codeCache.withLock({ $0[language] }) { return cached }

        var rules: [Rule] = [
            Rule("[{}()\\[\\];,.]", .punctuation),
            Rule("[+\\-*/%=<>!&|^~?]+", .operator),
            Rule("\\b[A-Z][A-Za-z0-9_]*\\b", .type),
            Rule("\\b([A-Za-z_]\\w*)\\s*\\(", .function, group: 1),
        ]

        if !keywords(for: language).isEmpty {
            rules.append(Rule("\\b(?:\(keywords(for: language)))\\b", .keyword))
        }
        rules.append(Rule("\\b(?:true|false|null|nil|None|True|False|undefined|NULL|nullptr)\\b", .constant))
        rules.append(Rule("(?<![\\w.])(?:0[xXbBoO][0-9a-fA-F_]+|\\d[\\d_]*(?:\\.\\d[\\d_]*)?(?:[eE][+-]?\\d+)?)\\b", .number))

        if let variable = variablePattern(for: language) {
            rules.append(Rule(variable, .variable))
        }
        if let attribute = attributePattern(for: language) {
            rules.append(Rule(attribute, .attribute))
        }

        rules.append(Rule(stringPattern(for: language), .string))
        if let comment = commentPattern(for: language) {
            rules.append(Rule(comment, .comment))
        }

        codeCache.withLock { $0[language] = rules }
        return rules
    }

    private static let codeCache = Mutex<[FileLanguage: [Rule]]>([:])

    /// A tiny lock box, so the per-language rule cache is safe to touch from
    /// whichever queue a highlight pass happens to be on.
    private final class Mutex<Value>: @unchecked Sendable {
        private var value: Value
        private let lock = NSLock()

        init(_ value: Value) { self.value = value }

        func withLock<Result>(_ body: (inout Value) -> Result) -> Result {
            lock.lock()
            defer { lock.unlock() }
            return body(&value)
        }
    }

    private static func commentPattern(for language: FileLanguage) -> String? {
        switch language.commentStyle {
        case .markup: "<!--[\\s\\S]*?-->"
        case .hash: "(?m)#.*$"
        case .doubleDash: "(?m)--.*$"
        case .slashes: "(?m)//.*$|/\\*[\\s\\S]*?\\*/"
        case .none: nil
        }
    }

    private static func stringPattern(for language: FileLanguage) -> String {
        switch language {
        case .python:
            // Triple quotes first, or a docstring falls apart into three empty
            // strings and whatever was between them.
            "\"\"\"[\\s\\S]*?\"\"\"|'''[\\s\\S]*?'''|\"(?:\\\\.|[^\"\\\\])*\"|'(?:\\\\.|[^'\\\\])*'"
        case .shell:
            "\"(?:\\\\.|[^\"\\\\])*\"|'[^']*'"
        default:
            "\"(?:\\\\.|[^\"\\\\])*\"|'(?:\\\\.|[^'\\\\])*'|`(?:\\\\.|[^`\\\\])*`"
        }
    }

    /// The sigil-carrying names some languages have — `$var`, `@ivar`, `self`.
    private static func variablePattern(for language: FileLanguage) -> String? {
        switch language {
        case .php, .shell: "\\$\\{?[A-Za-z_]\\w*\\}?"
        case .ruby: "[@$]@?[A-Za-z_]\\w*"
        default: nil
        }
    }

    /// Decorators and annotations, which sit above a declaration and read as
    /// their own thing in every theme that has an opinion about them.
    private static func attributePattern(for language: FileLanguage) -> String? {
        switch language {
        case .swift, .java, .python, .typescript, .javascript: "@[A-Za-z_][\\w.]*"
        case .rust: "#!?\\[[^\\]]*\\]"
        default: nil
        }
    }

    private static func keywords(for language: FileLanguage) -> String {
        switch language {
        case .swift:
            "actor|as|associatedtype|async|await|break|case|catch|class|continue|default|defer|deinit|do|else|enum|extension|fallthrough|fileprivate|for|func|guard|if|import|in|init|inout|internal|is|isolated|let|nonisolated|open|operator|private|protocol|public|repeat|required|rethrows|return|self|Self|some|static|struct|subscript|super|switch|throw|throws|try|typealias|var|where|while"
        case .javascript, .typescript:
            "abstract|any|as|async|await|break|case|catch|class|const|continue|debugger|declare|default|delete|do|else|enum|export|extends|finally|for|from|function|get|if|implements|import|in|instanceof|interface|keyof|let|namespace|new|of|package|private|protected|public|readonly|return|satisfies|set|static|super|switch|this|throw|try|type|typeof|var|void|while|with|yield"
        case .python:
            "and|as|assert|async|await|break|case|class|continue|def|del|elif|else|except|finally|for|from|global|if|import|in|is|lambda|match|nonlocal|not|or|pass|raise|return|try|while|with|yield"
        case .rust:
            "as|async|await|break|const|continue|crate|dyn|else|enum|extern|fn|for|if|impl|in|let|loop|match|mod|move|mut|pub|ref|return|self|Self|static|struct|super|trait|type|unsafe|use|where|while"
        case .go:
            "break|case|chan|const|continue|default|defer|else|fallthrough|for|func|go|goto|if|import|interface|map|package|range|return|select|struct|switch|type|var"
        case .java, .cFamily:
            "abstract|auto|bool|break|byte|case|catch|char|class|const|constexpr|continue|default|delete|do|double|else|enum|explicit|extends|extern|final|finally|float|for|friend|goto|if|implements|import|inline|instanceof|int|interface|long|namespace|new|noexcept|operator|override|package|private|protected|public|register|return|short|signed|sizeof|static|string|struct|super|switch|template|this|throw|throws|try|typedef|typename|union|unsigned|using|var|virtual|void|volatile|while"
        case .shell:
            "case|do|done|elif|else|esac|eval|exec|exit|export|fi|for|function|if|in|local|readonly|return|select|shift|source|then|time|trap|unset|until|while"
        case .ruby:
            "alias|and|begin|break|case|class|def|defined?|do|else|elsif|end|ensure|for|if|in|module|next|not|or|redo|require|require_relative|rescue|retry|return|self|super|then|undef|unless|until|when|while|yield"
        case .php:
            "abstract|and|array|as|break|callable|case|catch|class|clone|const|continue|declare|default|do|echo|else|elseif|empty|enum|extends|final|finally|fn|for|foreach|function|global|if|implements|include|include_once|instanceof|insteadof|interface|isset|list|match|namespace|new|or|print|private|protected|public|readonly|require|require_once|return|static|switch|throw|trait|try|unset|use|var|while|yield"
        case .lua:
            "and|break|do|else|elseif|end|for|function|goto|if|in|local|not|or|repeat|return|then|until|while"
        default:
            ""
        }
    }
}
