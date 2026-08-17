import SwiftUI

/// A live rendering of the SVG being edited, shown beside or instead of its
/// source.
///
/// AppKit reads SVG into an `NSImage` on its own — the same path the PNG export
/// uses — so the preview is just that image, drawn over a checkerboard so any
/// transparency in the drawing reads as transparency rather than as whatever
/// happens to be behind the window.
struct SVGPreview: View {
    let svg: String

    var body: some View {
        ZStack {
            Checkerboard()
            if let image = rendered {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .padding(24)
            } else {
                ContentUnavailableView {
                    Label("Nothing to Preview", systemImage: "square.dashed")
                } description: {
                    Text("This isn’t valid SVG yet — it should contain an <svg> element with a size or viewBox.")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The parsed image, or `nil` while the markup is incomplete or invalid —
    /// which is the normal state halfway through an edit.
    private var rendered: NSImage? {
        let data = Data(svg.utf8)
        guard let image = NSImage(data: data), image.size.width > 0, image.size.height > 0 else {
            return nil
        }
        return image
    }
}

/// The grey checkerboard image editors put behind a transparent picture.
private struct Checkerboard: View {
    private let square: CGFloat = 12

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(base))
            let columns = Int(ceil(size.width / square))
            let rows = Int(ceil(size.height / square))
            for row in 0 ..< rows {
                for column in 0 ..< columns where (row + column).isMultiple(of: 2) {
                    let rect = CGRect(
                        x: CGFloat(column) * square,
                        y: CGFloat(row) * square,
                        width: square,
                        height: square
                    )
                    context.fill(Path(rect), with: .color(tint))
                }
            }
        }
        .drawingGroup()
    }

    private var base: Color { Color(nsColor: .textBackgroundColor) }
    private var tint: Color { Color(nsColor: .quaternaryLabelColor).opacity(0.5) }
}
