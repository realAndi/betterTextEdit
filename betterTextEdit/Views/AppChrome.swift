import AppKit
import SwiftUI

// betterTextEdit's shared chrome.
//
// The rule for everything in this file: use the system's glass, the system's
// type scale, and the accent colour — from System Settings under the System
// theme, from the theme otherwise. The app should look like it came with
// macOS, not like it brought its own design language along.
//
// There's no `Theme` colour namespace here any more. Every view that needs a
// colour asks `ThemeStore.shared.current` for it directly, which is one hop
// rather than two and leaves nowhere for a second, stale answer to live.

// MARK: - Editor metrics

/// Shared limits for the editor's text size, so the toolbar menu and the View
/// menu agree on what "Bigger" means.
enum EditorMetrics {
    static let defaultFontSize = 13.0
    static let minimumFontSize = 9.0
    static let maximumFontSize = 28.0

    /// Extra leading between lines, in points. The default is what the editor
    /// used before it was adjustable.
    static let defaultLineSpacing = 2.5
    static let minimumLineSpacing = 0.0
    static let maximumLineSpacing = 12.0

    static func bigger(than size: Double) -> Double {
        min(size + 1, maximumFontSize)
    }

    static func smaller(than size: Double) -> Double {
        max(size - 1, minimumFontSize)
    }
}

// MARK: - Floating chrome

/// Metrics for the bars that float on Liquid Glass above the canvas — the tab
/// strip and the format bar. Shared so the two line up with each other and
/// inset from the window edge by the same amount.
enum Chrome {
    static let cornerRadius = 12.0
    static let inset = 10.0
    /// How far apart two glass shapes can be before they stop blending into one
    /// another inside a `GlassEffectContainer`.
    static let glassSpacing = 8.0

    static var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }
}

// MARK: - Behind-window blur

/// The window's canvas as a plain behind-window material — the blur macOS had
/// before Liquid Glass.
///
/// Kept alongside `LiquidGlassCanvas` rather than replaced by it, because the
/// two aren't the same look and neither is a worse version of the other. Glass
/// refracts what's behind the window and catches light across its surface;
/// this only smears, which is calmer to work over for long stretches.
///
/// `.sidebar` is the system's translucent-canvas material and lets considerably
/// more of the desktop through than `.underWindowBackground`, which is tuned to
/// sit underneath opaque content rather than be looked at.
struct MaterialCanvas: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar

    func makeNSView(context _: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        // `.active`, not the default `.followsWindowActiveState`: the canvas is
        // the thing the whole window's colour comes from, and having it go grey
        // the moment you click another app is a bigger change than an inactive
        // window should make.
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context _: Context) {
        view.material = material
    }
}

// MARK: - Liquid Glass

/// The window's canvas, in Liquid Glass.
///
/// `NSGlassEffectView` is the real thing rather than the `NSVisualEffectView`
/// approximation: it refracts and specularly highlights what's behind the
/// window instead of just frosting it, and it tints itself properly rather than
/// needing a flat colour laid over the top.
///
/// It also settles what the blur dial should have been. Glass has two styles,
/// `.regular` and `.clear`, and no amount in between — so the choice belongs in
/// the Window picker beside Solid, not in a slider pretending to be continuous.
struct LiquidGlassCanvas: NSViewRepresentable {
    var style: NSGlassEffectView.Style
    /// What to pull the glass towards — the theme's canvas colour, at the
    /// strength the Tint dial asks for. `nil` leaves the glass untinted.
    var tint: NSColor?

    func makeNSView(context _: Context) -> NSGlassEffectView {
        let view = NSGlassEffectView()
        // The glass wraps a content view; ours is empty, because what floats
        // over this canvas are siblings in the SwiftUI hierarchy above it.
        let content = NSView()
        content.autoresizingMask = [.width, .height]
        view.contentView = content
        // Full-bleed: this is the window's whole surface, not a floating panel.
        view.cornerRadius = 0
        view.style = style
        view.tintColor = tint
        return view
    }

    func updateNSView(_ view: NSGlassEffectView, context _: Context) {
        view.style = style
        view.tintColor = tint
    }
}

// MARK: - Window configuration

/// Lets the content run under the title bar so the window background — blurred
/// or solid — is continuous behind the toolbar. The title bar, its buttons, and
/// the toolbar all stay native.
struct WindowConfigurator: NSViewRepresentable {
    var translucent: Bool
    /// The colour the window falls back to when it isn't translucent — the
    /// theme's, so the frame around the content matches what's inside it.
    var background: NSColor

    func makeNSView(context _: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { apply(to: view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context _: Context) {
        DispatchQueue.main.async { apply(to: view.window) }
    }

    private func apply(to window: NSWindow?) {
        guard let window else { return }
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        // A non-opaque window is what lets the behind-window blur show through.
        window.isOpaque = !translucent
        window.backgroundColor = translucent ? .clear : background
    }
}

// MARK: - Middle-click

/// Reports a middle-click on whatever it's laid over — the gesture browsers use
/// to close a tab.
///
/// SwiftUI's gestures only ever see the primary button, so the only way to hear
/// the middle one is to put a real AppKit view in the way. The trick that keeps
/// it from being *in the way* of everything else is `hitTest`: it hands itself
/// back only while AppKit is routing an other-button event, and returns `nil`
/// otherwise, so ordinary clicks never reach it and carry on to the SwiftUI
/// view underneath — its tap gesture, its close button, its tooltip, all
/// untouched.
///
/// Firing on mouse-*up*, inside the bounds, is what a button does: press,
/// change your mind, drag off, and nothing happens.
struct MiddleClickCatcher: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context _: Context) -> CatcherView {
        let view = CatcherView()
        view.action = action
        return view
    }

    func updateNSView(_ view: CatcherView, context _: Context) {
        view.action = action
    }

    final class CatcherView: NSView {
        var action: () -> Void = {}
        /// Whether the press that's in flight started here, so a middle-click
        /// begun somewhere else and released over this view does nothing.
        private var pressed = false

        override func hitTest(_ point: NSPoint) -> NSView? {
            switch NSApp.currentEvent?.type {
            case .otherMouseDown, .otherMouseUp, .otherMouseDragged:
                return super.hitTest(point)
            default:
                return nil
            }
        }

        /// A middle-click shouldn't have to be spent activating the window
        /// first — the tab it lands on is the one it means.
        override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }

        override func otherMouseDown(with event: NSEvent) {
            guard event.buttonNumber == 2 else { return super.otherMouseDown(with: event) }
            pressed = true
        }

        override func otherMouseUp(with event: NSEvent) {
            guard event.buttonNumber == 2, pressed else { return super.otherMouseUp(with: event) }
            pressed = false
            guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
            action()
        }
    }
}
