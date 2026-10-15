// Renders the DiskSeer app icon (a treemap in a squircle) into an .iconset folder.
import AppKit

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)

func color(_ r: Double, _ g: Double, _ b: Double) -> NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: 1) }

func render(size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // macOS icon grid: 824/1024 body with a soft shadow.
    let inset = s * 100 / 1024
    let body = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = body.width * 0.225
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    let squircle = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.addPath(squircle)
    ctx.setFillColor(color(0.08, 0.09, 0.17).cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [color(0.17, 0.20, 0.36).cgColor, color(0.06, 0.07, 0.14).cgColor] as CFArray,
                              locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])

    // Treemap blocks (coordinates in unit space, origin top-left).
    let pad = body.width * 0.14
    let area = body.insetBy(dx: pad, dy: pad)
    let gap = area.width * 0.025
    let blocks: [(CGRect, NSColor)] = [
        (CGRect(x: 0, y: 0, width: 0.58, height: 0.62), color(0.27, 0.52, 0.96)),
        (CGRect(x: 0.58, y: 0, width: 0.42, height: 0.38), color(0.93, 0.47, 0.20)),
        (CGRect(x: 0.58, y: 0.38, width: 0.42, height: 0.24), color(0.98, 0.78, 0.22)),
        (CGRect(x: 0, y: 0.62, width: 0.36, height: 0.38), color(0.95, 0.36, 0.55)),
        (CGRect(x: 0.36, y: 0.62, width: 0.36, height: 0.38), color(0.24, 0.72, 0.52)),
        (CGRect(x: 0.72, y: 0.62, width: 0.28, height: 0.38), color(0.10, 0.62, 0.78)),
    ]
    for (unit, fill) in blocks {
        let r = CGRect(x: area.minX + unit.minX * area.width + gap / 2,
                       y: area.maxY - (unit.maxY * area.height) + gap / 2,
                       width: unit.width * area.width - gap, height: unit.height * area.height - gap)
        let path = CGPath(roundedRect: r, cornerWidth: r.width * 0.08 + 1, cornerHeight: r.width * 0.08 + 1, transform: nil)
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        let light = fill.blended(withFraction: 0.3, of: .white)!
        let dark = fill.blended(withFraction: 0.25, of: .black)!
        let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [light.cgColor, fill.cgColor, dark.cgColor] as CFArray, locations: [0, 0.5, 1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: r.minX, y: r.maxY), end: CGPoint(x: r.maxX, y: r.minY), options: [])
        ctx.restoreGState()
    }
    // Magnifier ring over the blocks ("seer").
    let ringCenter = CGPoint(x: area.minX + area.width * 0.70, y: area.minY + area.height * 0.30)
    let ringRadius = area.width * 0.20
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.95).cgColor)
    ctx.setLineWidth(area.width * 0.055)
    ctx.strokeEllipse(in: CGRect(x: ringCenter.x - ringRadius, y: ringCenter.y - ringRadius, width: ringRadius * 2, height: ringRadius * 2))
    ctx.setLineCap(.round)
    ctx.setLineWidth(area.width * 0.075)
    ctx.move(to: CGPoint(x: ringCenter.x + ringRadius * 0.72, y: ringCenter.y - ringRadius * 0.72))
    ctx.addLine(to: CGPoint(x: ringCenter.x + ringRadius * 1.45, y: ringCenter.y - ringRadius * 1.45))
    ctx.strokePath()
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! render(size: base * scale).write(to: URL(fileURLWithPath: "\(output)/\(name)"))
    }
}
print("wrote \(output)")
