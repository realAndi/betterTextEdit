import SwiftUI

struct MarkdownPreview: View {
    let markdown: String
    @ObservedObject private var themes = ThemeStore.shared
    @AppStorage(SettingsKey.windowSurface) private var surfaceRaw = WindowSurface.glass.rawValue

    private var blocks: [MarkdownBlock] {
        MarkdownParser.parse(markdown)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(blocks) { block in
                    MarkdownBlockView(block: block)
                }
            }
            .frame(maxWidth: 780, alignment: .leading)
            .padding(.horizontal, 44)
            .padding(.vertical, 34)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        // The preview follows the source pane exactly, so a split view reads as
        // one document rather than two panes from different apps: the theme's
        // ink either way, and a background only when the source has one. Under
        // glass both sides are clear and the window's wash shows through both.
        .foregroundStyle(themes.current.followsSystem ? Color.primary : themes.current.foregroundColor)
        .background(paintsCanvas ? themes.current.backgroundColor : Color.clear)
    }

    private var paintsCanvas: Bool {
        (WindowSurface(rawValue: surfaceRaw) ?? .glass) == .solid && !themes.current.followsSystem
    }
}

private struct MarkdownBlockView: View {
    let block: MarkdownBlock

    var body: some View {
        switch block.kind {
        case let .heading(level, text):
            VStack(alignment: .leading, spacing: 8) {
                inlineText(text)
                    .font(headingFont(level))
                    .fontWeight(level < 3 ? .bold : .semibold)
                if level <= 2 { Divider() }
            }
            .padding(.top, level == 1 ? 8 : 3)

        case let .paragraph(text):
            inlineText(text)
                .font(.body)
                .lineSpacing(4)
                .textSelection(.enabled)

        case let .quote(text):
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(.tertiary)
                    .frame(width: 3)
                inlineText(text)
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)

        case let .code(language, code):
            VStack(alignment: .leading, spacing: 0) {
                if !language.isEmpty {
                    HStack {
                        Text(language.uppercased())
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.secondary.opacity(0.08))
                    Divider()
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(code)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(14)
                }
            }
            .background(Color.secondary.opacity(0.075))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(.separator.opacity(0.6))
            }

        case let .list(items, ordered):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Text(ordered ? "\(index + 1)." : "•")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(width: 20, alignment: .trailing)
                        inlineText(item)
                            .textSelection(.enabled)
                    }
                    .font(.body)
                }
            }

        case .divider:
            Divider().padding(.vertical, 5)

        case let .table(headers, rows):
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                GridRow {
                    ForEach(headers.indices, id: \.self) { index in
                        inlineText(headers[index]).fontWeight(.semibold)
                    }
                }
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(rows.indices, id: \.self) { rowIndex in
                    GridRow {
                        ForEach(headers.indices, id: \.self) { columnIndex in
                            inlineText(rows[rowIndex].indices.contains(columnIndex) ? rows[rowIndex][columnIndex] : "")
                        }
                    }
                }
            }
            .font(.callout)
            .padding(12)
            .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
        }
    }

    /// The system type scale, used as-is. Heading levels map onto the styles
    /// macOS already ships rather than onto invented point sizes.
    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .largeTitle
        case 2: .title
        case 3: .title2
        case 4: .title3
        case 5: .headline
        default: .subheadline
        }
    }

    private func inlineText(_ source: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        if let attributed = try? AttributedString(markdown: source, options: options) {
            return Text(attributed)
        }
        return Text(source)
    }
}

private struct MarkdownBlock: Identifiable {
    enum Kind {
        case heading(level: Int, text: String)
        case paragraph(String)
        case quote(String)
        case code(language: String, code: String)
        case list(items: [String], ordered: Bool)
        case divider
        case table(headers: [String], rows: [[String]])
    }

    let id = UUID()
    let kind: Kind
}

private enum MarkdownParser {
    static func parse(_ source: String) -> [MarkdownBlock] {
        let lines = source.components(separatedBy: .newlines)
        var result: [MarkdownBlock] = []
        var index = 0

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                index += 1
                continue
            }

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let marker = String(trimmed.prefix(3))
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                index += 1
                var code: [String] = []
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(marker) {
                    code.append(lines[index])
                    index += 1
                }
                if index < lines.count { index += 1 }
                result.append(MarkdownBlock(kind: .code(language: language, code: code.joined(separator: "\n"))))
                continue
            }

            if let heading = heading(from: trimmed) {
                result.append(MarkdownBlock(kind: .heading(level: heading.level, text: heading.text)))
                index += 1
                continue
            }

            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                result.append(MarkdownBlock(kind: .divider))
                index += 1
                continue
            }

            if trimmed.hasPrefix(">") {
                var quote: [String] = []
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    guard candidate.hasPrefix(">") else { break }
                    quote.append(String(candidate.dropFirst()).trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                result.append(MarkdownBlock(kind: .quote(quote.joined(separator: " "))))
                continue
            }

            if let firstItem = listItem(from: trimmed) {
                var items = [firstItem.text]
                let ordered = firstItem.ordered
                index += 1
                while index < lines.count, let item = listItem(from: lines[index].trimmingCharacters(in: .whitespaces)), item.ordered == ordered {
                    items.append(item.text)
                    index += 1
                }
                result.append(MarkdownBlock(kind: .list(items: items, ordered: ordered)))
                continue
            }

            if index + 1 < lines.count, isTableSeparator(lines[index + 1]) {
                let headers = tableCells(line)
                index += 2
                var rows: [[String]] = []
                while index < lines.count, lines[index].contains("|"), !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                    rows.append(tableCells(lines[index]))
                    index += 1
                }
                result.append(MarkdownBlock(kind: .table(headers: headers, rows: rows)))
                continue
            }

            var paragraph = [trimmed]
            index += 1
            while index < lines.count {
                let next = lines[index].trimmingCharacters(in: .whitespaces)
                if next.isEmpty || next.hasPrefix("#") || next.hasPrefix("```") || next.hasPrefix("~~~") || next.hasPrefix(">") || listItem(from: next) != nil {
                    break
                }
                paragraph.append(next)
                index += 1
            }
            result.append(MarkdownBlock(kind: .paragraph(paragraph.joined(separator: " "))))
        }

        if result.isEmpty {
            result.append(MarkdownBlock(kind: .paragraph("Nothing to preview yet.")))
        }
        return result
    }

    private static func heading(from line: String) -> (level: Int, text: String)? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1 ... 6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return (hashes, String(line.dropFirst(hashes + 1)))
    }

    private static func listItem(from line: String) -> (ordered: Bool, text: String)? {
        if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
            return (false, String(line.dropFirst(2)))
        }
        guard let dot = line.firstIndex(of: "."), dot < line.endIndex else { return nil }
        let prefix = line[..<dot]
        let after = line.index(after: dot)
        guard !prefix.isEmpty, prefix.allSatisfy(\.isNumber), after < line.endIndex, line[after] == " " else { return nil }
        return (true, String(line[line.index(after: after)...]))
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let cells = tableCells(line)
        return !cells.isEmpty && cells.allSatisfy { cell in
            let value = cell.replacingOccurrences(of: ":", with: "").trimmingCharacters(in: .whitespaces)
            return value.count >= 3 && value.allSatisfy { $0 == "-" }
        }
    }

    private static func tableCells(_ line: String) -> [String] {
        line.trimmingCharacters(in: CharacterSet(charactersIn: "| "))
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
