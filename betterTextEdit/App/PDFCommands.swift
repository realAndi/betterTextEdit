import SwiftUI

/// The PDF menu: markup, notes, and page commands, under the chords Preview
/// uses for the same things — ⌃⌘H to highlight, ⌘L and ⌘R to rotate — so
/// hands that know Preview already know these.
///
/// Delete has no shortcut on purpose. ⌘⌫ is what Preview uses, but here the
/// find field sits a click away, and in a text field ⌘⌫ means "delete to the
/// start of the line" — a menu equivalent would win, and take a page with it.
struct PDFCommands: Commands {
    @ObservedObject var model: AppModel
    @AppStorage(SettingsKey.pdfSidebarVisible) private var sidebarVisible = false

    var body: some Commands {
        CommandMenu("PDF") {
            PDFMenuItems(
                editor: model.selectedPDFEditor ?? .inert,
                isPDF: model.selectedPDFEditor != nil,
                model: model,
                sidebarVisible: $sidebarVisible
            )
        }
    }
}

/// The items themselves, in a view of their own so they can watch the
/// selected PDF's controller: whether there's a text selection and which page
/// is current change without the app model hearing about it.
private struct PDFMenuItems: View {
    @ObservedObject var editor: PDFEditingController
    let isPDF: Bool
    let model: AppModel
    @Binding var sidebarVisible: Bool

    private var canMarkUp: Bool { isPDF && editor.hasTextSelection }

    var body: some View {
        Button("Highlight") { editor.addMarkup(.highlight) }
            .keyboardShortcut("h", modifiers: [.command, .control])
            .disabled(!canMarkUp)
        Button("Underline") { editor.addMarkup(.underline) }
            .keyboardShortcut("u", modifiers: [.command, .control])
            .disabled(!canMarkUp)
        Button("Strikethrough") { editor.addMarkup(.strikeOut) }
            .disabled(!canMarkUp)
        Button("Add Note…") { editor.addNote() }
            .keyboardShortcut("n", modifiers: [.command, .control])
            .disabled(!isPDF)
        Button("Remove Markup in Selection") { editor.removeMarkupInSelection() }
            .disabled(!canMarkUp)

        Divider()

        Button("Rotate Left") { editor.rotateTargetPages(by: -90) }
            .keyboardShortcut("l", modifiers: .command)
            .disabled(!isPDF)
        Button("Rotate Right") { editor.rotateTargetPages(by: 90) }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(!isPDF)

        Divider()

        Button("Move Page Up") { editor.moveCurrentPage(by: -1) }
            .disabled(!isPDF || !editor.canMoveCurrentPageUp)
        Button("Move Page Down") { editor.moveCurrentPage(by: 1) }
            .disabled(!isPDF || !editor.canMoveCurrentPageDown)
        Button("Insert Pages from File…") { model.insertPagesIntoPDF() }
            .disabled(!isPDF)
        Button("Export Pages…") { model.exportPDFPages() }
            .disabled(!isPDF)
        Button(editor.selectedPages.count > 1 ? "Delete Selected Pages" : "Delete Page") { editor.deleteTargetPages() }
            .disabled(!isPDF || editor.pageCount <= 1)

        Divider()

        Button(sidebarVisible ? "Hide Thumbnails" : "Show Thumbnails") { sidebarVisible.toggle() }
            .disabled(!isPDF)
    }
}

extension PDFEditingController {
    /// What the menu watches when no PDF is selected: attached to nothing, so
    /// every item reads as unavailable.
    static let inert = PDFEditingController()
}
