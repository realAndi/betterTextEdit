import SwiftUI

// The File Types section of Settings.
//
// Every control here is a popup whose first entry is "Default", because that's
// what an override *is*: the absence of one is a real, chosen state and not an
// empty field. Sliders and steppers can't say "nothing" without an extra
// checkbox beside them, so they aren't used — a row either names a value or
// says Default, and that reads the same for a theme as for a font size.

struct PresetSettings: View {
    @ObservedObject private var presets = PresetStore.shared
    @ObservedObject private var themes = ThemeStore.shared

    var body: some View {
        SettingsPage {
            SettingsGroup("File Types") {
                Text("Give a kind of file its own theme, font, or layout. Anything left on Default "
                    + "follows the settings in General and Appearance, so a preset only has to say "
                    + "what's different about it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 520, alignment: .leading)

                if presets.presets.isEmpty {
                    Text("No file types have a preset yet.")
                        .foregroundStyle(.tertiary)
                        .padding(.vertical, 6)
                } else {
                    VStack(spacing: 14) {
                        ForEach(presets.presets) { preset in
                            PresetCard(preset: presets.binding(for: preset)) {
                                presets.remove(preset)
                            }
                        }
                    }
                }

                addMenu
            }
        }
    }

    private var addMenu: some View {
        Menu {
            if presets.unusedLanguages.isEmpty {
                Text("Every file type already has one")
            } else {
                ForEach(presets.unusedLanguages) { language in
                    Button(language.rawValue) { presets.add(language) }
                }
            }
        } label: {
            Label("Add File Type…", systemImage: "plus")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        // One preset per language: two would mean deciding which wins, and the
        // answer would be invisible in the list. Languages already spoken for
        // simply aren't offered.
        .disabled(presets.unusedLanguages.isEmpty)
    }
}

/// One file type's overrides.
private struct PresetCard: View {
    @Binding var preset: FileTypePreset
    let remove: () -> Void

    @ObservedObject private var themes = ThemeStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 14, alignment: .leading)], spacing: 12) {
                themePicker
                fontPicker
                sizePicker
                spacingPicker
                wrapPicker
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(themes.current.recess)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(themes.current.edge)
        )
        .frame(maxWidth: 620, alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: preset.language.symbol)
                .foregroundStyle(preset.language.tint)
                .imageScale(.small)
            Text(preset.language.rawValue)
                .fontWeight(.medium)

            if preset.isEmpty {
                Text("nothing overridden yet")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 0)

            Button(role: .destructive, action: remove) {
                Image(systemName: "trash")
                    .imageScale(.small)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Remove this preset")
        }
    }

    // MARK: Rows

    private var themePicker: some View {
        PresetField("Theme") {
            Picker("", selection: optional($preset.themeID)) {
                Text("Default").tag(String?.none)
                Divider()
                ForEach(themes.all) { theme in
                    Text(theme.name).tag(String?.some(theme.id))
                }
            }
        }
    }

    private var fontPicker: some View {
        PresetField("Font") {
            Picker("", selection: optional($preset.fontName)) {
                Text("Default").tag(String?.none)
                Divider()
                Text("System Monospaced").tag(String?.some(EditorFonts.systemMonospaced))
                ForEach(EditorFonts.available, id: \.self) { name in
                    Text(name).tag(String?.some(name))
                }
            }
        }
    }

    private var sizePicker: some View {
        PresetField("Size") {
            Picker("", selection: optional($preset.fontSize)) {
                Text("Default").tag(Double?.none)
                Divider()
                ForEach(Self.sizes, id: \.self) { size in
                    Text("\(Int(size)) pt").tag(Double?.some(size))
                }
            }
        }
    }

    private var spacingPicker: some View {
        PresetField("Line spacing") {
            Picker("", selection: optional($preset.lineSpacing)) {
                Text("Default").tag(Double?.none)
                Divider()
                ForEach(Self.spacings, id: \.value) { spacing in
                    Text(spacing.name).tag(Double?.some(spacing.value))
                }
            }
        }
    }

    private var wrapPicker: some View {
        PresetField("Wrap lines") {
            Picker("", selection: optional($preset.wordWrap)) {
                Text("Default").tag(Bool?.none)
                Divider()
                Text("On").tag(Bool?.some(true))
                Text("Off").tag(Bool?.some(false))
            }
        }
    }

    /// A handful of sizes rather than every point: this is a popup so it can
    /// offer "Default", and a popup of twenty numbers is a scroll, not a choice.
    private static let sizes: [Double] = [10, 11, 12, 13, 14, 15, 16, 18, 20, 24]

    private static let spacings: [(name: String, value: Double)] = [
        ("Tight", 0),
        ("Normal", EditorMetrics.defaultLineSpacing),
        ("Relaxed", 6),
        ("Airy", 9),
    ]

    /// Passes an optional binding through unchanged.
    ///
    /// Only here so the pickers read the same as each other — SwiftUI is happy
    /// to select over an optional as long as every tag is one too, which is
    /// what makes "Default" expressible as a tag rather than a special case.
    private func optional<Value: Hashable>(_ binding: Binding<Value?>) -> Binding<Value?> {
        binding
    }
}

/// A labelled popup inside a preset card.
private struct PresetField<Content: View>: View {
    private let title: String
    private let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
            content
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
