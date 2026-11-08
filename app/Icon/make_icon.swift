// Draws the FanaMac app icon (original artwork) and writes an .iconset folder.
// Usage: swift make_icon.swift <output.iconset>
import AppKit

func draw(size s: CGFloat) -> NSImage {
    NSImage(size: NSSize(width: s, height: s), flipped: false) { _ in
        let ctx = NSGraphicsContext.current!.cgContext
        let inset = s * 0.1
        let tile = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
        let path = CGPath(roundedRect: tile, cornerWidth: tile.width * 0.225, cornerHeight: tile.width * 0.225, transform: nil)

        // Tile: deep graphite gradient with a soft drop shadow.
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: NSColor.black.withAlphaComponent(0.35).cgColor)
        ctx.addPath(path); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(path); ctx.clip()
        let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
            NSColor(red: 0.20, green: 0.22, blue: 0.26, alpha: 1).cgColor,
            NSColor(red: 0.07, green: 0.08, blue: 0.10, alpha: 1).cgColor,
        ] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])

        let c = CGPoint(x: s / 2, y: s / 2)
        let r = tile.width * 0.33
        let ring = tile.width * 0.075
        let accent = NSColor(red: 0.98, green: 0.36, blue: 0.20, alpha: 1)
        let light = NSColor(white: 0.93, alpha: 1)

        // Rim
        ctx.setStrokeColor(light.cgColor); ctx.setLineWidth(ring)
        ctx.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)); ctx.strokePath()

        // Spokes: left, right, bottom
        ctx.setLineCap(.round); ctx.setLineWidth(ring * 0.8)
        for angle in [CGFloat.pi, 0, -CGFloat.pi / 2] {
            ctx.move(to: c)
            ctx.addLine(to: CGPoint(x: c.x + cos(angle) * r, y: c.y + sin(angle) * r))
        }
        ctx.strokePath()

        // Hub
        let hub = r * 0.36
        ctx.setFillColor(light.cgColor)
        ctx.fillEllipse(in: CGRect(x: c.x - hub, y: c.y - hub, width: 2 * hub, height: 2 * hub))
        ctx.setFillColor(NSColor(red: 0.12, green: 0.13, blue: 0.16, alpha: 1).cgColor)
        let dot = hub * 0.45
        ctx.fillEllipse(in: CGRect(x: c.x - dot, y: c.y - dot, width: 2 * dot, height: 2 * dot))

        // Centre marker at 12 o'clock, in the accent colour
        ctx.setStrokeColor(accent.cgColor); ctx.setLineWidth(ring * 1.02); ctx.setLineCap(.butt)
        ctx.addArc(center: c, radius: r, startAngle: .pi / 2 - 0.17, endAngle: .pi / 2 + 0.17, clockwise: false)
        ctx.strokePath()
        ctx.restoreGState()
        return true
    }
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let img = draw(size: CGFloat(px))
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        img.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
    }
}
