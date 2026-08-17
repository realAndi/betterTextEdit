import AppKit
import SwiftUI
import UniformTypeIdentifiers

// The Themes section of the Settings pane.
//
// Themes are picked by looking at them, not by reading their names off a popup
// menu — so the gallery is the control. Every card is the theme actually
// painting a few lines of code, which is the only preview that tells you
// anything.

struct ThemeSettings: View {
    @ObservedObject private var themes = ThemeStore.shared
    @State private var browsing = false
    @State private var failure: ImportFailure?

    var body: some View {
        SettingsPage {
            Section("Built-in") {
                ThemeGallery(themes: BuiltInThemes.all, selection: selection)
            }

            Section("Imported") {
                if themes.imported.isEmpty {
                    Text("Themes you bring in from VS Code or Cursor appear here.")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                } else {
                    ThemeGallery(themes: themes.imported, selection: selection) { theme in
                        themes.remove(theme)
                    }
                }
            }

            Section {
                Button("Browse VS Code & Cursor Themes…") { browsing = true }
                    .help("Look through the themes already installed in the editors on this Mac")
                Button("Import Theme File…") { importFile() }
                    .help("Open a .json theme, a .vsix extension, or a .tmTheme file")
                Button("Reveal Themes Folder") { themes.revealThemesFolder() }
                    .help("Imported themes are plain JSON files you can edit by hand")
            } footer: {
                Text("Themes from VS Code, Cursor, VSCodium, and Windsurf all use the same format, "
                    + "and betterTextEdit reads any of them.")
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $browsing) {
            InstalledThemesBrowser()
        }
        .alert(
            failure?.title ?? "",
            isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } }),
            presenting: failure
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { failure in
            Text(failure.message)
        }
    }

    private var selection: Binding<String> {
        Binding(get: { themes.selectedID }, set: { themes.selectedID = $0 })
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.title = "Import Theme"
        panel.message = "Choose a VS Code or Cursor colour theme — a .json theme file, a .vsix extension, "
            + "a .tmTheme file, or an unpacked extension folder."
        panel.prompt = "Import"
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        // An unpacked extension is a folder with a package.json in it, which is
        // exactly what sits in ~/.vscode/extensions — so allow one to be picked.
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [UTType.json] + ["vsix", "tmtheme", "jsonc"].compactMap {
            UTType(filenameExtension: $0)
        }

        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        do {
            let added = try themes.importThemes(from: panel.urls)
            guard let first = added.first else {
                failure = ImportFailure(
                    title: "Nothing was imported.",
                    message: "betterTextEdit couldn’t find a colour theme in what you chose."
                )
                return
            }
            // Land on what was just imported — the point of importing a theme is
            // almost always to use it.
            themes.selectedID = first.id
        } catch {
            failure = ImportFailure(
                title: (error as? LocalizedError)?.errorDescription ?? "The theme couldn’t be imported.",
                message: (error as? LocalizedError)?.recoverySuggestion ?? error.localizedDescription
            )
        }
    }
}

/// An error worth showing in a sheet, in the shape `alert(item:)` wants.
private struct ImportFailure: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

// MARK: - The gallery

/// A grid of theme cards, as many across as will fit.
///
/// Adaptive rather than a fixed two, because the pane is as wide as the window
/// now: at 190pt a card still reads, so a wide window shows three or four and a
/// narrow one falls back to two without the cards ever going illegibly small.
private struct ThemeGallery: View {
    let themes: [EditorTheme]
    @Binding var selection: String
    var remove: ((EditorTheme) -> Void)?

    private let columns = [GridItem(.adaptive(minimum: 190), spacing: 10)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(themes) { theme in
                ThemeCard(theme: theme, selected: theme.id == selection, remove: remove)
                    .onTapGesture { selection = theme.id }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct ThemeCard: View {
    let theme: EditorTheme
    let selected: Bool
    var remove: ((EditorTheme) -> Void)?

    @State private var hovering = false

    private var resolved: ResolvedTheme { ResolvedTheme(theme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ThemeMiniature(theme: resolved)
                .frame(height: 74)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(selected ? resolved.accentColor : Color.primary.opacity(0.12), lineWidth: selected ? 2 : 1)
                }

            HStack(spacing: 5) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(0.5))
                    .imageScale(.small)

                Text(theme.name)
                    .font(.callout)
                    .fontWeight(selected ? .semibold : .regular)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 0)

                if let remove, hovering {
                    Button {
                        remove(theme)
                    } label: {
                        Image(systemName: "trash")
                            .imageScale(.small)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Remove this theme")
                }
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(theme.followsSystem ? "Follows the Light and Dark setting in System Settings" : theme.name)
    }
}

/// A theme painting a few lines of code at card size.
///
/// The sample is chosen to exercise the roles a theme differs on — a keyword, a
/// type, a call, a string, a number, and a comment. Two themes that agree on
/// keywords still look nothing alike here, which is the point.
struct ThemeMiniature: View {
    let theme: ResolvedTheme
    var scale: CGFloat = 1

    private typealias Piece = (ThemeRole, String)

    private var lines: [[Piece]] {
        [
            [(.comment, "// a quiet place to write")],
            [(.keyword, "func "), (.function, "greet"), (.punctuation, "("), (.variable, "name"), (.punctuation, ": "), (.type, "String"), (.punctuation, ") {")],
            [(.function, "  print"), (.punctuation, "("), (.string, "\"Hi, \\(name)\""), (.punctuation, ")")],
            [(.keyword, "  let "), (.variable, "count"), (.operator, " = "), (.number, "42")],
            [(.punctuation, "}")],
        ]
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            theme.backgroundColor

            VStack(alignment: .leading, spacing: 2 * scale) {
                ForEach(lines.indices, id: \.self) { index in
                    HStack(spacing: 0) {
                        Text("\(index + 1)")
                            .foregroundStyle(theme.swiftUIColor(.gutterForeground))
                            .frame(width: 12 * scale, alignment: .trailing)
                            .padding(.trailing, 5 * scale)
                        text(for: lines[index])
                        Spacer(minLength: 0)
                    }
                }
            }
            .font(.system(size: 9 * scale, design: .monospaced))
            .lineLimit(1)
            .padding(.horizontal, 7 * scale)
            .padding(.vertical, 6 * scale)
        }
    }

    /// One run of attributed text rather than an `HStack` of coloured labels,
    /// so the pieces share a baseline and clip together when the card is narrow.
    private func text(for pieces: [Piece]) -> Text {
        var line = AttributedString()
        for (role, content) in pieces {
            var piece = AttributedString(content)
            piece.foregroundColor = theme.swiftUIColor(role)

            let style = theme.style(role)
            if style.contains(.italic) || style.contains(.bold) {
                var font = Font.system(size: 9 * scale, design: .monospaced)
                if style.contains(.bold) { font = font.bold() }
                if style.contains(.italic) { font = font.italic() }
                piece.font = font
            }
            line.append(piece)
        }
        return Text(line)
    }
}

// MARK: - Browsing what's installed

/// The themes already installed in VS Code, Cursor, and their relatives.
///
/// Nothing is copied until a row is added, and nothing about the other editor
/// is touched — this reads its extensions folder and no more.
private struct InstalledThemesBrowser: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var themes = ThemeStore.shared

    @State private var found: [VSCodeThemeImporter.DiscoveredTheme] = []
    @State private var searching = true
    @State private var query = ""
    @State private var added: Set<String> = []
    @State private var failed: Set<String> = []

    private var matches: [VSCodeThemeImporter.DiscoveredTheme] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return found }
        return found.filter {
            $0.name.localizedCaseInsensitiveContains(trimmed)
                || $0.package.localizedCaseInsensitiveContains(trimmed)
                || $0.editor.localizedCaseInsensitiveContains(trimmed)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            if searching {
                progress
            } else if found.isEmpty {
                empty
            } else {
                list
            }

            Divider()

            HStack {
                if !found.isEmpty {
                    Text(matches.count == 1 ? "1 theme" : "\(matches.count) themes")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 560, height: 520)
        .task {
            // Walking several extension folders is disk work; keep it off the
            // main actor so the sheet appears straight away.
            let discovered = await Task.detached(priority: .userInitiated) {
                VSCodeThemeImporter.installedThemes()
            }.value
            found = discovered
            searching = false
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Themes on This Mac")
                .font(.headline)
            Text("Everything installed in VS Code, Cursor, VSCodium, or Windsurf. Adding one copies it "
                + "into betterTextEdit — the original is left alone.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !searching, !found.isEmpty {
                TextField("Search", text: $query)
                    .textFieldStyle(.roundedBorder)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var progress: some View {
        VStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Looking through your editors…")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var empty: some View {
        ContentUnavailableView {
            Label("No Themes Found", systemImage: "magnifyingglass")
        } description: {
            Text("betterTextEdit looked in VS Code, Cursor, VSCodium, and Windsurf and didn’t find any "
                + "installed colour themes. You can still import a theme file directly.")
        }
    }

    private var list: some View {
        List(matches) { theme in
            HStack(spacing: 10) {
                Image(systemName: theme.isDark ? "moon.fill" : "sun.max.fill")
                    .foregroundStyle(.secondary)
                    .imageScale(.small)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 1) {
                    Text(theme.name)
                        .lineLimit(1)
                    Text("\(theme.editor) · \(theme.package)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if failed.contains(theme.id) {
                    Label("Couldn’t read", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if added.contains(theme.id) {
                    Label("Added", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Button("Add") { add(theme) }
                        .controlSize(.small)
                }
            }
            .padding(.vertical, 2)
        }
        .listStyle(.inset)
    }

    private func add(_ discovered: VSCodeThemeImporter.DiscoveredTheme) {
        do {
            let imported = try themes.importThemes(from: [discovered.url])
            guard let first = imported.first else {
                failed.insert(discovered.id)
                return
            }
            added.insert(discovered.id)
            themes.selectedID = first.id
        } catch {
            failed.insert(discovered.id)
        }
    }
}
