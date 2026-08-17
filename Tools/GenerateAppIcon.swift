// Generates betterTextEdit's app icon.
//
//   swift Tools/GenerateAppIcon.swift <output-dir> [caret|sheet|ibeam]
//   iconutil -c icns <output-dir>/AppIcon.iconset -o betterTextEdit/Resources/AppIcon.icns
//
// The geometry is not invented: it was measured from the system's own Tahoe
// icons. The rounded shape covers 83.6% of the canvas, inset 8.2% left and
// right, sitting slightly high so the baked shadow has room beneath it. The
// corner is a superellipse rather than a circular round-rect — sampling
// TextEdit's silhouette gave a width profile of 0.728 / 0.830 / 0.922 at 2% /
// 5% / 10% down from the top, which an exponent of 5 reproduces to within a
// hundredth (0.713 / 0.836 / 0.924).
//
// Three designs are kept here because the choice is a matter of taste; `ibeam`
// is the one that ships, being the only one still legible at 16 points.

import AppKit

// Geometry measured from the system's own Tahoe icons (TextEdit, Notes):
// the rounded shape is 83.6% of the canvas, inset 8.2% left/right, and sits
// slightly high so the baked shadow has room beneath it.
enum Geometry {
    static let shapeRatio: CGFloat = 0.836
    static let topInsetRatio: CGFloat = 23.0 / 256.0
    static let cornerRatio: CGFloat = 0.2255   // of the shape's width
}

/// Apple's corners are continuous, not circular. A superellipse is the closest
/// shape you can build from a path without private API.
func squircle(in rect: CGRect, exponent n: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    let cx = rect.midX, cy = rect.midY
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let ct = cos(t), st = sin(t)
        let x = cx + a * (ct < 0 ? -1 : 1) * pow(abs(ct), 2 / n)
        let y = cy + b * (st < 0 ? -1 : 1) * pow(abs(st), 2 / n)
        if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

func shapeRect(for size: CGFloat) -> CGRect {
    let s = size * Geometry.shapeRatio
    let top = size * Geometry.topInsetRatio
    // CG origin is bottom-left: y = canvas - top - height
    return CGRect(x: (size - s) / 2, y: size - top - s, width: s, height: s)
}

func rounded(_ rect: CGRect, _ r: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
}

enum Design: String, CaseIterable { case caret, sheet, ibeam }

func draw(_ design: Design, size: CGFloat, into ctx: CGContext) {
    ctx.clear(CGRect(x: 0, y: 0, width: size, height: size))
    let rect = shapeRect(for: size)
    let shape = squircle(in: rect)

    // Shadow beneath the shape, the way the system bakes one in.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.012),
                  blur: size * 0.028,
                  color: NSColor.black.withAlphaComponent(0.28).cgColor)
    ctx.addPath(shape)
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    // Background gradient.
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let top = NSColor(srgbRed: 0.35, green: 0.60, blue: 0.99, alpha: 1).cgColor
    let bottom = NSColor(srgbRed: 0.16, green: 0.32, blue: 0.85, alpha: 1).cgColor
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [top, bottom] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: rect.midX, y: rect.maxY),
                           end: CGPoint(x: rect.midX, y: rect.minY),
                           options: [])

    // A soft specular sheen across the top, which is what gives Tahoe icons
    // their sense of material rather than flat colour.
    let sheen = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                           colors: [NSColor.white.withAlphaComponent(0.22).cgColor,
                                    NSColor.white.withAlphaComponent(0.0).cgColor] as CFArray,
                           locations: [0, 1])!
    ctx.drawLinearGradient(sheen,
                           start: CGPoint(x: rect.midX, y: rect.maxY),
                           end: CGPoint(x: rect.midX, y: rect.midY + rect.height * 0.05),
                           options: [])
    ctx.restoreGState()

    // Glyph
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let white = NSColor.white.cgColor
    let accent = NSColor(srgbRed: 1.0, green: 0.82, blue: 0.30, alpha: 1).cgColor

    switch design {
    case .caret:
        // Three text lines with a caret sitting on the middle one.
        let lineH = rect.width * 0.070
        let radius = lineH / 2
        let gap = rect.width * 0.115
        let left = rect.minX + rect.width * 0.185
        let widths: [CGFloat] = [0.630, 0.630, 0.385]
        let midY = rect.midY
        for (i, w) in widths.enumerated() {
            let y = midY + CGFloat(1 - i) * gap - lineH / 2
            ctx.addPath(rounded(CGRect(x: left, y: y, width: rect.width * w, height: lineH), radius))
            ctx.setFillColor(white)
            ctx.fillPath()
        }
        // The caret: a bold vertical bar crossing the lines.
        let caretW = rect.width * 0.072
        let caretH = rect.height * 0.46
        let caretX = rect.minX + rect.width * 0.655
        ctx.addPath(rounded(CGRect(x: caretX, y: rect.midY - caretH / 2, width: caretW, height: caretH), caretW / 2))
        ctx.setFillColor(accent)
        ctx.fillPath()

    case .sheet:
        // A page with lines knocked out of it.
        let pw = rect.width * 0.52, ph = rect.height * 0.66
        let page = CGRect(x: rect.midX - pw / 2, y: rect.midY - ph / 2, width: pw, height: ph)
        ctx.addPath(rounded(page, pw * 0.10))
        ctx.setFillColor(white)
        ctx.fillPath()
        ctx.setBlendMode(.destinationOut)
        let lineH = pw * 0.085, gap = pw * 0.175
        for i in 0..<3 {
            let w = i == 2 ? pw * 0.36 : pw * 0.62
            let y = page.midY + CGFloat(1 - i) * gap - lineH / 2
            ctx.addPath(rounded(CGRect(x: page.minX + pw * 0.19, y: y, width: w, height: lineH), lineH / 2))
            ctx.fillPath()
        }
        ctx.setBlendMode(.normal)

    case .ibeam:
        // The text cursor itself.
        let stemW = rect.width * 0.085
        let armW = rect.width * 0.30
        let armH = rect.height * 0.075
        let h = rect.height * 0.52
        ctx.setFillColor(white)
        ctx.addPath(rounded(CGRect(x: rect.midX - stemW / 2, y: rect.midY - h / 2, width: stemW, height: h), stemW / 2))
        ctx.fillPath()
        for sign in [CGFloat(1), CGFloat(-1)] {
            let y = rect.midY + sign * (h / 2) - armH / 2
            ctx.addPath(rounded(CGRect(x: rect.midX - armW / 2, y: y, width: armW, height: armH), armH / 2))
            ctx.fillPath()
        }
    }
    ctx.restoreGState()
}

func render(_ design: Design, size: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high
    draw(design, size: CGFloat(size), into: ctx)
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    let rep = NSBitmapImageRep(cgImage: image)
    try? rep.representation(using: .png, properties: [:])?.write(to: url)
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for design in Design.allCases {
    writePNG(render(design, size: 1024), to: out.appendingPathComponent("\(design.rawValue)-1024.png"))
    // small-size legibility check
    for small in [16, 32, 48, 64] {
        writePNG(render(design, size: small), to: out.appendingPathComponent("\(design.rawValue)-\(small).png"))
    }
}
print("rendered: \(Design.allCases.map(\.rawValue).joined(separator: ", "))")

// --- iconset emission ---
if CommandLine.arguments.count > 2 {
    let design = Design(rawValue: CommandLine.arguments[2])!
    let iconset = out.appendingPathComponent("AppIcon.iconset")
    try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
    let ladder: [(String, Int)] = [
        ("icon_16x16", 16), ("icon_16x16@2x", 32),
        ("icon_32x32", 32), ("icon_32x32@2x", 64),
        ("icon_128x128", 128), ("icon_128x128@2x", 256),
        ("icon_256x256", 256), ("icon_256x256@2x", 512),
        ("icon_512x512", 512), ("icon_512x512@2x", 1024),
    ]
    for (name, size) in ladder {
        writePNG(render(design, size: size), to: iconset.appendingPathComponent("\(name).png"))
    }
    print("iconset written for \(design.rawValue): \(ladder.count) sizes")
}
