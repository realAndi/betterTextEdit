import SwiftUI

/// Shows an image, and — when there's more than one frame — lets you walk
/// through it a frame at a time.
///
/// Zoom is one continuous number rather than a short list of stops. `zoom` is
/// still 0 for "fit the window", because that's a genuinely different intent —
/// it re-fits as the window resizes, where every other value is a fixed
/// multiple of the image's own pixels and stays put.
struct ImageViewer: View {
    let document: ImageDocument
    @Binding var zoom: Double

    @State private var frameIndex = 0
    @State private var playing = true

    /// The scale while a pinch is in flight.
    ///
    /// Held apart from `zoom` because `zoom` is backed by `@AppStorage`, and
    /// writing to it on every frame of a gesture means writing to `UserDefaults`
    /// on every frame of a gesture. The pinch commits once, when it ends.
    @State private var pinch: Double?
    /// The scale the pinch began from, so magnification multiplies against a
    /// fixed starting point instead of compounding.
    @State private var pinchBase: Double?

    /// How much room the picture has, which is what "fit" is measured against.
    @State private var canvasSize: CGSize = .zero

    private static let limits = 0.02 ... 40.0
    private static let step = 1.25
    /// Breathing room around the picture, and the inset "fit" allows for.
    private static let inset: CGFloat = 20

    private var currentFrame: ImageDocument.Frame {
        document.frames[min(frameIndex, document.frames.count - 1)]
    }

    var body: some View {
        VStack(spacing: 0) {
            canvas
            Divider()
            controls
        }
        .task(id: TaskKey(playing: playing, frames: document.frames.count)) {
            await animate()
        }
    }

    // MARK: - Scale

    /// What one image pixel is worth in points right now.
    ///
    /// The single answer everything reads: the frame the picture is given, the
    /// percentage on the bar, and which way to interpolate. Nothing else works
    /// out its own version of it.
    private var scale: Double {
        if let pinch { return pinch }
        return zoom > 0 ? zoom : fitScale
    }

    /// The scale at which the whole picture is visible.
    private var fitScale: Double {
        let pixels = document.pixelSize
        guard pixels.width > 0, pixels.height > 0 else { return 1 }
        let available = CGSize(
            width: max(canvasSize.width - Self.inset * 2, 1),
            height: max(canvasSize.height - Self.inset * 2, 1)
        )
        return min(available.width / pixels.width, available.height / pixels.height)
    }

    private func clamped(_ value: Double) -> Double {
        min(max(value, Self.limits.lowerBound), Self.limits.upperBound)
    }

    /// Zooms by a factor, starting from whatever is on screen — so stepping up
    /// from "fit" continues from the size it was actually being shown at rather
    /// than jumping to some unrelated multiple.
    private func zoom(by factor: Double) {
        zoom = clamped(scale * factor)
    }

    // MARK: - The picture

    private var canvas: some View {
        ScrollView([.horizontal, .vertical]) {
            image
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(Self.inset)
        }
        .background(Checkerboard())
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { canvasSize = $0 }
        .gesture(magnification)
        // Preview's gesture, and the one people try first: straight to actual
        // size, and straight back to fitting.
        .onTapGesture(count: 2) {
            zoom = zoom > 0 ? 0 : 1
        }
    }

    private var image: some View {
        // Interpolation follows the scale actually on screen, not the stored
        // setting. Enlarged pixels are shown as pixels; anything at or below
        // full size is smoothed. Under "fit" those two can both happen to the
        // same picture, and the stored 0 says nothing about which.
        Image(nsImage: currentFrame.image)
            .interpolation(scale > 1 ? .none : .high)
            .antialiased(scale <= 1)
            .resizable()
            .frame(
                width: document.pixelSize.width * scale,
                height: document.pixelSize.height * scale
            )
    }

    private var magnification: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                // Pinching out of "fit" needs a number to start from, and the
                // size it's being shown at is the only one that won't jump.
                let base = pinchBase ?? scale
                pinchBase = base
                pinch = clamped(base * value.magnification)
            }
            .onEnded { _ in
                if let pinch { zoom = pinch }
                pinch = nil
                pinchBase = nil
            }
    }

    // MARK: - Animation

    /// Identifies a run of the animation task, so it restarts when playback is
    /// toggled or the document changes but not on every frame.
    private struct TaskKey: Equatable {
        let playing: Bool
        let frames: Int
    }

    private func animate() async {
        guard document.isAnimated, playing else { return }
        while !Task.isCancelled, playing {
            try? await Task.sleep(for: .seconds(currentFrame.delay))
            guard !Task.isCancelled, playing else { return }
            advance(by: 1)
        }
    }

    private func advance(by offset: Int) {
        let count = document.frames.count
        frameIndex = (frameIndex + offset + count) % count
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 10) {
            if document.isAnimated {
                frameControls
            }
            Spacer(minLength: 12)
            zoomControls
        }
        .font(.subheadline)
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .frame(height: 34)
    }

    private var zoomControls: some View {
        HStack(spacing: 8) {
            Button {
                zoom(by: 1 / Self.step)
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .help("Zoom out")
            .disabled(scale <= Self.limits.lowerBound)

            // Wide enough for "1000%", so the buttons either side don't shuffle
            // as the number grows.
            Text(percentage)
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
                .help("Resize the picture to the window, and keep it there")

            Button("100%") { zoom = 1 }
                .disabled(zoom == 1)
                .help("One image pixel per point")
        }
    }

    private var percentage: String {
        let shown = scale * 100
        // Below 10% a whole number is all noise; above it, a fraction is.
        return shown < 10
            ? String(format: "%.1f%%", shown)
            : "\(Int(shown.rounded()))%"
    }

    private var frameControls: some View {
        HStack(spacing: 10) {
            Button {
                playing.toggle()
            } label: {
                Image(systemName: playing ? "pause.fill" : "play.fill")
                    .frame(width: 14)
            }
            .help(playing ? "Pause" : "Play")

            Button {
                playing = false
                advance(by: -1)
            } label: {
                Image(systemName: "backward.frame.fill")
            }
            .help("Previous frame")

            Button {
                playing = false
                advance(by: 1)
            } label: {
                Image(systemName: "forward.frame.fill")
            }
            .help("Next frame")

            Slider(
                value: Binding(
                    get: { Double(frameIndex) },
                    set: { playing = false; frameIndex = Int($0.rounded()) }
                ),
                in: 0 ... Double(document.frames.count - 1),
                step: 1
            )
            .controlSize(.small)
            .frame(width: 130)

            Text("Frame \(frameIndex + 1) of \(document.frames.count)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Text("\(Int(currentFrame.delay * 1000)) ms")
                .monospacedDigit()
                .foregroundStyle(.tertiary)
        }
    }
}

/// The standard grey chequerboard, so transparency reads as transparency rather
/// than as whatever colour the window happens to be.
private struct Checkerboard: View {
    private let square: CGFloat = 10

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white.opacity(0.06)))
            let columns = Int(size.width / square) + 1
            let rows = Int(size.height / square) + 1
            for row in 0 ..< rows {
                for column in 0 ..< columns where (row + column).isMultiple(of: 2) {
                    let rect = CGRect(
                        x: CGFloat(column) * square,
                        y: CGFloat(row) * square,
                        width: square,
                        height: square
                    )
                    context.fill(Path(rect), with: .color(.primary.opacity(0.05)))
                }
            }
        }
        .drawingGroup()
    }
}
