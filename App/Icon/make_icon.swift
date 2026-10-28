// Renders the BrightBar app icon: a dark squircle with a glowing sun above a brightness slider.
// Usage: swift make_icon.swift <output-dir>   → writes AppIcon.iconset/*.png
import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let iconset = URL(fileURLWithPath: outDir).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func draw(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else { return image }
    let s = size / 1024.0

    // macOS icon grid: 824pt artwork centred on a 1024pt canvas.
    let inset = 100 * s
    let rect = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let radius = rect.width * 0.2237
    let squircle = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

    // Drop shadow
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12 * s), blur: 28 * s, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    NSColor(calibratedRed: 0.10, green: 0.10, blue: 0.14, alpha: 1).setFill()
    squircle.fill()
    ctx.restoreGState()

    // Background gradient
    ctx.saveGState()
    squircle.addClip()
    NSGradient(colors: [
        NSColor(calibratedRed: 0.16, green: 0.16, blue: 0.22, alpha: 1),
        NSColor(calibratedRed: 0.07, green: 0.07, blue: 0.10, alpha: 1),
    ])!.draw(in: rect, angle: -90)

    let sunCenter = CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.60)
    let sunRadius = rect.width * 0.17
    let amber = NSColor(calibratedRed: 1.0, green: 0.72, blue: 0.22, alpha: 1)
    let gold = NSColor(calibratedRed: 1.0, green: 0.88, blue: 0.45, alpha: 1)

    // Warm glow behind the sun
    NSGradient(colors: [amber.withAlphaComponent(0.55), amber.withAlphaComponent(0.0)])!
        .draw(fromCenter: sunCenter, radius: 0, toCenter: sunCenter, radius: rect.width * 0.55, options: [])

    // Rays
    ctx.saveGState()
    ctx.translateBy(x: sunCenter.x, y: sunCenter.y)
    let rayInner = sunRadius * 1.45
    let rayOuter = sunRadius * 2.05
    let rayWidth = 40 * s
    for i in 0..<8 {
        ctx.saveGState()
        ctx.rotate(by: CGFloat(i) * .pi / 4)
        let ray = NSBezierPath(roundedRect: CGRect(x: -rayWidth / 2, y: rayInner, width: rayWidth, height: rayOuter - rayInner),
                               xRadius: rayWidth / 2, yRadius: rayWidth / 2)
        gold.setFill()
        ray.fill()
        ctx.restoreGState()
    }
    ctx.restoreGState()

    // Sun disc
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 40 * s, color: amber.withAlphaComponent(0.8).cgColor)
    let disc = NSBezierPath(ovalIn: CGRect(x: sunCenter.x - sunRadius, y: sunCenter.y - sunRadius, width: sunRadius * 2, height: sunRadius * 2))
    NSGradient(colors: [gold, amber])!.draw(in: disc, angle: -90)
    ctx.restoreGState()

    // Slider track + knob
    let trackY = rect.minY + rect.height * 0.21
    let trackHeight = 46 * s
    let trackX0 = rect.minX + rect.width * 0.17
    let trackX1 = rect.maxX - rect.width * 0.17
    let knobX = trackX0 + (trackX1 - trackX0) * 0.68
    let track = NSBezierPath(roundedRect: CGRect(x: trackX0, y: trackY - trackHeight / 2, width: trackX1 - trackX0, height: trackHeight),
                             xRadius: trackHeight / 2, yRadius: trackHeight / 2)
    NSColor.white.withAlphaComponent(0.16).setFill()
    track.fill()
    let lit = NSBezierPath(roundedRect: CGRect(x: trackX0, y: trackY - trackHeight / 2, width: knobX - trackX0, height: trackHeight),
                           xRadius: trackHeight / 2, yRadius: trackHeight / 2)
    amber.setFill()
    lit.fill()

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6 * s), blur: 14 * s, color: NSColor.black.withAlphaComponent(0.45).cgColor)
    let knobR = 58 * s
    let knob = NSBezierPath(ovalIn: CGRect(x: knobX - knobR, y: trackY - knobR, width: knobR * 2, height: knobR * 2))
    NSGradient(colors: [NSColor.white, NSColor(calibratedWhite: 0.86, alpha: 1)])!.draw(in: knob, angle: -90)
    ctx.restoreGState()
    ctx.restoreGState()

    image.unlockFocus()
    return image
}

func write(_ image: NSImage, pixels: Int, name: String) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: CGRect(x: 0, y: 0, width: pixels, height: pixels), from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: iconset.appendingPathComponent(name))
}

for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let pixels = points * scale
    let image = draw(size: CGFloat(pixels))
    write(image, pixels: pixels, name: "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png")
}
print("wrote \(iconset.path)")
