#!/usr/bin/env swift
// Generates the Sweep app icon into an .appiconset directory.
// Usage: swift scripts/generate-icon.swift Sweep/Assets.xcassets/AppIcon.appiconset

import AppKit

guard CommandLine.arguments.count > 1 else {
    print("usage: generate-icon.swift <appiconset-dir>")
    exit(1)
}
let outDir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)

func render(canvas: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: canvas, pixelsHigh: canvas,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: canvas, height: canvas)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let s = CGFloat(canvas)
    // Standard macOS icon grid: content inset ~10% with a continuous-corner feel.
    let inset = s * 0.098
    let rect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = rect.width * 0.225
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.36, green: 0.65, blue: 0.98, alpha: 1),
        NSColor(calibratedRed: 0.11, green: 0.32, blue: 0.80, alpha: 1),
    ])!
    gradient.draw(in: path, angle: -70)

    // Wind strokes: three swooshes, drawn as rounded-cap curves.
    let strokeColor = NSColor.white
    strokeColor.setStroke()
    func swoosh(yFrac: CGFloat, startFrac: CGFloat, endFrac: CGFloat, curlRadiusFrac: CGFloat, width: CGFloat) {
        let y = rect.minY + rect.height * yFrac
        let startX = rect.minX + rect.width * startFrac
        let endX = rect.minX + rect.width * endFrac
        let line = NSBezierPath()
        line.lineWidth = width
        line.lineCapStyle = .round
        line.move(to: NSPoint(x: startX, y: y))
        line.line(to: NSPoint(x: endX, y: y))
        // curl: a small arc at the end of the stroke
        let r = rect.width * curlRadiusFrac
        line.appendArc(withCenter: NSPoint(x: endX, y: y + r), radius: r,
                       startAngle: -90, endAngle: 180, clockwise: false)
        line.stroke()
    }
    let w = rect.width * 0.055
    swoosh(yFrac: 0.62, startFrac: 0.16, endFrac: 0.62, curlRadiusFrac: 0.085, width: w)
    swoosh(yFrac: 0.44, startFrac: 0.22, endFrac: 0.74, curlRadiusFrac: 0.065, width: w)
    swoosh(yFrac: 0.28, startFrac: 0.16, endFrac: 0.52, curlRadiusFrac: 0.05, width: w)

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func writePNG(_ rep: NSBitmapImageRep, to url: URL) {
    let png = rep.representation(using: .png, properties: [:])!
    try! png.write(to: url)
}

// Render master and all required sizes.
let sizes: [(name: String, px: Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for entry in sizes {
    writePNG(render(canvas: entry.px), to: outDir.appendingPathComponent(entry.name))
}
print("Wrote \(sizes.count) icons to \(outDir.path)")
