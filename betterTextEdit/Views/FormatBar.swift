import AppKit
import SwiftUI

/// The formatting strip above a word-processor document: typeface, size, style,
/// colour, alignment. Everything here writes into the document's own text
/// storage, so a change made in this bar survives being saved back to `.docx`
/// and opened in Word.
struct FormatBar: View {
    @ObservedObject var controller: RichTextController

    private static let commonSizes: [CGFloat] = [9, 10, 11, 12, 14, 18, 24, 36, 48, 72]

    var body: some View {
        HStack(spacing: 8) {
            familyPicker
            sizeControl

            separator
            stylePicker

            separator
            ColorPicker("Text Colour", selection: colorBinding, supportsOpacity: false)
                .labelsHidden()
                .help("Text colour")

            separator
            alignmentPicker

            Spacer(minLength: 8)

            if controller.wordCount >= 0 {
                Text("\(controller.wordCount) words")
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .frame(height: 38)
        // Floats on glass over the page rather than sitting in a ruled bar. The
        // controls inside keep their own system appearance — the SDK already
        // gives them Liquid Glass where that's right for them.
        .glassEffect(.regular, in: Chrome.shape)
        .padding(.horizontal, Chrome.inset)
        .padding(.bottom, 6)
    }

    private var separator: some View {
        Divider().frame(height: 16)
    }

    private var familyPicker: some View {
        Picker("Typeface", selection: familyBinding) {
            ForEach(controller.availableFamilies, id: \.self) { family in
                Text(family).tag(family)
            }
        }
        .labelsHidden()
        .frame(width: 170)
        .help("Typeface")
    }

    private var sizeControl: some View {
        HStack(spacing: 2) {
            Menu {
                ForEach(Self.commonSizes, id: \.self) { size in
                    Button("\(Int(size))") { controller.setSize(size) }
                }
            } label: {
                Text("\(Int(controller.fontSize.rounded()))")
                    .monospacedDigit()
                    .frame(minWidth: 22)
            }
            .frame(width: 58)

            Stepper("Size") {
                controller.nudgeSize(by: 1)
            } onDecrement: {
                controller.nudgeSize(by: -1)
            }
            .labelsHidden()
        }
        .help("Font size")
    }

    private var stylePicker: some View {
        HStack(spacing: 4) {
            styleToggle("Bold", "bold", isOn: controller.isBold) { controller.toggleBold() }
            styleToggle("Italic", "italic", isOn: controller.isItalic) { controller.toggleItalic() }
            styleToggle("Underline", "underline", isOn: controller.isUnderlined) { controller.toggleUnderline() }
        }
    }

    private func styleToggle(
        _ label: String,
        _ symbol: String,
        isOn: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Toggle(isOn: Binding(get: { isOn }, set: { _ in action() })) {
            Label(label, systemImage: symbol)
                .labelStyle(.iconOnly)
        }
        .toggleStyle(.button)
        .help(label)
    }

    private var alignmentPicker: some View {
        Picker("Alignment", selection: alignmentBinding) {
            Label("Left", systemImage: "text.alignleft").tag(NSTextAlignment.left)
            Label("Centre", systemImage: "text.aligncenter").tag(NSTextAlignment.center)
            Label("Right", systemImage: "text.alignright").tag(NSTextAlignment.right)
            Label("Justify", systemImage: "text.justify").tag(NSTextAlignment.justified)
        }
        .pickerStyle(.segmented)
        .labelStyle(.iconOnly)
        .labelsHidden()
        .fixedSize()
        .help("Alignment")
    }

    // MARK: - Bindings

    private var familyBinding: Binding<String> {
        Binding(
            get: { controller.fontFamily },
            set: { controller.setFamily($0) }
        )
    }

    private var colorBinding: Binding<Color> {
        Binding(
            get: { controller.textColor },
            set: { controller.setColor($0) }
        )
    }

    private var alignmentBinding: Binding<NSTextAlignment> {
        Binding(
            // `.natural` has no button of its own; show it as left, which is
            // what it resolves to for the languages this app ships in.
            get: { controller.alignment == .natural ? .left : controller.alignment },
            set: { controller.setAlignment($0) }
        )
    }
}
