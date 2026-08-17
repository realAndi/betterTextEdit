import AppKit

/// Flattens an `NSAttributedString` — the shape AppKit hands back after reading
/// a Word, Rich Text, OpenDocument, or web-archive file — into Markdown.
///
/// Word documents don't survive the trip as *styled* text in a plain-text
/// editor, so the goal is to preserve structure rather than appearance:
/// headings, lists, tables, links, and emphasis all have Markdown spellings.
/// Everything else (colours, fonts, spacing, floating images) is dropped.
///
/// Headings are recovered by size rather than by style name: AppKit's readers
/// don't surface Word's paragraph-style names, so the converter finds the
/// document's dominant body size and treats anything meaningfully larger — or
/// short and bold — as a heading.
enum RichTextMarkdown {
    static func convert(_ source: NSAttributedString) -> String {
        Converter(source).run()
    }
}

// MARK: - Converter

private final class Converter {
    private struct Paragraph {
        var range: NSRange
        /// `range` minus any bullet or number that was baked into the text.
        var contentRange: NSRange
        var plain: String
        var maxFontSize: CGFloat
        var isBold: Bool
        var isMonospaced: Bool
        var lists: [NSTextList]
        /// Set when the marker was literal text rather than a real text list.
        var literalListIsOrdered: Bool?
        var cell: NSTextTableBlock?
        var table: NSTextTable?

        var isListItem: Bool {
            !lists.isEmpty || literalListIsOrdered != nil
        }
    }

    private let source: NSAttributedString
    private let string: NSString
    private var paragraphs: [Paragraph] = []
    private var bodyFontSize: CGFloat = 12
    /// Every font size used for a heading, largest first. A paragraph's rank in
    /// this list is its heading level, which holds up whatever sizes a
    /// particular document happens to use.
    private var headingSizes: [CGFloat] = []

    init(_ source: NSAttributedString) {
        self.source = source
        string = source.string as NSString
        scan()
    }

    // MARK: Scanning

    private func scan() {
        var sizeHistogram: [CGFloat: Int] = [:]

        string.enumerateSubstrings(
            in: NSRange(location: 0, length: string.length),
            options: [.byParagraphs, .substringNotRequired]
        ) { _, range, _, _ in
            var maxSize: CGFloat = 0
            var bold = true
            var monospaced = true
            var sawText = false

            self.source.enumerateAttributes(in: range, options: []) { attributes, subrange, _ in
                let text = self.string.substring(with: subrange)
                guard text.contains(where: { !$0.isWhitespace && $0 != "\u{FFFC}" }) else { return }
                sawText = true

                let font = attributes[.font] as? NSFont
                let traits = font?.fontDescriptor.symbolicTraits ?? []
                let size = (font?.pointSize ?? 12).rounded()

                maxSize = max(maxSize, size)
                bold = bold && traits.contains(.bold)
                monospaced = monospaced && traits.contains(.monoSpace)
                sizeHistogram[size, default: 0] += text.count
            }

            let style = self.source.length > range.location
                ? self.source.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
                : nil
            let cell = style?.textBlocks.compactMap { $0 as? NSTextTableBlock }.last
            let lists = style?.textLists ?? []
            let marker = self.marker(in: range, hasTextList: !lists.isEmpty)

            let contentRange = NSRange(
                location: range.location + (marker?.length ?? 0),
                length: range.length - (marker?.length ?? 0)
            )

            self.paragraphs.append(
                Paragraph(
                    range: range,
                    contentRange: contentRange,
                    plain: self.plainText(in: contentRange),
                    maxFontSize: sawText ? maxSize : 0,
                    isBold: sawText && bold,
                    isMonospaced: sawText && monospaced,
                    lists: lists,
                    literalListIsOrdered: lists.isEmpty ? marker?.ordered : nil,
                    cell: cell,
                    table: cell?.table
                )
            )
        }

        // The most-used size across the document is the body size.
        if let dominant = sizeHistogram.max(by: { ($0.value, $0.key) < ($1.value, $1.key) })?.key, dominant > 0 {
            bodyFontSize = dominant
        }

        headingSizes = Set(
            paragraphs
                .filter { $0.table == nil && !$0.isListItem && !$0.plain.isEmpty }
                .map(\.maxFontSize)
                .filter { $0 > bodyFontSize * 1.12 }
        )
        .sorted(by: >)
        .prefix(6)
        .map { $0 }
    }

    // MARK: Literal list markers

    /// Word's own files put list markers in the paragraph style; files written
    /// by other tools — including macOS's own `.docx` writer — bake the bullet
    /// or number straight into the text, as `"\t•\t"`. Both need to come out.
    private func marker(in range: NSRange, hasTextList: Bool) -> (length: Int, ordered: Bool)? {
        let text = string.substring(with: range)
        let patterns = hasTextList
            ? [Self.embeddedMarker, Self.tabbedMarker]
            : [Self.tabbedMarker]

        for pattern in patterns {
            let match = pattern.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length))
            guard let match, match.range.location == 0 else { continue }
            // Capture group 1 is the bullet; anything else is a number or letter.
            let ordered = match.range(at: 1).location == NSNotFound
            return (match.range.length, ordered)
        }
        return nil
    }

    private static let bullets = "\u{2022}\u{25E6}\u{25AA}\u{00B7}"

    /// A marker followed by a tab — unambiguous enough to trust on any paragraph.
    private static let tabbedMarker = try! NSRegularExpression(
        pattern: "^[ \t]*(?:([\(bullets)])|\\d+[.)]?|[a-zA-Z][.)])\t"
    )

    /// A looser marker, only trusted on paragraphs already known to be list items.
    private static let embeddedMarker = try! NSRegularExpression(
        pattern: "^[ \t]*(?:([\(bullets)*+-])|\\d+[.)]|[a-zA-Z][.)])[ \t]+"
    )

    // MARK: Emitting

    func run() -> String {
        var blocks: [String] = []
        var index = 0

        while index < paragraphs.count {
            let paragraph = paragraphs[index]

            if let table = paragraph.table {
                let end = endOfRun(from: index) { $0.table === table }
                blocks.append(tableMarkdown(from: index, to: end))
                index = end
                continue
            }

            if paragraph.isListItem {
                let end = endOfRun(from: index) { $0.table == nil && $0.isListItem }
                blocks.append(listMarkdown(from: index, to: end))
                index = end
                continue
            }

            if paragraph.isMonospaced, !paragraph.plain.isEmpty {
                let end = endOfRun(from: index) { $0.table == nil && $0.isMonospaced && !$0.plain.isEmpty }
                let lines = paragraphs[index ..< end].map(\.plain)
                blocks.append("```\n" + lines.joined(separator: "\n") + "\n```")
                index = end
                continue
            }

            index += 1
            guard !paragraph.plain.isEmpty else { continue }

            if let level = headingLevel(for: paragraph) {
                blocks.append(String(repeating: "#", count: level) + " " + inline(paragraph.contentRange, suppressBold: true))
            } else {
                blocks.append(inline(paragraph.contentRange, suppressBold: false))
            }
        }

        let body = blocks.filter { !$0.isEmpty }.joined(separator: "\n\n")
        return body.isEmpty ? "" : body + "\n"
    }

    private func endOfRun(from start: Int, while matches: (Paragraph) -> Bool) -> Int {
        var end = start + 1
        while end < paragraphs.count, matches(paragraphs[end]) { end += 1 }
        return end
    }

    private func headingLevel(for paragraph: Paragraph) -> Int? {
        if let rank = headingSizes.firstIndex(of: paragraph.maxFontSize) {
            return rank + 1
        }

        // Body-sized, but short and entirely bold: a run-in heading. It sits one
        // level below the smallest heading the document actually sizes up.
        guard paragraph.isBold, paragraph.plain.count <= 90, !paragraph.plain.hasSuffix(".") else { return nil }
        return min(headingSizes.count + 1, 6)
    }

    private func listMarkdown(from start: Int, to end: Int) -> String {
        var lines: [String] = []
        var counters: [Int: Int] = [:]

        for paragraph in paragraphs[start ..< end] {
            let text = inline(paragraph.contentRange, suppressBold: false)
            guard !text.isEmpty else { continue }

            let level = max(paragraph.lists.count - 1, 0)
            counters = counters.filter { $0.key <= level }

            let marker: String
            if isOrdered(paragraph) {
                let number = (counters[level] ?? 0) + 1
                counters[level] = number
                marker = "\(number)."
            } else {
                counters[level] = nil
                marker = "-"
            }

            lines.append(String(repeating: "  ", count: level) + marker + " " + text)
        }

        return lines.joined(separator: "\n")
    }

    private func isOrdered(_ paragraph: Paragraph) -> Bool {
        if let list = paragraph.lists.last {
            let format = list.markerFormat.rawValue.lowercased()
            return format.contains("decimal") || format.contains("roman") || format.contains("alpha")
        }
        return paragraph.literalListIsOrdered ?? false
    }

    private func tableMarkdown(from start: Int, to end: Int) -> String {
        var cells: [Int: [Int: [String]]] = [:]
        var columnCount = 0
        let headerRow = paragraphs[start ..< end].compactMap { $0.cell?.startingRow }.min()

        for paragraph in paragraphs[start ..< end] {
            guard let cell = paragraph.cell else { continue }
            // A Markdown header row is already bold; keeping the source's bold
            // on top of that just adds noise.
            let text = inline(
                paragraph.contentRange,
                suppressBold: cell.startingRow == headerRow,
                escapePipes: true
            )
            guard !text.isEmpty else { continue }
            cells[cell.startingRow, default: [:]][cell.startingColumn, default: []].append(text)
            columnCount = max(columnCount, cell.startingColumn + 1)
        }

        let rowIndexes = cells.keys.sorted()
        guard !rowIndexes.isEmpty, columnCount > 0 else { return "" }

        func row(_ index: Int) -> String {
            let values = (0 ..< columnCount).map { column in
                cells[index]?[column]?.joined(separator: " ") ?? ""
            }
            return "| " + values.joined(separator: " | ") + " |"
        }

        var lines = [row(rowIndexes[0])]
        lines.append("|" + String(repeating: " --- |", count: columnCount))
        lines.append(contentsOf: rowIndexes.dropFirst().map(row))
        return lines.joined(separator: "\n")
    }

    // MARK: Inline runs

    private func inline(_ range: NSRange, suppressBold: Bool, escapePipes: Bool = false) -> String {
        var output = ""

        source.enumerateAttributes(in: range, options: []) { attributes, subrange, _ in
            let raw = self.cleaned(self.string.substring(with: subrange))
            guard !raw.isEmpty else { return }

            let leading = String(raw.prefix { $0 == " " || $0 == "\t" })
            let trailing = String(raw.reversed().prefix { $0 == " " || $0 == "\t" }.reversed())
            let core = String(raw.dropFirst(leading.count).dropLast(trailing.count))
            guard !core.isEmpty else {
                output += raw
                return
            }

            let font = attributes[.font] as? NSFont
            let traits = font?.fontDescriptor.symbolicTraits ?? []
            let monospaced = traits.contains(.monoSpace)

            var piece = monospaced ? "`\(core)`" : self.escaped(core, escapePipes: escapePipes)

            let bold = traits.contains(.bold) && !suppressBold
            let italic = traits.contains(.italic)
            if bold, italic {
                piece = "***\(piece)***"
            } else if bold {
                piece = "**\(piece)**"
            } else if italic {
                piece = "*\(piece)*"
            }

            if (attributes[.strikethroughStyle] as? Int ?? 0) != 0 {
                piece = "~~\(piece)~~"
            }

            if let destination = self.link(from: attributes[.link]), destination != core {
                piece = "[\(piece)](\(destination))"
            }

            output += leading + piece + trailing
        }

        return output
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "\n", with: "  \n")
    }

    private func plainText(in range: NSRange) -> String {
        cleaned(string.substring(with: range)).trimmingCharacters(in: .whitespaces)
    }

    /// Removes attachment placeholders and normalises the line separators Word
    /// uses for soft breaks into real newlines.
    private func cleaned(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\u{FFFC}", with: "")
            .replacingOccurrences(of: "\u{2028}", with: "\n")
            .replacingOccurrences(of: "\u{000B}", with: "\n")
            .replacingOccurrences(of: "\t", with: " ")
    }

    private func escaped(_ text: String, escapePipes: Bool) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "\\", "*", "_", "`", "[", "]":
                result.append("\\")
                result.append(character)
            case "|" where escapePipes:
                result.append("\\|")
            default:
                result.append(character)
            }
        }
        return result
    }

    private func link(from value: Any?) -> String? {
        switch value {
        case let url as URL: url.absoluteString
        case let string as String: string
        default: nil
        }
    }
}
