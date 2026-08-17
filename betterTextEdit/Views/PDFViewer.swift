import PDFKit
import SwiftUI

/// Shows a PDF as a PDF.
///
/// Anything that flattens a PDF to text throws away the part that took the
/// effort — the typography, the spacing, the colour, the figures. PDFKit
/// renders the pages exactly as they were authored, with selection, search, and
/// zoom included. Turning the text into something editable is a separate,
/// deliberate step.
///
/// Zoom works the way it does for images: 0 means "fit the window" and re-fits
/// as the window resizes, and any other value is a fixed multiple of the page's
/// own size that stays put. The bar underneath is the same one, so the two
/// viewers behave identically.
struct PDFViewer: View {
    let document: PDFDocument
    @Binding var zoom: Double

    /// What PDFKit is actually showing, which is not always what `zoom` says:
    /// under "fit" the scale moves on its own as the window resizes, and a
    /// pinch changes it without going through us.
    @State private var scale: Double = 1

    private static let limits = 0.05 ... 20.0
    private static let step = 1.25

    var body: some View {
        VStack(spacing: 0) {
            PDFCanvas(document: document, zoom: $zoom, scale: $scale)
            Divider()
            controls
        }
    }

    private func clamped(_ value: Double) -> Double {
        min(max(value, Self.limits.lowerBound), Self.limits.upperBound)
    }

    /// Zooms by a factor of what's on screen, so stepping up out of "fit"
    /// carries on from the size the page was actually being shown at.
    private func zoom(by factor: Double) {
        zoom = clamped(scale * factor)
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 12)

            Button {
                zoom(by: 1 / Self.step)
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .help("Zoom out")
            .disabled(scale <= Self.limits.lowerBound)

            Text("\(Int((scale * 100).rounded()))%")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 54)

            Button {
                zoom(by: Self.step)
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .help("Zoom in")
            .disabled(scale >= Self.limits.upperBound)

            Button("Fit") { zoom = 0 }
                .disabled(zoom == 0)
                .help("Resize the page to the window, and keep it there")

            Button("100%") { zoom = 1 }
                .disabled(zoom == 1)
                .help("The page at its authored size")
        }
        .font(.subheadline)
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .frame(height: 34)
    }
}

/// The PDFKit view itself.
private struct PDFCanvas: NSViewRepresentable {
    let document: PDFDocument
    @Binding var zoom: Double
    @Binding var scale: Double

    func makeCoordinator() -> Coordinator {
        Coordinator(zoom: $zoom, scale: $scale)
    }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.document = document
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
        view.autoScales = true
        view.backgroundColor = .underPageBackgroundColor

        // PDFKit does its own pinch handling, and does it well — page-aware and
        // properly centred. Rather than fight it with a gesture of our own, we
        // listen for the result and adopt it.
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.scaleChanged),
            name: .PDFViewScaleChanged,
            object: view
        )
        DispatchQueue.main.async { scale = view.scaleFactor }
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        context.coordinator.zoom = $zoom
        context.coordinator.scale = $scale

        if view.document !== document {
            view.document = document
            view.autoScales = true
        }

        // 0 is "fit", which is exactly what `autoScales` does — including
        // re-fitting when the window changes size.
        if zoom > 0 {
            view.autoScales = false
            if abs(view.scaleFactor - zoom) > 0.001 {
                view.scaleFactor = zoom
            }
        } else if !view.autoScales {
            view.autoScales = true
        }
    }

    static func dismantleNSView(_ view: PDFView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator, name: .PDFViewScaleChanged, object: view)
    }

    final class Coordinator: NSObject {
        var zoom: Binding<Double>
        var scale: Binding<Double>

        init(zoom: Binding<Double>, scale: Binding<Double>) {
            self.zoom = zoom
            self.scale = scale
        }

        /// PDFKit changed the scale — because the window resized under "fit",
        /// because the user pinched, or because we asked it to.
        ///
        /// Telling those apart is what `autoScales` is for. While it's on we're
        /// fitting, and the scale is only worth reporting for the percentage on
        /// the bar; adopting it into `zoom` there would turn the first window
        /// resize into a fixed zoom and quietly break fitting. Once it's off,
        /// the number *is* the setting, so a pinch sticks.
        @objc func scaleChanged(_ note: Notification) {
            guard let view = note.object as? PDFView else { return }
            scale.wrappedValue = view.scaleFactor

            guard !view.autoScales, abs(view.scaleFactor - zoom.wrappedValue) > 0.001 else { return }
            zoom.wrappedValue = view.scaleFactor
        }
    }
}
