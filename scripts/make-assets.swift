// Generates the app icon (.iconset) and the DMG background.
//   swift scripts/make-assets.swift icon  <out.iconset>
//   swift scripts/make-assets.swift dmgbg <out.png>
import AppKit

func bitmap(_ w: Int, _ h: Int, _ draw: () -> Void) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: w, height: h)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let indigo = NSColor(calibratedRed: 0.40, green: 0.36, blue: 0.98, alpha: 1)
let teal = NSColor(calibratedRed: 0.13, green: 0.80, blue: 0.82, alpha: 1)

func drawIcon(_ s: CGFloat) {
    let inset = s * 0.098
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.30)
    shadow.shadowBlurRadius = s * 0.03
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.015)
    shadow.set()
    indigo.setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    NSGradient(colors: [teal, indigo])!.draw(in: rect, angle: 62)
    // soft top highlight
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.20), NSColor.white.withAlphaComponent(0)])!
        .draw(in: NSRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2), angle: -90)

    // waveform bars, tallest in the middle
    let heights: [CGFloat] = [0.20, 0.36, 0.54, 0.72, 0.54, 0.36, 0.20]
    let barW = rect.width * 0.078
    let gap = rect.width * 0.050
    let total = CGFloat(heights.count) * barW + CGFloat(heights.count - 1) * gap
    var x = rect.midX - total / 2
    for h in heights {
        let bh = rect.height * h
        let bar = NSBezierPath(roundedRect: NSRect(x: x, y: rect.midY - bh / 2, width: barW, height: bh),
                               xRadius: barW / 2, yRadius: barW / 2)
        NSColor.white.withAlphaComponent(0.96).setFill()
        bar.fill()
        x += barW + gap
    }
    NSGraphicsContext.restoreGraphicsState()
}

func drawDmgBackground(_ w: CGFloat, _ h: CGFloat) {
    NSGradient(colors: [NSColor(calibratedWhite: 0.99, alpha: 1), NSColor(calibratedRed: 0.90, green: 0.93, blue: 0.97, alpha: 1)])!
        .draw(in: NSRect(x: 0, y: 0, width: w, height: h), angle: -90)

    let title = "Drag Auto Volume to Applications"
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 17, weight: .semibold),
        .foregroundColor: NSColor(calibratedWhite: 0.22, alpha: 1),
    ]
    let size = (title as NSString).size(withAttributes: attrs)
    (title as NSString).draw(at: NSPoint(x: (w - size.width) / 2, y: h - 62), withAttributes: attrs)

    let sub = "Then open it from your menu bar"
    let subAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: NSColor(calibratedWhite: 0.45, alpha: 1),
    ]
    let ss = (sub as NSString).size(withAttributes: subAttrs)
    (sub as NSString).draw(at: NSPoint(x: (w - ss.width) / 2, y: h - 84), withAttributes: subAttrs)

    // Arrow between the two icon positions (y measured from the top in Finder = 200).
    let cy = h - 200
    let arrow = NSBezierPath()
    arrow.lineWidth = 5
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    arrow.move(to: NSPoint(x: w / 2 - 38, y: cy))
    arrow.line(to: NSPoint(x: w / 2 + 34, y: cy))
    arrow.move(to: NSPoint(x: w / 2 + 16, y: cy + 18))
    arrow.line(to: NSPoint(x: w / 2 + 36, y: cy))
    arrow.line(to: NSPoint(x: w / 2 + 16, y: cy - 18))
    teal.withAlphaComponent(0.9).setStroke()
    arrow.stroke()
}

let args = CommandLine.arguments
guard args.count >= 3 else { print("usage: make-assets.swift icon|dmgbg <out>"); exit(2) }

switch args[1] {
case "icon":
    let dir = args[2]
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let sizes: [(String, Int)] = [
        ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
        ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
        ("icon_512x512", 512), ("icon_512x512@2x", 1024),
    ]
    for (name, px) in sizes {
        let data = bitmap(px, px) { drawIcon(CGFloat(px)) }
        try data.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
    }
case "dmgbg":
    let data = bitmap(660, 400) { drawDmgBackground(660, 400) }
    try data.write(to: URL(fileURLWithPath: args[2]))
default:
    print("unknown mode"); exit(2)
}
