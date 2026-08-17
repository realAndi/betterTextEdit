import AppKit
import SwiftUI

/// A file browser for the folder the current document lives in.
///
/// Hidden by default — it appears with ⌃⌘S, or the button at the left of the
/// toolbar. Folders load their contents the first time they're opened rather
/// than up front, so pointing this at a large tree costs nothing until you go
/// looking.
struct FileSidebar: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var themes = ThemeStore.shared

    static let width: CGFloat = 240

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(width: Self.width)
        // No background of its own.
        //
        // The window's canvas already runs the full width behind this, so the
        // only way the sidebar can be *guaranteed* to match it — in every
        // surface, under every theme — is to let it through rather than paint
        // an approximation of it. Painting the system's `.sidebar` material
        // here is what made the sidebar a different colour from the editor the
        // moment a theme was chosen.
        //
        // What's left is the recess: a whisper of the theme's own canvas colour
        // laid over the window's, so the panel still reads as set back from the
        // editor without leaving the theme's palette. Shared with the tab band,
        // so the two recessed regions are the same depth.
        .background(themes.current.recess)
    }

    private var header: some View {
        HStack(spacing: 6) {
            if let root = model.sidebarRoot {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                Text(root.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(root.path(percentEncoded: false))
            } else {
                Text("No Folder")
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            Button {
                model.chooseSidebarFolder()
            } label: {
                Image(systemName: "folder.badge.gearshape")
            }
            .buttonStyle(.borderless)
            .help("Choose a folder")
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .frame(height: 30)
    }

    @ViewBuilder
    private var content: some View {
        if let root = model.sidebarRoot {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    FileRow(url: root, depth: 0, isRoot: true)
                }
                .padding(.vertical, 4)
            }
        } else {
            VStack(spacing: 10) {
                Text("Open a file, or choose a folder to browse.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Choose Folder…") { model.chooseSidebarFolder() }
                    .controlSize(.small)
            }
            .padding(16)
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }
}

// MARK: - One row

private struct FileRow: View {
    let url: URL
    let depth: Int
    var isRoot = false

    @EnvironmentObject private var model: AppModel
    @State private var expanded = false
    @State private var children: [URL]?
    @State private var hovering = false

    private var isDirectory: Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private var isOpen: Bool {
        model.documents.contains { ($0.url ?? $0.sourceURL)?.standardizedFileURL == url.standardizedFileURL }
    }

    private var isSelected: Bool {
        guard let document = model.selectedDocument else { return false }
        return (document.url ?? document.sourceURL)?.standardizedFileURL == url.standardizedFileURL
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row
            if expanded, let children {
                ForEach(children, id: \.self) { child in
                    FileRow(url: child, depth: depth + 1)
                }
            }
        }
        .onAppear {
            if isRoot {
                expanded = true
                loadChildren()
            }
        }
    }

    private var row: some View {
        HStack(spacing: 5) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(expanded ? 90 : 0))
                .frame(width: 10)
                .opacity(isDirectory ? 1 : 0)

            Image(systemName: icon)
                .imageScale(.small)
                .foregroundStyle(isDirectory ? Color.secondary : FileLanguage.detect(for: url).tint)
                .frame(width: 14)

            Text(url.lastPathComponent)
                .lineLimit(1)
                .truncationMode(.middle)
                .fontWeight(isOpen ? .medium : .regular)

            Spacer(minLength: 0)
        }
        .font(.callout)
        .padding(.leading, CGFloat(depth) * 12 + 8)
        .padding(.trailing, 8)
        .frame(height: 22)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(background)
                .padding(.horizontal, 4)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: activate)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            if isDirectory {
                Button("Use as Sidebar Folder") { model.sidebarRoot = url }
            }
        }
    }

    private var background: Color {
        if isSelected { return Color.accentColor.opacity(0.22) }
        return hovering ? Color.primary.opacity(0.06) : .clear
    }

    private var icon: String {
        if isDirectory { return expanded ? "folder.fill" : "folder" }
        return FileLanguage.detect(for: url).symbol
    }

    private func activate() {
        guard isDirectory else {
            model.open(url)
            return
        }
        expanded.toggle()
        if expanded { loadChildren() }
    }

    private func loadChildren() {
        guard children == nil else { return }
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        children = contents.sorted { left, right in
            let leftIsDirectory = (try? left.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            let rightIsDirectory = (try? right.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            if leftIsDirectory != rightIsDirectory { return leftIsDirectory }
            return left.lastPathComponent.localizedStandardCompare(right.lastPathComponent) == .orderedAscending
        }
    }
}
