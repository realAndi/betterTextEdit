import PDFKit
import SwiftUI

/// The strip down the left of a PDF: a thumbnail of every page, and — when the
/// document has one — its table of contents.
///
/// Thumbnails are the page commands' other half. Click one to go there; ⌘- or
/// ⇧-click to pick several, and Rotate, Delete, and Export Pages act on those
/// instead of the page on screen. Drag one to move the page.
struct PDFSidebar: View {
    @ObservedObject var editor: PDFEditingController
    let document: PDFDocument
    @ObservedObject private var themes = ThemeStore.shared

    @State private var showsContents = false
    @State private var outline: [PDFOutlineNode] = []

    var body: some View {
        VStack(spacing: 0) {
            if !outline.isEmpty {
                Picker("Show", selection: $showsContents) {
                    Text("Pages").tag(false)
                    Text("Contents").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(8)
                Divider()
            }

            if showsContents, !outline.isEmpty {
                List(outline, children: \.children) { node in
                    Text(node.label)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if let destination = node.destination { editor.go(to: destination) }
                        }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            } else {
                PDFThumbnailList(editor: editor, document: document)
            }
        }
        .frame(width: 180)
        .background(themes.current.recess)
        .onAppear { outline = PDFOutlineNode.nodes(of: document) }
        // A selection nobody can see shouldn't decide what the next command
        // does, so closing the strip lets go of it.
        .onDisappear { editor.clearPageSelection() }
    }
}

// MARK: - Thumbnails

private struct PDFThumbnailList: View {
    @ObservedObject var editor: PDFEditingController
    let document: PDFDocument

    /// Where each thumbnail sits, so a drag can tell which one it's over.
    @State private var frames: [Int: CGRect] = [:]
    @State private var dragging: Int?
    @State private var dropTarget: Int?

    static let space = "pdfThumbnails"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(0 ..< editor.pageCount, id: \.self) { index in
                        if let page = document.page(at: index) {
                            PDFThumbnailCell(
                                editor: editor,
                                page: page,
                                index: index,
                                isCurrent: index == editor.currentPageIndex,
                                isSelected: editor.selectedPages.contains(page),
                                isDropTarget: dropTarget == index && dragging != index,
                                isDragged: dragging == index,
                                revision: editor.pageLayoutRevision
                            )
                            .id(index)
                            .onGeometryChange(for: CGRect.self) {
                                $0.frame(in: .named(Self.space))
                            } action: {
                                frames[index] = $0
                            }
                            .gesture(drag(from: index, page: page))
                        }
                    }
                }
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
                .coordinateSpace(.named(Self.space))
            }
            // Keep the page being read in view as the document scrolls.
            .onChange(of: editor.currentPageIndex) { _, index in
                guard dragging == nil else { return }
                proxy.scrollTo(index)
            }
        }
    }

    /// Reordering is a `DragGesture` with a threshold rather than `onDrag`,
    /// for the reason the tab strip gives: `onDrag` loses to a tap gesture on
    /// the same view and never starts, while a drag that needs movement leaves
    /// a plain click to the tap. The page moves once, on release — moving it at
    /// every boundary crossed would leave a trail of undo steps behind.
    private func drag(from index: Int, page: PDFPage) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named(Self.space))
            .onChanged { value in
                dragging = index
                dropTarget = frames.first { $0.value.minY <= value.location.y && value.location.y <= $0.value.maxY }?.key
            }
            .onEnded { _ in
                if let target = dropTarget, target != index, let destination = document.page(at: target) {
                    editor.movePage(page, toPositionOf: destination)
                }
                dragging = nil
                dropTarget = nil
            }
    }
}

private struct PDFThumbnailCell: View {
    let editor: PDFEditingController
    let page: PDFPage
    let index: Int
    let isCurrent: Bool
    let isSelected: Bool
    let isDropTarget: Bool
    let isDragged: Bool
    /// Not read directly: it's here so a rotated or marked-up page counts as a
    /// change to this cell, and its picture is drawn again.
    let revision: Int

    /// Drawn at twice the size it's shown, for Retina screens.
    private static let pixelSize = CGSize(width: 232, height: 300)

    var body: some View {
        VStack(spacing: 4) {
            Image(nsImage: editor.thumbnail(for: page, size: Self.pixelSize))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 116, maxHeight: 150)
                .shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)
                .padding(5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isSelected ? Color.accentColor.opacity(0.3) : .clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(outline, lineWidth: 2)
                )

            Text("\(index + 1)")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(isCurrent ? .primary : .secondary)
        }
        .opacity(isDragged ? 0.45 : 1)
        .contentShape(Rectangle())
        .onTapGesture {
            let modifiers = NSEvent.modifierFlags
            editor.selectThumbnail(
                page,
                extending: modifiers.contains(.shift),
                toggling: modifiers.contains(.command)
            )
        }
        .contextMenu {
            Button("Rotate Left") { prepare(); editor.rotateTargetPages(by: -90) }
            Button("Rotate Right") { prepare(); editor.rotateTargetPages(by: 90) }
            Divider()
            Button("Export Pages…") { prepare(); AppModel.shared.exportPDFPages() }
            Divider()
            Button(editor.selectedPages.count > 1 && isSelected ? "Delete Pages" : "Delete Page", role: .destructive) {
                prepare()
                editor.deleteTargetPages()
            }
            .disabled(editor.pageCount <= 1)
        }
        .help("Page \(index + 1)")
    }

    private var outline: Color {
        if isDropTarget { return .accentColor }
        if isCurrent, !isSelected { return .accentColor.opacity(0.55) }
        return .clear
    }

    /// A right-click on a page outside the selection means that page, the way
    /// it does in Finder.
    private func prepare() {
        if !isSelected {
            editor.selectThumbnail(page, extending: false, toggling: false)
        }
    }
}

// MARK: - Table of contents

/// One entry in a PDF's table of contents, copied out of `PDFOutline` into
/// something a SwiftUI `List` can walk.
struct PDFOutlineNode: Identifiable {
    let id = UUID()
    let label: String
    let destination: PDFDestination?
    let children: [PDFOutlineNode]?

    /// A hostile or broken outline can nest or repeat without end, so the walk
    /// is bounded on both axes.
    private static let maximumDepth = 16
    private static let maximumNodes = 5000

    @MainActor
    static func nodes(of document: PDFDocument) -> [PDFOutlineNode] {
        guard let root = document.outlineRoot else { return [] }
        var budget = maximumNodes
        return children(of: root, depth: 0, budget: &budget)
    }

    @MainActor
    private static func children(of item: PDFOutline, depth: Int, budget: inout Int) -> [PDFOutlineNode] {
        guard depth < maximumDepth else { return [] }
        var nodes: [PDFOutlineNode] = []
        for index in 0 ..< item.numberOfChildren {
            guard budget > 0, let child = item.child(at: index) else { break }
            budget -= 1
            let grandchildren = children(of: child, depth: depth + 1, budget: &budget)
            nodes.append(PDFOutlineNode(
                label: child.label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Untitled",
                destination: child.destination ?? (child.action as? PDFActionGoTo)?.destination,
                children: grandchildren.isEmpty ? nil : grandchildren
            ))
        }
        return nodes
    }
}
